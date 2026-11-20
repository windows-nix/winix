# NixOS VM test for win-sync and win-vm's shared disk checks.
# Build: nix build -L .#checks.x86_64-linux.win-sync
{ pkgs, ... }:
let
  stub = pkgs.runCommand "windows-config-stub" { } ''
    mkdir -p $out/installers/x
    echo '@echo apply' > $out/apply.cmd
    echo payload > $out/installers/x/file.txt
  '';
  winVm = pkgs.writers.writePython3Bin "win-vm" {
    flakeIgnore = [ "E501" ];
  } (builtins.readFile ./win_vm.py);
  # libvirt is not in the test VM; state comes from /tmp/virsh-state.
  fakeVirsh = pkgs.writeShellScriptBin "virsh" ''
    cat /tmp/virsh-state 2>/dev/null || echo "shut off"
  '';
  # Sets VOLUME_IS_DIRTY in $Volume's $VOLUME_INFORMATION, as an unclean
  # Windows shutdown leaves it.
  ntfsDirty = pkgs.writers.writePython3Bin "ntfs-dirty" { } ''
    import struct
    import sys

    with open(sys.argv[1], "r+b") as f:
        boot = f.read(512)
        bps, spc = struct.unpack_from("<HB", boot, 0x0B)
        mft_lcn = struct.unpack_from("<Q", boot, 0x30)[0]
        cpr = struct.unpack_from("<b", boot, 0x40)[0]
        rec = 1 << -cpr if cpr < 0 else cpr * bps * spc
        base = mft_lcn * bps * spc + 3 * rec  # MFT record 3 = $Volume
        f.seek(base)
        r = bytearray(f.read(rec))
        assert r[:4] == b"FILE", r[:4]
        off = struct.unpack_from("<H", r, 0x14)[0]
        while True:
            typ, length = struct.unpack_from("<II", r, off)
            assert typ != 0xFFFFFFFF, "no $VOLUME_INFORMATION"
            if typ == 0x70:
                flags = off + struct.unpack_from("<H", r, off + 0x14)[0] + 0x0A
                if sys.argv[2:] == ["--clear"]:
                    r[flags] &= ~1 & 0xFF
                else:
                    r[flags] |= 1
                break
            off += length
        f.seek(base)
        f.write(r)
  '';
in
pkgs.testers.runNixOSTest {
  name = "win-sync";
  nodes.machine = {
    imports = [ ./win-sync.nix ];
    services.win-sync.source = stub;
    virtualisation.cores = 2;
    virtualisation.emptyDiskImages = [
      {
        size = 512;
        driveConfig.deviceExtraOpts.serial = "windisk";
      }
    ];
    environment.systemPackages = [
      winVm
      fakeVirsh
      ntfsDirty
      pkgs.gptfdisk
      pkgs.dosfstools
      pkgs.ntfs3g
      pkgs.util-linux
    ];
  };

  testScript = ''
    def refuses(cmd, needle):
        out = machine.fail(f"{cmd} 2>&1")
        assert needle in out, f"{needle!r} not in output of {cmd}:\n{out}"
        return out

    def on(part, script):
        machine.succeed(f"mkdir -p /mnt && mount -t ntfs3 {part} /mnt && (cd /mnt && {script}); umount /mnt")

    def label(n, name):
        machine.succeed(f"sgdisk -c {n}:{name} /dev/vdb && udevadm settle")

    T = "ProgramData/machine-config"
    DRY = "WIN_VM_ROOT=/fake win-vm start --dry-run"

    machine.wait_for_unit("multi-user.target")
    machine.succeed(
        "sgdisk -n1:0:+64M -t1:ef00 -c1:win-esp -n2:0:+200M -t2:0700 -c2:win-c"
        " -n3:0:0 -t3:0700 -c3:games /dev/vdb",
        "udevadm settle",
        "mkfs.vfat /dev/vdb1",
        "mkfs.ntfs -f -L win-c /dev/vdb2",
        "mkfs.ntfs -f -L games /dev/vdb3",
        "udevadm trigger --settle",
    )
    on("/dev/vdb2", "mkdir -p Windows/System32/config && printf 'regf\\0\\0' > Windows/System32/config/SYSTEM")
    # win-vm --dry-run needs a host with >= 12 GiB; fake topology and meminfo.
    machine.succeed(
        "mkdir -p /fake/proc && cp /proc/cpuinfo /fake/proc/",
        "echo 'MemTotal: 67108864 kB' > /fake/proc/meminfo",
        "c=/fake/sys/devices/system/cpu; mkdir -p $c && echo 0-1 > $c/online;"
        " for i in 0 1; do mkdir -p $c/cpu$i/topology $c/cpu$i/cache/index3;"
        " echo $i > $c/cpu$i/topology/thread_siblings_list;"
        " echo 0-1 > $c/cpu$i/cache/index3/shared_cpu_list;"
        " echo 32768K > $c/cpu$i/cache/index3/size; done",
    )

    with subtest("by-partlabel target, idempotent, logs/ and virtio-staged kept"):
        machine.succeed("win-sync")
        on("/dev/vdb2", f"grep -q apply {T}/apply.cmd && grep -q payload {T}/installers/x/file.txt"
                        f" && mkdir -p {T}/logs && echo l > {T}/logs/run.log && touch {T}/virtio-staged {T}/stale")
        machine.succeed("win-sync")
        on("/dev/vdb2", f"test -f {T}/logs/run.log && test -f {T}/virtio-staged && ! test -e {T}/stale"
                        f" && test -w {T}/apply.cmd")
        assert machine.succeed("win-vm find-disk").strip() == "/dev/vdb2"
        assert "/mnt" not in machine.succeed("findmnt -rno TARGET")
        assert machine.succeed("ls /tmp | grep -c win-sync || true").strip() == "0"

    with subtest("label on a non-NTFS partition"):
        label(2, "win-c-old")
        label(1, "win-c")
        refuses("win-sync", "not NTFS")
        label(1, "win-esp")

    with subtest("label lost: scan finds the partition"):
        machine.succeed("udevadm settle; ! test -e /dev/disk/by-partlabel/win-c")
        out = machine.succeed("win-sync 2>&1")
        assert "/dev/vdb2" in out, out
        assert machine.succeed("win-vm find-disk").strip() == "/dev/vdb2"

    with subtest("two Windows partitions: refuses and lists both"):
        on("/dev/vdb3", "mkdir -p Windows/System32/config && printf 'regf' > Windows/System32/config/SYSTEM")
        out = refuses("win-sync", "several Windows partitions")
        assert "/dev/vdb2" in out and "/dev/vdb3" in out, out
        refuses("win-vm find-disk", "several Windows installs")
        on("/dev/vdb3", "rm -r Windows")

    with subtest("no Windows partition"):
        on("/dev/vdb2", "mv Windows/System32/config/SYSTEM Windows/System32/config/SYSTEM.bak")
        refuses("win-sync", "no Windows partition found")
        refuses("win-vm find-disk", "no Windows disk found")
        on("/dev/vdb2", "mv Windows/System32/config/SYSTEM.bak Windows/System32/config/SYSTEM")
        label(2, "win-c")

    with subtest("hibernated: refuses without writing"):
        on("/dev/vdb2", f"printf HIBRxxxx > hiberfil.sys && rm {T}/apply.cmd")
        refuses("win-sync", "hibernated")
        on("/dev/vdb2", f"! test -e {T}/apply.cmd")
        out = machine.succeed(f"{DRY} 2>&1 >/dev/null")
        assert "would refuse: Windows is hibernated" in out, out
        on("/dev/vdb2", "printf 'wake' > hiberfil.sys")
        refuses("win-sync", "hibernated")
        on("/dev/vdb2", "printf '\\0\\0\\0\\0' > hiberfil.sys")
        machine.succeed("win-sync")

    with subtest("dirty volume: ntfs3 refusal is surfaced"):
        machine.succeed("ntfs-dirty /dev/vdb2")
        refuses("win-sync", "ntfs3 refuses volumes marked dirty")
        assert "/mnt" not in machine.succeed("findmnt -rno TARGET")
        machine.succeed("ntfs-dirty /dev/vdb2 --clear", "win-sync")

    with subtest("lock held"):
        machine.succeed("(flock /run/win-disk.lock sleep 600 >/dev/null 2>&1 &) && sleep 1")
        refuses("win-sync", "/run/win-disk.lock is held")
        refuses("WIN_VM_ROOT=/fake win-vm start --no-viewer", "the Windows disk is in use")
        machine.succeed("pkill -x flock; pkill -x sleep; true")
        machine.succeed("win-sync")

    with subtest("partition mounted"):
        machine.succeed("mkdir -p /games && mount -t ntfs3 /dev/vdb3 /games")
        refuses("win-sync", "/dev/vdb3 is mounted at /games")
        machine.succeed("touch /tmp/x")
        out = machine.succeed(f"{DRY} 2>&1 >/dev/null")
        assert "would refuse: /dev/vdb3 is mounted at /games" in out, out
        machine.succeed("umount /games")
        out = machine.succeed(f"{DRY} 2>&1 >/dev/null")
        assert "would refuse" not in out, out

    with subtest("block device held open by a process"):
        machine.succeed("(sleep 600 < /dev/vdb >/dev/null 2>&1 &) && sleep 1")
        refuses("win-sync", "/dev/vdb is held open by PID")
        machine.succeed("pkill -x sleep; sleep 1")
        machine.succeed("win-sync")

    with subtest("VM running"):
        machine.succeed("echo running > /tmp/virsh-state")
        refuses("win-sync", "win10 is running")
        machine.succeed("rm /tmp/virsh-state", "win-sync")
  '';
}
