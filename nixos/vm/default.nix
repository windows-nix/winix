# windows-vm: run a Windows install as a KVM guest with GPU passthrough.
# Generic, hardware-independent module exported as
# `nixosModules.windows-vm` from the windows-nix flake.
# openspec/changes/unify-windows-nix (moved from nixos/windows-vm).
#
# While imported: with gpuHandover the card stays on its Linux driver at boot
# and is handed to the VM only while it runs — `systemctl start windows-vm`
# (or `win-vm start`) stops the units in gpuSystemUnits/gpuUserUnits via
# Conflicts=, and starting one of them stops the VM. With gpuHandover = false
# the guest GPU (all its functions) is bound to vfio-pci at boot and is gone
# from Linux, idling at ~70-100 W in D0. Nothing starts a VM at boot and
# nothing needs the Windows disk. Removing the import is a full revert
# (an enabled IVRS initrd override is what makes VFIO possible on firmware
# that ships IVMD exclusion ranges).
#
# VFIO on kernel 7 needs iommufd (legacy group ioctls are gone); boards whose
# firmware ships IVMD exclusion ranges additionally need ivrsOverride with a
# dump of that board's IVRS table (see ivrsDump).
#
# The importing host must set at least `user`. Desktop integration (Looking
# Glass client config, GNOME shell helpers) is intentionally NOT here — it
# lives in the consuming repo (nixos/windows-vm-desktop.nix in the nixos repo)
# so headless or other-desktop hosts can import this module alone.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.windows-vm;
  qemuGrabCombos = [
    "ctrl-ctrl"
    "alt-alt"
    "shift-shift"
    "meta-meta"
    "scrolllock"
    "ctrl-scrolllock"
  ];
  useEvsieve = !(lib.elem cfg.evdevGrabToggle qemuGrabCombos) && cfg.evdevDevices != [ ];
  evsieveKey =
    k:
    {
      ctrl = "leftctrl";
      alt = "leftalt";
      shift = "leftshift";
      meta = "leftmeta";
    }
    .${k} or k;
  evsieveHookKeys = lib.concatMapStringsSep " " (k: "key:${evsieveKey k}") (
    lib.splitString "+" cfg.evdevGrabToggle
  );
  qemuEvdevDevices =
    if useEvsieve then [ "/dev/input/by-id/winvm-kbd" ] ++ lib.drop 1 cfg.evdevDevices else cfg.evdevDevices;
  report = config.hardware.facter.report;
  # PCI class 0x03 display controllers in the facter report.
  gpus = report.hardware.graphics_card or [ ];
  isNvidia = g: (g.vendor.value or 0) == 4318; # 0x10de
  # "0000:01:00.0" -> both functions of that slot (VGA + HDMI audio).
  slotFunctions =
    addr:
    let
      slot = lib.removeSuffix ".0" addr;
    in
    [ addr ] ++ lib.optional cfg.passAudio "${slot}.1";
  detected = map (g: g.sysfs_bus_id) (lib.filter isNvidia gpus);
  guestGpu =
    if cfg.guestGpu != null then
      cfg.guestGpu
    else if detected != [ ] then
      slotFunctions (lib.head detected)
    else
      [ ];

  # shm size: two SDR frames at maxResolution plus 10 MiB, next power of two (MiB).
  kvmfrMiB =
    let
      wh = map lib.toInt (lib.splitString "x" cfg.maxResolution);
      need = (lib.elemAt wh 0) * (lib.elemAt wh 1) * 4 * 2 / 1048576 + 10;
      pow2 = n: p: if p >= n then p else pow2 n (p * 2);
    in
    pow2 need 1;

  winVm = pkgs.symlinkJoin {
    name = "win-vm";
    paths = [ (pkgs.writers.writePython3Bin "win-vm" {
      flakeIgnore = [ "E501" "W503" ];
    } (builtins.readFile ./win_vm.py)) ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/win-vm --set WIN_VM_GPU ${lib.escapeShellArg (toString guestGpu)} --set WIN_VM_KVMFR ${toString (kvmfrMiB * 1048576)} --set WIN_VM_HANDOVER ${if cfg.gpuHandover then "1" else "0"} --set WIN_VM_EVDEV ${lib.escapeShellArg (toString qemuEvdevDevices)} --set WIN_VM_GRAB_TOGGLE ${if useEvsieve then "scrolllock" else cfg.evdevGrabToggle} --set WIN_VM_VGA ${if cfg.virtualConsole then "1" else "0"} --set WIN_VM_UNIT ${lib.escapeShellArg "windows-vm.service"} --prefix PATH : ${
          lib.makeBinPath [
            pkgs.libvirt
            pkgs.util-linux
            pkgs.ntfs3g
            cfg.viewerPackage
            pkgs.systemd
          ]
        }
    '';
  };
  hookPy = pkgs.writers.writePython3 "win-vm-hook.py" {
    flakeIgnore = [ "E501" "W503" ];
  } (builtins.readFile ./qemu_hook.py);
  # libvirtd's PATH is not ours to rely on; the hook runs systemctl, runuser
  # and modprobe, and reads the GPU unit lists from the module.
  hook = pkgs.writeShellScript "win-vm-hook" ''
    export PATH=${lib.makeBinPath [ config.systemd.package pkgs.kmod pkgs.util-linux ]}:$PATH
    export WIN_VM_HOOK_SYSTEM_UNITS=${lib.escapeShellArg (toString cfg.gpuSystemUnits)}
    export WIN_VM_HOOK_USER_UNITS=${lib.escapeShellArg (toString cfg.gpuUserUnits)}
    export WIN_VM_HOOK_USER=${lib.escapeShellArg cfg.user}
    exec ${hookPy} "$@"
  '';
  # Some boards' firmware ships IVMD exclusion ranges over PCI buses 00-0f
  # which the kernel then refuses to put in an unmanaged IOMMU domain.
  # patch-ivrs.py derives the patched table from the raw dump at build time;
  # the result is prepended to the initrd. Board-specific: the dump lives in
  # the consuming repo and is passed via ivrsDump.
  ivrsPatched = pkgs.runCommand "ivrs-patched" { } ''
    ${pkgs.python3.interpreter} ${./patch-ivrs.py} ${cfg.ivrsDump} $out
  '';
  ivrsOverrideCpio = pkgs.runCommand "ivrs-override.cpio" { } ''
    # The kernel only scans kernel/firmware/acpi/ in the early cpio
    # (admin-guide/acpi/initrd_table_override), and the OEM revision must be
    # higher than the firmware table's or the copy is ignored (patch-ivrs.py
    # takes care of the revision).
    mkdir -p kernel/firmware/acpi && cp ${ivrsPatched} kernel/firmware/acpi/IVRS
    printf 'kernel/firmware/acpi/IVRS\0' | ${pkgs.cpio}/bin/cpio -o -H newc --owner root:root > $out
  '';
in
{
  options.windows-vm = {
    guestGpu = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      default = null;
      example = [
        "0000:01:00.0"
        "0000:01:00.1"
      ];
      description = "PCI functions passed to the guest. Default: the NVIDIA card in the facter report.";
    };
    passAudio = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Pass the GPU's HDMI audio function too. Turn off if VM restarts fail:
        on one RTX 5090 report its FLR was the part that hung. Audio still
        goes through SPICE.
      '';
    };
    evdevDevices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = [
        "/dev/input/by-id/usb-BY_Tech_Gaming_Keyboard-event-kbd"
        "/dev/input/by-id/usb-Razer_Razer_DeathAdder_V2_Mini-event-mouse"
      ];
      description = ''
        Physical keyboard/mouse evdev nodes passed straight to the guest
        (libvirt input passthrough). While grabbed they are gone from the
        host; press Scroll Lock to toggle the grab. Needed because the
        SPICE mouse is mapped to the SPICE console's display, not the
        VDD/Looking Glass one.
      '';
    };
    maxResolution = lib.mkOption {
      type = lib.types.str;
      default = "3840x2160";
      description = "Largest guest resolution Looking Glass must carry (SDR). Sizes kvmfr.";
    };
    evdevGrabToggle = lib.mkOption {
      type = lib.types.str;
      default = "scrolllock";
      example = "ctrl+space";
      description = ''
        Key that toggles the evdev grab between host and guest. qemu combos
        (ctrl-ctrl, alt-alt, shift-shift, meta-meta, scrolllock,
        ctrl-scrolllock) go straight to qemu. Any other "mod+key" combo
        (e.g. "ctrl+space", "alt+a") is handled by an evsieve layer that
        turns the chord into Scroll Lock for qemu.
      '';
    };
    lgSpiceInput = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Let the Looking Glass client forward keyboard/mouse over SPICE.
        Off (default): input goes only through evdev passthrough. With both
        enabled the guest gets duplicated events and the host desktop also
        runs host shortcuts for keys meant for the guest.
      '';
    };
    virtualConsole = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Attach a virtual VGA console (SPICE on 127.0.0.1:5900) for
        install/recovery when the passed GPU has no picture yet. Off for
        normal Looking Glass use: the emulated adapter competes for the
        primary-display role with the real GPU.
      '';
    };
    gpuHandover = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Keep the guest GPU on its Linux driver (nvidia) at boot and hand it
        to vfio-pci only while the VM runs: the qemu hook stops the units in
        gpuSystemUnits/gpuUserUnits and unloads the NVIDIA modules, libvirt
        detaches the card (managed='yes'), and after the VM stops it is
        reattached and the units restarted. Off: the card is bound to
        vfio-pci in the initrd and NVIDIA is blacklisted.
      '';
    };
    user = lib.mkOption {
      type = lib.types.str;
      description = "Desktop user who owns the VM (kvm group, polkit rule, user units).";
    };
    gpuSystemUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        System units that hold the GPU and are stopped while the VM runs,
        restarted after. windows-vm.service declares Conflicts= on them, so
        starting either side stops the other.
      '';
    };
    gpuUserUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Same as gpuSystemUnits, for the desktop user's systemd --user units.";
    };
    amdIommu = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Add amd_iommu=on (AMD platforms; Intel uses intel_iommu=on which this module does not add).";
    };
    gpuFlrWorkaround = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Add vfio_pci.disable_idle_d3=1: keep the card in D0 while vfio owns
        it. Workaround for the RTX 5090 FLR/D3cold reset defect.
      '';
    };
    viewerPackage = lib.mkOption {
      type = lib.types.package;
      default = pkgs.looking-glass-client;
      defaultText = lib.literalExpression "pkgs.looking-glass-client";
      description = ''
        Looking Glass client used by `win-vm viewer` / `win-vm start`. A
        desktop overlay can wrap it (e.g. an X11/Xwayland auth wrapper for
        GNOME Wayland).
      '';
    };
    ivrsOverride = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Prepend an initrd-patched IVRS ACPI table that drops the firmware's
        IVMD exclusion ranges (they make kernel 7 refuse VFIO for every device
        on the affected PCI buses). Board-specific: requires ivrsDump. Set to
        false once the firmware stops shipping them.
      '';
    };
    ivrsDump = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Raw dump of this board's firmware IVRS table (kept in the consuming
        repo, not here — every board's table differs):
          sudo cp /sys/firmware/acpi/tables/IVRS ivrs-orig
        patch-ivrs.py drops the IVMD blocks and bumps the OEM revision at
        build time. Re-dump after a BIOS update and check the build log for
        what got dropped.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = guestGpu != [ ] && (cfg.guestGpu != null || lib.length gpus >= 2);
        message = ''
          windows-vm: GPU passthrough needs a second GPU for the host desktop.
          The facter report lists ${toString (lib.length gpus)} GPU(s) and windows-vm.guestGpu is
          unset. Enable the iGPU in firmware and regenerate the facter report, or set
          windows-vm.guestGpu explicitly.
        '';
      }
      {
        assertion = !cfg.ivrsOverride || cfg.ivrsDump != null;
        message = "windows-vm: ivrsOverride = true requires ivrsDump (a raw dump of this board's /sys/firmware/acpi/tables/IVRS).";
      }
    ];

    boot.kernelParams =
      [ "iommu=pt" ]
      ++ lib.optional cfg.amdIommu "amd_iommu=on"
      ++ lib.optional cfg.gpuFlrWorkaround "vfio_pci.disable_idle_d3=1";
    boot.initrd.kernelModules = [
      "vfio_pci"
      "vfio"
      "vfio_iommu_type1"
    ];
    # By PCI address, not vfio-pci.ids: ids would also grab an identical host card.
    # PCI devices exist before udev's coldplug, so claiming them here means the
    # GPU driver never probes them; drivers_probe makes the order of module
    # loading irrelevant.
    boot.initrd.systemd.services.vfio-guest-gpu = lib.mkIf (!cfg.gpuHandover) {
      description = "Bind the guest GPU to vfio-pci";
      wantedBy = [ "sysinit.target" ];
      before = [
        "systemd-udev-trigger.service"
        "sysinit.target"
      ];
      after = [ "systemd-modules-load.service" ];
      unitConfig.DefaultDependencies = false;
      serviceConfig.Type = "oneshot";
      script = ''
        modprobe vfio-pci
      ''
      + lib.concatMapStrings (a: ''
        if [ -e /sys/bus/pci/devices/${a} ]; then
          echo vfio-pci > /sys/bus/pci/devices/${a}/driver_override
          echo ${a} > /sys/bus/pci/drivers_probe || true
        fi
      '') guestGpu;
    };
    boot.blacklistedKernelModules = [
      "nouveau"
    ]
    ++ lib.optionals (!cfg.gpuHandover) [
      "nvidia"
      "nvidia_drm"
      "nvidia_modeset"
    ];
    # Shared by win-vm (as the user) and win-sync (as root): both open it
    # read-write for flock, and only root can create files in /run.
    systemd.tmpfiles.rules = [ "f /run/win-disk.lock 0660 root kvm - -" ];

    services.udev.extraRules = lib.concatMapStrings (a: ''
      ACTION=="add", SUBSYSTEM=="pci", KERNEL=="${a}", ATTR{power/control}="on", ATTR{d3cold_allowed}="0"
    '') guestGpu
    + lib.optionalString useEvsieve ''
      SUBSYSTEM=="input", ATTRS{name}=="winvm-kbd", SYMLINK+="input/winvm-kbd"
    '';

    systemd.services.win-vm-evsieve = lib.mkIf useEvsieve {
      description = "Map the grab-toggle chord to the qemu evdev grab toggle (Scroll Lock)";
      wantedBy = [ "multi-user.target" ];
      # qemu holds the virtual device by path: restarting evsieve recreates
      # it under a new eventN and the running guest loses its keyboard.
      restartIfChanged = false;
      serviceConfig = {
        ExecStart = "${pkgs.evsieve}/bin/evsieve --input ${lib.escapeShellArg (builtins.head cfg.evdevDevices)} grab --hook key:leftctrl key:leftalt key:esc send-key=key:scrolllock --hook key:leftctrl key:space send-key=key:scrolllock --output create-link=/dev/input/by-id/winvm-kbd";
        Restart = "on-failure";
      };
    };


    virtualisation.libvirtd.qemu.verbatimConfig = ''
      namespaces = []
      # The input nodes must be INSIDE cgroup_device_acl: evdev passthrough
      # goes through qemu:commandline (libvirt strips grabToggle), so libvirt
      # doesn't whitelist the nodes itself. Trusted VMs only on this host.
      # NOTE: no comments inside the list — libvirt's conf parser rejects
      # them ("expecting a value") and libvirtd dies on boot.
      cgroup_device_acl = [
        "/dev/null", "/dev/full", "/dev/zero",
        "/dev/random", "/dev/urandom",
        "/dev/ptmx", "/dev/kvm",
        "/dev/userfaultfd",
        ${lib.concatMapStringsSep ", " (n: "\"/dev/input/event${toString n}\"") (lib.genList lib.id 32)}
      ]
    '';
    virtualisation.libvirtd.hooks.qemu.win-vm = hook;
    # libvirtd-config.service refreshes the hooks dir only when it runs
    # (boot); a switch that only changes the hook would keep the stale
    # symlink until the next reboot. Point ours at the current build on
    # every activation.
    system.activationScripts.win-vm-hook = ''
      mkdir -p /var/lib/libvirt/hooks/qemu.d
      ln -sfn ${hook} /var/lib/libvirt/hooks/qemu.d/win-vm
    '';

    users.users.${cfg.user}.extraGroups = [ "kvm" ];

    environment.systemPackages = [ winVm ];

    # The toggle: `systemctl start windows-vm` (or `win-vm start`, which
    # delegates to it) stops the GPU units via Conflicts=; starting one of
    # them back stops the VM the same way. The hook does the rest (nvidia
    # unload, hugepages, CPU isolation, and on release it restarts what it
    # stopped — ExecStopPost must NOT start conflicting units: systemd
    # serializes the conflicting start job behind this unit's stop, which
    # waits for ExecStopPost — a deadlock until TimeoutStopSec kills it).
    systemd.services.windows-vm = {
      description = "Windows gaming VM (disk Windows install, GPU passthrough)";
      conflicts = cfg.gpuSystemUnits;
      after = cfg.gpuSystemUnits;
      environment.WIN_VM_DIRECT = "1";
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = cfg.user;
        ExecStart = "${winVm}/bin/win-vm start --no-viewer";
        ExecStop = "${winVm}/bin/win-vm stop";
        TimeoutStartSec = 600;
        TimeoutStopSec = 300;
      };
    };

    # The GPU units may be imperative (hand-written unit files); let the user
    # flip units without a password prompt.
    security.polkit.extraConfig =
      let
        allowed = lib.concatStringsSep "|" ([ "windows-vm\\.service" ] ++ map lib.escapeRegex cfg.gpuSystemUnits);
      in
      ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              subject.user == "${cfg.user}" &&
              action.lookup("unit") &&
              action.lookup("unit").match(/^(${allowed})$/)) {
            return polkit.Result.YES;
          }
        });
      '';

    # QEMU maps guest RAM from hugetlbfs (hugepages + shared for iommufd DMA).
    fileSystems."/dev/hugepages" = {
      device = "hugetlbfs";
      fsType = "hugetlbfs";
      options = [ "mode=0770" ];
    };

    boot.initrd.prepend = lib.mkIf cfg.ivrsOverride [ "${ivrsOverrideCpio}" ];
  };
}
