# Assembles the folder (README.md "Built folder") and the config CD.
# Installer blobs are unfree; fetchurl ignores licences, so nothing here needs
# allowUnfree. virtio-win is free.
{
  lib,
  config,
  pkgs,
  ...
}:
let
  inherit (lib) mkOption types;
  cfg = config;

  pinOf = i: cfg.pins.${i.id};
  fetch =
    i:
    let
      p = pinOf i;
    in
    pkgs.fetchurl {
      inherit (p) url sha256;
      name = p.file;
    };
  enabled = lib.filter (i: i.enable) cfg.packageItems;
  tools = lib.filter (i: i.tool != null) enabled;
  installers = lib.filter (i: i.tool == null) enabled;

  json = name: v: pkgs.writeText name (builtins.toJSON v);

  itemsJson = json "items.json" (
    map (
      i:
      let
        p = pinOf i;
      in
      {
        inherit (i)
          id
          name
          when
          minBuild
          extractTo
          rootDevice
          ;
        inherit (p) version installerType;
        kind = if i.kind == "auto" then p.kind else i.kind;
        detect = if i.detect != null then i.detect else p.detect or null;
        silentArgs = if i.silentArgs != null then i.silentArgs else p.silentArgs or null;
        nestedFile = if i.nestedFile != null then i.nestedFile else p.nestedFile or null;
        # Pinned source so apply can download just the items whose detect
        # fails when the local installer blob is absent (thin deploy).
        url = p.url or null;
        sha256 = p.sha256 or null;
        file = "installers/${i.id}/${p.file}";
      }
    ) installers
  );

  machineJson = json "machine.json" (
    {
      files = lib.mapAttrsToList (
        name: f:
        {
          inherit name;
          inherit (f)
            root
            path
            format
            holders
            requires
            minBuild
            ;
        }
        // {
          json.data = f.json;
          ini.data = f.ini;
          text.data = f.text;
        }
        .${f.format}
      ) cfg.files;
      inherit (cfg) manualSteps;
    }
    // lib.optionalAttrs cfg.dsc.winrm { dscWinRM = true; }
  );

  # PSGallery .nupkg files are zips; .zip because 5.1 Expand-Archive insists.
  psModules = lib.mapAttrsToList (name: m: {
    inherit name;
    inherit (m) version;
    src = pkgs.fetchurl {
      url = "https://www.powershellgallery.com/api/v2/package/${name}/${m.version}";
      name = "${name}-${m.version}.zip";
      inherit (m) hash;
    };
  }) cfg.dsc.modules;

  startupJson = json "startup.json" cfg.boot.actions;

  switches = pkgs.writeText "switches.txt" (lib.concatMapStrings (s: "-${s}\n") cfg.debloat.switches);

  failed = map (a: a.message) (lib.filter (a: !a.assertion) cfg.assertions);
  checked =
    if failed == [ ] then
      lib.id
    else
      throw "windows configuration:\n${lib.concatMapStringsSep "\n" (m: "- ${m}") failed}";
in
{
  options = {
    assertions = mkOption {
      type = types.listOf types.attrs;
      default = [ ];
      internal = true;
    };
    debloat.switches = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Win11Debloat switches without the leading dash; empty skips debloat.";
    };
    drivers.virtio = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "virtio-win drivers staged from drivers/vm (w10/amd64 layout).";
    };
    unattend = {
      variant = mkOption {
        type = types.enum [
          "vm"
          "metal"
        ];
        default = "vm";
        description = "autounattend.xml variant put on the config CD.";
      };
      user = mkOption {
        type = types.str;
        default = "user";
      };
    };
    build = {
      applyDir = mkOption {
        type = types.path;
        default = ../apply;
        description = "Engine scripts copied verbatim.";
      };
      folder = mkOption {
        type = types.package;
        readOnly = true;
      };
      folderThin = mkOption {
        type = types.package;
        readOnly = true;
        description = "Scripts/json only, no installer blobs; apply downloads missing installers itself.";
      };
      iso = mkOption {
        type = types.package;
        readOnly = true;
      };
      unattend = mkOption {
        type = types.package;
        readOnly = true;
      };
    };
  };

  config.build =
    let
      # withInstallers=false renders only scripts/json/dsc (~100 KiB): the
      # thin deploy syncs that and apply downloads just the items whose
      # detect fails (items.json carries each pin's url+sha256).
      buildFolder =
        name: withInstallers:
        checked (
          pkgs.runCommand name
            {
              passthru = {
                inherit itemsJson machineJson startupJson;
                inherit (cfg.dsc) documents;
              };
            }
            ''
              mkdir -p $out/installers $out/tools $out/drivers/vm
              cp ${cfg.build.applyDir}/* $out/
              cp ${itemsJson} $out/items.json
              cp ${machineJson} $out/machine.json
              cp ${startupJson} $out/startup.json
              ${lib.concatStrings (lib.mapAttrsToList (n: d: "cp ${d} $out/${n}\n") cfg.dsc.documents)}
              ${lib.optionalString withInstallers (
                lib.concatMapStrings (i: ''
                  mkdir -p $out/installers/${i.id}
                  cp ${fetch i} $out/installers/${i.id}/${(pinOf i).file}
                '') installers
              )}
              ${lib.concatMapStrings (i: ''
                mkdir -p $out/tools/${i.tool}
                cp ${fetch i} $out/tools/${i.tool}/${(pinOf i).file}
              '') tools}
              ${lib.optionalString (
                cfg.debloat.switches != [ ]
              ) "cp ${switches} $out/tools/Win11Debloat/switches.txt"}
              ${lib.concatMapStrings (d: ''
                cp -r ${pkgs.virtio-win}/${d}/w10/amd64 $out/drivers/vm/${d}
              '') cfg.drivers.virtio}
              ${lib.concatMapStrings (m: ''
                mkdir -p $out/tools/psmodules/${m.name}
                cp ${m.src} $out/tools/psmodules/${m.name}/${m.version}.zip
              '') psModules}
              chmod -R u+w $out
            ''
        );
    in
    {
      folder = buildFolder "windows-config" true;
      folderThin = buildFolder "windows-config-thin" false;

      unattend = pkgs.callPackage ../unattend.nix { inherit (cfg.unattend) variant user; };

      # Config CD (volume MCONFIG): the folder + autounattend.xml at the root.
      # Not bootable; attach it next to the Windows install ISO.
      iso = pkgs.runCommand "windows-config.iso" { nativeBuildInputs = [ pkgs.xorriso ]; } ''
        xorriso -as mkisofs -iso-level 3 -J -joliet-long -R -V MCONFIG -o $out \
          -graft-points ${cfg.build.folder}/ autounattend.xml=${cfg.build.unattend}
      '';
    };
}
