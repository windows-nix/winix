{
  description = "Declarative Windows hosts: Nix modules rendered to DSC v3 + a generic PowerShell engine";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/f9a75f41be3a74eab55d3a7679d34ad6cc0da977";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
      wlib = import ./lib.nix { inherit (nixpkgs) lib; };
      deployFor =
        pkgs:
        pkgs.writeShellApplication {
          name = "windows-deploy";
          runtimeInputs = with pkgs; [
            openssh
            gnutar
            coreutils
            findutils
            gnugrep
            glibc.bin # iconv
          ];
          text = builtins.readFile ./deploy.sh;
        };
      sample =
        (wlib.windowsConfiguration {
          inherit pkgs;
          modules = [ ./tests/sample-security.nix ];
        }).config.build.folder;
      samplePackages =
        (wlib.windowsConfiguration {
          inherit pkgs;
          modules = [ ./tests/sample-packages.nix ];
        }).config.build.folderThin;
    in
    {
      # windowsConfiguration { pkgs; modules = [ ... ]; specialArgs ? {}; }
      # deployFor pkgs -> windows-deploy <folder> [--apply ...]
      lib = {
        inherit (wlib) windowsConfiguration wlib;
        inherit deployFor;
      };
      windowsModules.default = ./modules;

      # Host-side NixOS modules (see docs/vm-module.md). windows-vm is the
      # generic GPU-passthrough VM module; win-sync delivers the built
      # Windows config folder to the Windows partition. default = both.
      nixosModules = {
        windows-vm = ./nixos/vm;
        win-sync = ./nixos/vm/win-sync.nix;
        default = [
          ./nixos/vm
          ./nixos/vm/win-sync.nix
        ];
      };

      packages.${system} = {
        deploy = deployFor pkgs;
        sync-pins = pkgs.writeShellApplication {
          name = "windows-sync-pins";
          runtimeInputs = with pkgs; [
            git
            yq-go
            nix
          ];
          text = ''exec ${pkgs.python3}/bin/python3 ${./sync-pins} "$@"'';
        };
      };

      checks.${system} = {
        apply-tests = pkgs.runCommand "windows-apply-tests" { nativeBuildInputs = [ pkgs.powershell ]; } ''
          cp -r ${./apply} apply && cp -r ${./modules} modules && cp -r ${./tests} tests && chmod -R u+w .
          HOME=$TMPDIR pwsh -NoProfile -File tests/apply.tests.ps1
          touch $out
        '';

        package-sets = pkgs.runCommand "windows-package-sets" { nativeBuildInputs = [ pkgs.jq ]; } ''
          jq -e 'sort_by(.id) | map({id, when}) == [
            {id: "bare-app", when: "metal"},
            {id: "common-app", when: "any"},
            {id: "publisher-application", when: "any"},
            {id: "vm-app", when: "vm"}
          ]' ${samplePackages}/items.json
          jq -e '.[] | select(.id == "publisher-application") |
            .name == "Publisher.Application" and .kind == "msi" and
            .detect.displayName == "^Publisher Application$"' ${samplePackages}/items.json
          touch $out
        '';

        sync-pins-tests =
          pkgs.runCommand "windows-sync-pins-tests" { nativeBuildInputs = [ pkgs.python3 ]; }
            ''
              cp ${./sync-pins} sync-pins
              cp ${./tests/sync-pins.tests.py} sync-pins.tests.py
              mkdir tests
              mv sync-pins.tests.py tests/
              python3 tests/sync-pins.tests.py
              touch $out
            '';

        deploy-tests =
          pkgs.runCommand "windows-deploy-tests"
            {
              nativeBuildInputs = with pkgs; [
                python3
                bash
                coreutils
                findutils
                gnugrep
                gnutar
                glibc.bin
              ];
            }
            ''
              cp ${./deploy.sh} deploy.sh
              mkdir tests
              cp ${./tests/deploy.tests.py} tests/deploy.tests.py
              python3 tests/deploy.tests.py
              touch $out
            '';

        # Host-side VM module tests (moved from the nixos repo's checks).
        win-sync = pkgs.callPackage ./nixos/vm/test-win-sync.nix { };
        win-vm = pkgs.runCommand "win-vm-test" { } ''
          ${pkgs.python3}/bin/python3 ${./nixos/vm}/test_win_vm.py && touch $out
        '';

        # securityPolicy + an adapted PSDSC resource render as expected.
        sample-security = pkgs.runCommand "windows-sample-security" { nativeBuildInputs = [ pkgs.jq ]; } ''
          d=${sample}/config.dsc.yaml
          jq -e '[.resources[].name] == ["Audit policy", "Security policy", "Audit logoff"]' $d
          jq -e '.resources[1].type == "Microsoft.DSC.Transitional/WindowsPowerShellScript"' $d
          jq -e '.resources[1].properties.setScript | test("SeLockMemoryPrivilege") and test("Set-SecPolicy")' $d
          jq -e '.resources[0].properties.testScript | test("0CCE9215") and test("Get-AuditPolicyDrift")' $d
          jq -e '.resources[2].directives.requireAdapter == "Microsoft.Adapter/WindowsPowerShell"' $d
          jq -e '.dscWinRM == true' ${sample}/machine.json
          test -s ${sample}/tools/psmodules/AuditPolicyDsc/*.zip
          touch $out
        '';
      };
    };
}
