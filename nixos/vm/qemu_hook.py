"""libvirt qemu hook for the win-vm domain: host isolation only while it runs.

Called as `<hook> <domain> <operation> <sub-op> -` with the domain XML on stdin.
prepare/begin: hugepages, slice AllowedCPUs, IRQ affinity, guest-core EPP/governor;
               with handover='1', stop GPU users and unload nvidia so libvirt
               can detach the card (managed='yes' runs after this hook).
release/end:   undo all of it from the saved state (libvirt has reattached the
               card by then; nvidia is loaded again and its users restarted).
A non-zero exit on prepare makes libvirt abort the start.
"""
import grp
import json
import os
import pwd
import subprocess
import sys
import time
import xml.etree.ElementTree as ET
from pathlib import Path

NAME = "win11"
NS = "urn:mbox:win-vm"
STATE = Path("/run/win-vm-hook.json")
SLICES = ["system.slice", "user.slice", "init.scope"]
CPU = Path("/sys/devices/system/cpu")
# Looking Glass ivshmem backing on hugetlbfs. /dev/hugepages is root-only
# (mode=0770, and win-vm runs as the user), so this hook creates and owns the
# file; qemu and the LG client just open it.
SHM_PATH = Path("/dev/hugepages/looking-glass")
SHM_PAGE_KIB = 2048
# GPU users to stop while the VM owns the card. System units via systemctl,
# user units (handy, ...) via the user manager; both from the module's env.
GPU_SYSTEM_UNITS = os.environ.get("WIN_VM_HOOK_SYSTEM_UNITS", "").split()
GPU_USER_UNITS = os.environ.get("WIN_VM_HOOK_USER_UNITS", "").split()
HOOK_USER = os.environ.get("WIN_VM_HOOK_USER", "")
NVIDIA_MODULES = ["nvidia_uvm", "nvidia_drm", "nvidia_modeset", "nvidia"]


def user_systemctl(*args):
    """systemctl --user as HOOK_USER; returns None without a user configured."""
    if not HOOK_USER:
        return None
    uid = pwd.getpwnam(HOOK_USER).pw_uid
    return subprocess.run(
        ["runuser", "-u", HOOK_USER, "--", "env", f"XDG_RUNTIME_DIR=/run/user/{uid}",
         "systemctl", "--user", *args], capture_output=True, text=True)


def gpu_release():
    """Free the card for vfio. Returns ([system units], [user units]) that ran."""
    active = [u for u in GPU_SYSTEM_UNITS
              if subprocess.run(["systemctl", "is-active", "-q", u]).returncode == 0]
    active_user = []
    if HOOK_USER:
        active_user = [u for u in GPU_USER_UNITS
                       if user_systemctl("is-active", "-q", u).returncode == 0]
    # Stop unconditionally, not only when already active: a unit that is still
    # activating (handy autostarts right after login) would otherwise win the
    # race and keep nvidia_drm busy.
    if GPU_SYSTEM_UNITS:
        subprocess.run(["systemctl", "stop", *GPU_SYSTEM_UNITS], check=False)
    if GPU_USER_UNITS:
        user_systemctl("stop", *GPU_USER_UNITS)
    subprocess.run(["modprobe", "-r", *NVIDIA_MODULES], check=False)
    loaded = Path("/proc/modules").read_text()
    stuck = [m for m in NVIDIA_MODULES if loaded.startswith(m + " ")]
    if stuck:
        gpu_restore((active, active_user))
        log(f"cannot unload nvidia ({', '.join(stuck)} still loaded; a desktop "
            "app such as Epiphany may hold /dev/nvidia0)")
        sys.exit(1)
    return active, active_user


def gpu_restore(units):
    system_units, user_units = units
    subprocess.run(["modprobe", "nvidia_uvm"], check=False)
    if system_units:
        subprocess.run(["systemctl", "start", "--no-block", *system_units], check=False)
    if user_units:
        user_systemctl("start", "--no-block", *user_units)


def log(msg):
    print(f"win-vm-hook: {msg}", file=sys.stderr)


def write(path, value):
    try:
        Path(path).write_text(str(value))
        return True
    except OSError:
        return False


def pages_path(kib):
    return Path(f"/sys/kernel/mm/hugepages/hugepages-{kib}kB/nr_hugepages")


def set_cpus(cpus):
    for s in SLICES:
        subprocess.run(["systemctl", "set-property", "--runtime", "--", s, f"AllowedCPUs={cpus}"],
                       check=False)


def irq_affinity(cpus):
    write("/proc/irq/default_smp_affinity_list", cpus)  # absent on some kernels; harmless
    for irq in Path("/proc/irq").iterdir():
        if irq.is_dir():
            write(irq / "smp_affinity_list", cpus)  # per-CPU IRQs refuse; expected


def guest_power(cpus, saved=None):
    """Set EPP/governor to performance on guest cpus; with `saved`, restore it."""
    old = {}
    for c in cpus:
        base = CPU / f"cpu{c}/cpufreq"
        for knob in ("energy_performance_preference", "scaling_governor"):
            f = base / knob
            if not f.exists():
                continue
            if saved is None:
                old[f"{c}/{knob}"] = f.read_text().strip()
                if knob == "scaling_governor" and (base / "energy_performance_preference").exists():
                    continue  # amd-pstate-epp: EPP is the knob; keep the governor
                write(f, "performance")
            elif f"{c}/{knob}" in saved:
                write(f, saved[f"{c}/{knob}"])
    return old


def all_cpus():
    return (CPU / "online").read_text().strip()


def parse_list(s):
    out = []
    for part in s.split(","):
        a, _, b = part.partition("-")
        out += range(int(a), int(b or a) + 1)
    return out


def alloc_pages(kib, need):
    """Grow the kib pool by `need` pages; return (before, got)."""
    nr = pages_path(kib)
    before = int(nr.read_text())
    target = before + need
    for _ in range(3):
        write(nr, target)
        if int(nr.read_text()) >= target:
            break
        time.sleep(1)
        write("/proc/sys/vm/compact_memory", 1)
    return before, int(nr.read_text()) - before


def shm_file(shm_pages):
    """Create/size the ivshmem backing root:kvm 0660 (qemu and the client
    open it; hugetlbfs faults draw from the pool reserved above)."""
    if shm_pages <= 0:
        return
    fd = os.open(SHM_PATH, os.O_RDWR | os.O_CREAT, 0o660)
    try:
        os.ftruncate(fd, shm_pages * SHM_PAGE_KIB * 1024)
    finally:
        os.close(fd)
    os.chown(SHM_PATH, 0, grp.getgrnam("kvm").gr_gid)
    os.chmod(SHM_PATH, 0o660)


def prepare(meta):
    # evsieve owns the physical keyboard only while the VM runs.
    subprocess.run(["systemctl", "start", "win-vm-evsieve"], check=False)
    gpu_units = gpu_release() if meta.get("handover") == "1" else None
    kib, pages = int(meta["pagekib"]), int(meta["pages"])
    shm_pages = int(meta.get("shmpages", 0))
    # The ivshmem/Looking Glass backing lives on hugetlbfs at the default
    # (2M) page size regardless of the guest's RAM page size; same-size
    # needs merge into one pool bump.
    needs = {2048: shm_pages}
    needs[kib] = needs.get(kib, 0) + pages
    write("/proc/sys/vm/drop_caches", 3)
    write("/proc/sys/vm/compact_memory", 1)
    pools = []
    ok = True
    for pk in sorted(needs):
        need = needs[pk]
        if need <= 0:
            continue
        before, got = alloc_pages(pk, need)
        pools.append((pk, before, got))
        if got < need:
            ok = False
            break
    if not ok:
        for pk, before, _ in pools:
            write(pages_path(pk), before)
        if gpu_units is not None:
            gpu_restore(gpu_units)
        log(f"hugepages unavailable ({kib} KiB x {pages}, 2048 KiB x {shm_pages}); freed them")
        sys.exit(1)
    shm_file(shm_pages)
    Path("/run/win-vm-input-state").write_text("guest")
    state = {"pools": [[pk, before, got] for pk, before, got in pools],
             "allcpus": all_cpus(), "gpu_units": gpu_units}
    set_cpus(meta["hostcpus"])
    irq_affinity(meta["hostcpus"])
    state["power"] = guest_power(parse_list(meta["guestcpus"]))
    STATE.write_text(json.dumps(state))


def release():
    if not STATE.exists():
        return
    state = json.loads(STATE.read_text())
    set_cpus(state["allcpus"])
    irq_affinity(state["allcpus"])
    guest_power([int(k.split("/")[0]) for k in state["power"]], state["power"])
    # Tolerate pre-pools state files written by older hooks.
    pools = state.get("pools")
    if pools is None and "pagekib" in state:
        pools = [[state["pagekib"], 0, state["pages"]]]
    for kib, before, got in pools or []:
        nr = pages_path(kib)
        # Pool may have been resized meanwhile; never hand pages back the
        # pool no longer holds, and never resurrect pre-VM reservations.
        write(nr, max(before, int(nr.read_text()) - got))
    Path("/run/win-vm-input-state").write_text("host")
    # Stopping evsieve releases the physical keyboard back to the host.
    subprocess.run(["systemctl", "stop", "win-vm-evsieve"], check=False)
    if state.get("gpu_units") is not None:
        gpu_restore(state["gpu_units"])
    STATE.unlink()


def main():
    name, op, sub = sys.argv[1:4]
    if name != NAME:
        return
    if op == "prepare" and sub == "begin":
        meta = ET.fromstring(sys.stdin.read()).find(f".//{{{NS}}}vm")
        if meta is None:
            log("domain XML has no win-vm metadata; start it with win-vm")
            sys.exit(1)
        release()  # stale state from a crashed run
        prepare(meta.attrib)
    elif op == "release" and sub == "end":
        release()


if __name__ == "__main__":
    main()
