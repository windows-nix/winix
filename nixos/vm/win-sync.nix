# win-sync: copy the Windows config folder (outputs.windowsConfigurations.mbox) to
# ProgramData\machine-config on the disk2 Windows partition, through ntfs3.
# On demand only: `sudo win-sync`. Nothing runs at boot, nothing needs disk2.
# openspec/changes/windows-config ("Safe delivery to a Windows partition").
#
# Disk rules are shared with win-vm by importing ./win_vm.py: the
# /run/win-disk.lock lock, mounted / open-LUKS / hibernation refusals and the
# NTFS scan for Windows/System32/config/SYSTEM. Test: ./test-win-sync.nix.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.services.win-sync;
  winVmLib = pkgs.writeTextDir "win_vm.py" (builtins.readFile ./win_vm.py);
  path = lib.makeBinPath [
    pkgs.util-linux
    pkgs.ntfs3g
    pkgs.rsync
    pkgs.psmisc
  ];
  winSync =
    pkgs.writers.writePython3Bin "win-sync"
      {
        flakeIgnore = [
          "E402"
          "E501"
        ];
      }
      ''
        import fcntl
        import os
        import shutil
        import subprocess
        import sys
        import tempfile

        sys.path.insert(0, "${winVmLib}")
        os.environ["PATH"] = "${path}:" + os.environ.get("PATH", "")
        import win_vm as wv

        DEVICE = "${cfg.device}"
        SOURCE = "${cfg.source}"
        DEST = "ProgramData/machine-config"
        KEEP = ["/logs/", "/virtio-staged"]  # written by apply on the Windows side


        def die(msg):
            print(f"win-sync: {msg}", file=sys.stderr)
            sys.exit(1)


        def run(*cmd, check=False):
            return subprocess.run(cmd, text=True, capture_output=True, check=check)


        def target():
            if os.path.exists(DEVICE):
                return os.path.realpath(DEVICE)
            found = []
            for line in run("lsblk", "-rno", "PATH,FSTYPE").stdout.splitlines():
                p, _, fs = line.partition(" ")
                if fs == "ntfs" and wv.ntfs_head(p, "Windows/System32/config/SYSTEM") == b"regf":
                    found.append(p)
            if not found:
                die(f"{DEVICE} does not exist and no Windows partition found")
            if len(found) > 1:
                die(f"{DEVICE} does not exist and several Windows partitions were found: {' '.join(found)}")
            return found[0]


        def main():
            if os.geteuid() != 0:
                die("needs root: sudo win-sync")
            fd = os.open(wv.LOCK, os.O_RDWR | os.O_CREAT, 0o660)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                die(f"the Windows disk is in use ({wv.LOCK} is held by win-vm or another win-sync)")
            if shutil.which("virsh") and run("virsh", "-c", wv.URI, "domstate", wv.NAME).stdout.strip() == "running":
                die(f"VM {wv.NAME} is running; stop it first (win-vm stop)")

            part = target()
            fs = run("lsblk", "-no", "FSTYPE", part).stdout.strip()
            if fs != "ntfs":
                die(f"{part} is {fs or 'unformatted'}, not NTFS")
            disk = wv.parent_disk(part)
            refusals = wv.disk_refusals(disk, part)
            held = run("fuser", *run("lsblk", "-rno", "PATH", disk).stdout.split())
            if held.returncode == 0:
                refusals.append(f"{disk} is held open by PID {' '.join(held.stdout.split())}")
            if refusals:
                die("\n  ".join([f"refusing to write {part}:"] + refusals))

            mnt = tempfile.mkdtemp(prefix="win-sync.")
            try:
                m = run("mount", "-t", "ntfs3", "-o", "rw,noatime", part, mnt)
                if m.returncode != 0:
                    # ntfs3 refuses volumes marked dirty (fast startup, unclean VM
                    # stop). ntfsfix -d only clears the flag — metadata, no file
                    # changes; a genuinely damaged volume still needs chkdsk /f
                    # in Windows, which it will then complain about on its own.
                    f = run("ntfsfix", "-d", part, check=False)
                    if f.returncode == 0:
                        print(f"win-sync: {part} was marked dirty, flag cleared; retrying mount")
                        m = run("mount", "-t", "ntfs3", "-o", "rw,noatime", part, mnt)
                if m.returncode != 0:
                    die(f"mount -t ntfs3 {part} failed: {m.stderr.strip()}\n"
                        "  ntfs3 refuses volumes marked dirty and ntfsfix could not clear it: "
                        "boot Windows, shut it down fully (or chkdsk /f), then retry")
                try:
                    dest = os.path.join(mnt, DEST)
                    os.makedirs(dest, exist_ok=True)
                    # --chmod: store files are read-only, and ntfs3 maps that to the
                    # DOS read-only attribute, which would block apply and the next sync.
                    r = subprocess.run([
                        "rsync", "-rt", "--delete", "--no-perms", "--no-owner", "--no-group",
                        "--chmod=ugo=rwX", "--modify-window=2",
                        *[f"--exclude={k}" for k in KEEP],
                        SOURCE + "/", dest + "/"])
                    if r.returncode != 0:
                        die(f"rsync failed (exit {r.returncode})")
                finally:
                    u = run("umount", mnt)
                    if u.returncode != 0:
                        die(f"umount {mnt} failed: {u.stderr.strip()}; unmount it before booting Windows")
            finally:
                if not os.path.ismount(mnt):
                    os.rmdir(mnt)
            print(f"win-sync: {SOURCE} -> {part}:/{DEST}")


        main()
      '';
in
{
  options.services.win-sync = {
    device = lib.mkOption {
      type = lib.types.str;
      default = "/dev/disk/by-partlabel/win-c";
      description = "Windows system partition. If missing, NTFS partitions are scanned for a Windows install.";
    };
    source = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression "outputs.windowsConfigurations.mbox.config.build.folder";
      description = "Folder copied to ProgramData\\machine-config.";
    };
  };

  config.environment.systemPackages = [ winSync ];
}
