"""win-vm: boot the disk2 Windows install as a KVM guest with GPU passthrough.

Config comes from the environment, set by the Nix wrapper (nixos/windows-vm.nix):
  WIN_VM_GPU        space-separated PCI addresses passed to the guest
  WIN_VM_KVMFR      kvmfr size in bytes
  WIN_VM_HANDOVER   "1": the GPU stays on its host driver until start; libvirt
                    detaches it (managed='yes') after the hook unloads nvidia
  WIN_VM_ROOT       sysfs/procfs prefix (tests only)
"""
import argparse
import fcntl
import os
import re
import subprocess
import sys
import time
from pathlib import Path

NAME = "win11"
UUID = "6d1b5f0e-4c0a-4e8e-9b5e-6d626f780a10"  # fixed: keys NVRAM and swtpm state
LOCK = "/run/win-disk.lock"
# ivshmem backing on hugetlbfs: iommufd maps it via IOMMU_IOAS_MAP_FILE, and
# only pin-backed files (hugetlbfs) map into a passthrough IOAS — tmpfs takes
# the kernel's fault path, which needs a fault-capable HWPT (SVA/PRI) the
# passthrough GPU doesn't have, and the kvmfr chardev has no filemap at all.
# Both fail with EINVAL ("vfio: DMA mapping failed") ~2 s into the guest boot.
# Must live in /dev/hugepages (mode 0770 root:kvm; the unit runs as the user).
SHM = "/dev/hugepages/looking-glass"
SHM_PAGE_KIB = 2048  # hugetlbfs default page size; the hook reserves this many pages
URI = "qemu:///system"
ROOT = os.environ.get("WIN_VM_ROOT", "")
GIB = 1 << 30


def die(msg):
    print(f"win-vm: {msg}", file=sys.stderr)
    sys.exit(1)


def sysread(path):
    return Path(ROOT + path).read_text().strip()


def parse_list(s):
    """'0-3,8,10-11' -> [0,1,2,3,8,10,11]"""
    out = []
    for part in s.split(","):
        if "-" in part:
            a, b = part.split("-")
            out += range(int(a), int(b) + 1)
        elif part:
            out.append(int(part))
    return out


def fmt_list(cpus):
    return ",".join(str(c) for c in sorted(cpus))


def size_kib(s):
    m = re.fullmatch(r"(\d+)([KMG]?)", s)
    return int(m[1]) * {"": 1, "K": 1, "M": 1024, "G": 1 << 20}[m[2]] // (1 if m[2] else 1024)


# --- topology ---------------------------------------------------------------

def topology():
    """L3 domains: [{cpus, size_kib}], cpus online only, plus sibling map."""
    base = "/sys/devices/system/cpu"
    online = parse_list(sysread(f"{base}/online"))
    domains, siblings = {}, {}
    for c in online:
        siblings[c] = tuple(parse_list(sysread(f"{base}/cpu{c}/topology/thread_siblings_list")))
        l3 = f"{base}/cpu{c}/cache/index3"
        key = sysread(f"{l3}/shared_cpu_list")
        d = domains.setdefault(key, {"cpus": [], "size_kib": size_kib(sysread(f"{l3}/size"))})
        d["cpus"].append(c)
    return list(domains.values()), siblings


def cores_of(cpus, siblings):
    """Group cpus into SMT sibling tuples, ordered by first thread."""
    return sorted({siblings[c] for c in cpus})


def choose_cpus(domains, siblings):
    """Return (guest_cores, host_cpus). guest_cores is a list of sibling tuples."""
    all_cpus = sorted(c for d in domains for c in d["cpus"])
    if len(domains) > 1:
        # Biggest L3 (V-cache CCD on X3D); on a tie, the domain without CPU 0.
        guest = max(domains, key=lambda d: (d["size_kib"], 0 not in d["cpus"]))
        cores = cores_of(guest["cpus"], siblings)
    else:
        # One CCD: keep the core holding CPU 0 for the host, emulator and iothread.
        cores = cores_of(all_cpus, siblings)
        if len(cores) < 2:
            die("need at least two cores")
        cores = [k for k in cores if k != siblings[all_cpus[0]]]
    guest_set = {c for k in cores for c in k}
    return cores, [c for c in all_cpus if c not in guest_set]


def meminfo_kib():
    for line in Path(ROOT + "/proc/meminfo").read_text().splitlines():
        if line.startswith("MemTotal:"):
            return int(line.split()[1])
    die("no MemTotal in /proc/meminfo")


def has_pdpe1gb():
    return re.search(r"^flags\s*:.*\bpdpe1gb\b", Path(ROOT + "/proc/cpuinfo").read_text(), re.M) is not None


def guest_mem_kib(total_kib, page_kib, want_gib=None):
    """Half of RAM by default, at most RAM - 8 GiB, rounded down to the page size."""
    ceiling = total_kib - 8 * (1 << 20)
    mem = want_gib * (1 << 20) if want_gib else total_kib // 2
    mem = min(mem, ceiling)
    mem -= mem % page_kib
    if mem < 4 * (1 << 20):
        die(f"guest memory {mem // 1024} MiB is too small (host has {total_kib // 1024} MiB)")
    return mem


# --- disk -------------------------------------------------------------------

def run(*cmd, check=True, **kw):
    return subprocess.run(cmd, check=check, text=True, capture_output=True, **kw)


def ntfs_head(part, path, n=4):
    """First n bytes of a file on an NTFS partition, read without mounting.
    Streams and kills ntfscat after n bytes: hiberfil.sys is RAM-sized and
    buffering it whole (capture_output) OOMs the launcher."""
    p = subprocess.Popen(["ntfscat", "-q", part, path], stdout=subprocess.PIPE,
                         stderr=subprocess.DEVNULL)
    try:
        head = p.stdout.read(n)
    finally:
        p.stdout.close()
        p.terminate()
        p.wait()
    return head


def windows_partition():
    label = Path("/dev/disk/by-partlabel/win-c")
    if label.exists():
        return str(label.resolve())
    found = []
    for line in run("lsblk", "-rno", "PATH,FSTYPE").stdout.splitlines():
        path, _, fs = line.partition(" ")
        if fs == "ntfs" and ntfs_head(path, "Windows/System32/config/SYSTEM") == b"regf":
            found.append(path)
    if len(found) != 1:
        die("no Windows disk found" if not found else f"several Windows installs: {' '.join(found)}")
    return found[0]


def parent_disk(part):
    return "/dev/" + run("lsblk", "-no", "PKNAME", part).stdout.split()[0]


def disk_refusals(disk, part):
    out = []
    for line in run("lsblk", "-rno", "PATH,TYPE,MOUNTPOINTS", disk).stdout.splitlines():
        f = line.split(" ", 2)
        if f[1] == "crypt":
            out.append(f"{disk} holds an open LUKS device ({f[0]}); refusing the host disk")
        if len(f) > 2 and f[2].strip():
            out.append(f"{f[0]} is mounted at {f[2].strip()}")
    if ntfs_head(part, "hiberfil.sys").lower() in (b"hibr", b"wake"):
        out.append("Windows is hibernated (hiberfil.sys); boot it on metal and shut down fully")
    return out


def nvme_controller(disk):
    """PCI address of an NVMe disk's controller, if it is alone in its IOMMU group."""
    name = Path(disk).name
    dev = Path(f"/sys/block/{name}/device/device")
    if not name.startswith("nvme") or not dev.is_symlink():
        return None
    addr = dev.resolve().name
    group = os.listdir(f"/sys/bus/pci/devices/{addr}/iommu_group/devices")
    return addr if group == [addr] else None


def by_id(disk):
    real = os.path.realpath(disk)
    ids = sorted(p for p in Path("/dev/disk/by-id").iterdir()
                 if "-part" not in p.name and os.path.realpath(p) == real)
    if not ids:
        die(f"no /dev/disk/by-id link for {disk}")
    return str(ids[0])


# --- GPU --------------------------------------------------------------------

def gpu_refusals(gpus, handover=False):
    out = []
    for a in gpus:
        dev = Path(f"/sys/bus/pci/devices/{a}")
        if not dev.exists():
            out.append(f"GPU function {a} not present")
            continue
        drv = (dev / "driver").resolve().name if (dev / "driver").exists() else "none"
        if drv != "vfio-pci" and not handover:
            out.append(f"{a} is bound to {drv}, not vfio-pci (reboot after enabling the module)")
        for peer in os.listdir(dev / "iommu_group/devices"):
            if peer not in gpus:
                out.append(f"{a} shares IOMMU group with {peer}; ACS override is not used")
    return out


# --- XML --------------------------------------------------------------------

def pci_xml(addr, managed, boot=None):
    d, b, sf = addr.split(":")
    s, f = sf.split(".")
    order = f"<boot order='{boot}'/>" if boot else ""
    return (f"<hostdev mode='subsystem' type='pci' managed='{managed}'><source>"
            f"<address domain='0x{d}' bus='0x{b}' slot='0x{s}' function='0x{f}'/>"
            f"</source>{order}</hostdev>")


def render(cores, host_cpus, mem_kib, page_kib, disk_xml, gpus, kvmfr_bytes, handover=False, evdev=()):
    threads = len(cores[0])
    vcpus = [c for k in cores for c in k]
    pins = "".join(f"<vcpupin vcpu='{i}' cpuset='{c}'/>" for i, c in enumerate(vcpus))
    hs = fmt_list(host_cpus)
    gpu_xml = "".join(pci_xml(a, "yes" if handover else "no") for a in gpus)
    # Physical keyboard/mouse straight from evdev. Must go through
    # qemu:commandline: libvirt silently strips grab/grabToggle from
    # <input type='passthrough'> sources, leaving the devices grabbed with
    # no way to release. Scroll Lock toggles the grab host <-> guest.
    # grab_all on the first (keyboard) object: the toggle then grabs and
    # releases ALL input-linux devices together. Without it each device
    # grabs independently and the mouse stays stuck in the guest.
    toggle = os.environ.get("WIN_VM_GRAB_TOGGLE", "scrolllock")
    evdev_xml = "".join(
        "<qemu:arg value='-object'/><qemu:arg value='input-linux,id=evdev%d,evdev=%s,grab-toggle=%s%s'/>"
        % (i, p, toggle, ",grab_all=true" if i == 0 else "")
        for i, p in enumerate(evdev))
    return f"""<domain type='kvm' xmlns:qemu='http://libvirt.org/schemas/domain/qemu/1.0'>
  <name>{NAME}</name>
  <uuid>{UUID}</uuid>
  <metadata><wv:vm xmlns:wv='urn:mbox:win-vm' hostcpus='{hs}' guestcpus='{fmt_list(vcpus)}' pages='{mem_kib // page_kib}' pagekib='{page_kib}' shmpages='{kvmfr_bytes // (SHM_PAGE_KIB * 1024)}' handover='{int(handover)}'/></metadata>
  <memory unit='KiB'>{mem_kib}</memory>
  <memoryBacking><hugepages><page size='{page_kib}' unit='KiB'/></hugepages><access mode='shared'/><locked/></memoryBacking>
  <vcpu placement='static'>{len(vcpus)}</vcpu>
  <iothreads>1</iothreads>
  <cputune>{pins}<emulatorpin cpuset='{hs}'/><iothreadpin iothread='1' cpuset='{hs}'/></cputune>
  <!-- iommufd: kernel 7 removed the legacy VFIO group ioctls; libvirt >= 12.2
       opens /dev/iommu and the vfio cdevs itself. Needs shared RAM for DMA. -->
  <iommufd enabled='yes'/>
  <sysinfo type='smbios'/>
  <os firmware='efi'>
    <type arch='x86_64' machine='q35'>hvm</type>
    <firmware><feature enabled='no' name='secure-boot'/><feature enabled='no' name='enrolled-keys'/></firmware>
    <smbios mode='host'/>
  </os>
  <features>
    <acpi/><apic/>
    <!-- No <hyperv> enlightenments and no hypervclock timer: with the custom
         hyperv block (synic/stimer/vpindex/avic/...) this install hangs in
         bootmgfw at 100 % vCPU and the boot-failure counter dumps it into
         WinRE every time; on bare metal it boots fine. Removed wholesale
         2026-11-19; re-add selectively (relaxed/vapic/spinlocks first) and
         re-test before trusting any of them. -->
    <kvm><hidden state='off'/></kvm>
    <vmport state='off'/>
    <ioapic driver='kvm'/>
  </features>
  <cpu mode='host-passthrough' check='none' migratable='off'>
    <topology sockets='1' cores='{len(cores)}' threads='{threads}'/>
    <cache mode='passthrough'/>
    <maxphysaddr mode='passthrough'/>
    <feature policy='require' name='topoext'/>
    <feature policy='require' name='invtsc'/>
  </cpu>
  <clock offset='utc'>
    <timer name='rtc' tickpolicy='catchup'/><timer name='pit' tickpolicy='delay'/>
    <timer name='hpet' present='no'/>
  </clock>
  <pm><suspend-to-mem enabled='no'/><suspend-to-disk enabled='no'/></pm>
  <on_poweroff>destroy</on_poweroff><on_reboot>restart</on_reboot><on_crash>destroy</on_crash>
  <devices>
    {disk_xml}
    {gpu_xml}
    <!-- e1000, not virtio: Windows has an inbox driver for it, so the guest
         gets working network before the virtio drivers are deployed
         (virtio staged by the guest config lands with the LG host app). -->
    <interface type='network'><source network='default'/><model type='e1000'/></interface>
    <input type='mouse' bus='virtio'/><input type='keyboard' bus='virtio'/>
    <graphics type='spice' port='5900' autoport='no'><listen type='address' address='127.0.0.1'/><image compression='off'/></graphics>
    <video><model type='{("vga" if os.environ.get("WIN_VM_VGA", "0") == "1" else "none")}'/></video>
    <channel type='spicevmc'><target type='virtio' name='com.redhat.spice.0'/></channel>
    <channel type='unix'><target type='virtio' name='org.qemu.guest_agent.0'/></channel>
    <sound model='ich9'><audio id='1'/></sound>
    <audio id='1' type='spice'/>
    <!-- No swtpm: removed together with the hyperv block (see <features>);
         this install reaches the network phase without a vTPM. Re-test
         before restoring (BitLocker/Hello on the guest would need it). -->
    <memballoon model='none'/>
  </devices>
  <qemu:commandline>
    {evdev_xml}
    <qemu:arg value='-device'/>
    <qemu:arg value='{{"driver":"ivshmem-plain","id":"shmem0","memdev":"looking-glass"}}'/>
    <qemu:arg value='-object'/>
    <qemu:arg value='{{"qom-type":"memory-backend-file","id":"looking-glass","mem-path":"{SHM}","size":{kvmfr_bytes},"share":true}}'/>
    <qemu:arg value='-fw_cfg'/>
    <qemu:arg value='opt/ovmf/X-PciMmio64Mb,string=65536'/>
  </qemu:commandline>
</domain>
"""


def disk_xml_for(disk, part, refusals):
    nvme = nvme_controller(disk)
    if nvme:
        return pci_xml(nvme, "yes", boot=1)
    if subprocess.run(["ntfscat", "-q", part, "ProgramData/machine-config/virtio-staged"],
                      capture_output=True).returncode != 0:
        refusals.append("disk2's NVMe controller shares an IOMMU group and the virtio drivers "
                        "are not staged; run apply on metal once")
    return ("<controller type='scsi' model='virtio-scsi'><driver iothread='1'/></controller>"
            f"<disk type='block' device='disk'><driver name='qemu' type='raw' cache='none' "
            f"io='native' discard='unmap'/><source dev='{by_id(disk)}'/>"
            "<target dev='sda' bus='scsi'/><boot order='1'/></disk>")


# --- commands ---------------------------------------------------------------

def virsh(*args, check=True):
    return run("virsh", "-c", URI, *args, check=check)


def running():
    return virsh("domstate", NAME, check=False).stdout.strip() == "running"


def lock():
    fd = os.open(LOCK, os.O_RDWR | os.O_CREAT, 0o660)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        die("the Windows disk is in use (win-sync or another win-vm holds the lock)")
    return fd


def cmd_start(a):
    gpus = os.environ.get("WIN_VM_GPU", "").split()
    kvmfr = int(os.environ.get("WIN_VM_KVMFR", "134217728"))
    handover = os.environ.get("WIN_VM_HANDOVER") == "1"
    if running():
        die(f"{NAME} is already running")
    _lock = None if a.dry_run else lock()
    domains, siblings = topology()
    cores, host = choose_cpus(domains, siblings)
    page_kib = (1 << 20) if a.pagesize == "1G" and has_pdpe1gb() else 2048
    mem = guest_mem_kib(meminfo_kib(), page_kib, a.mem)
    refusals = gpu_refusals(gpus, handover)
    try:
        part = windows_partition()
        disk = parent_disk(part)
        refusals += disk_refusals(disk, part)
        disk_xml = disk_xml_for(disk, part, refusals)
    except SystemExit:
        if not a.dry_run:
            raise
        disk_xml = "<!-- no Windows disk found -->"
    xml = render(cores, host, mem, page_kib, disk_xml, gpus, kvmfr, handover,
                 evdev=os.environ.get("WIN_VM_EVDEV", "").split())
    if a.dry_run:
        for r in refusals:
            print(f"would refuse: {r}", file=sys.stderr)
        print(xml)
        return
    if refusals:
        die("\n  ".join(["refusing to start:"] + refusals))
    # memory-backend-file does not create the file. Size it best-effort as
    # the user; on the root-only hugetlbfs mount the hook (root) has already
    # created and sized it root:kvm 0660 during prepare.
    try:
        with open(SHM, "ab") as f:
            os.ftruncate(f.fileno(), kvmfr)
    except PermissionError:
        pass
    out = Path(os.environ.get("XDG_RUNTIME_DIR", "/tmp")) / f"{NAME}.xml"
    out.write_text(xml)
    p = virsh("create", str(out), check=False)
    if p.returncode != 0:
        if page_kib != 2048 and "hook" in p.stderr:
            print("win-vm: 1 GiB hugepages unavailable, retrying with 2 MiB pages", file=sys.stderr)
            a.pagesize = "2M"
            os.close(_lock)
            return cmd_start(a)
        die(p.stderr.strip())
    print(f"started {NAME}: {len(cores)} cores, {mem >> 20} GiB, host keeps CPUs {fmt_list(host)}")
    if not a.no_viewer:
        cmd_viewer(a)


def cmd_stop(a):
    if not running():
        # QEMU died on its own (crash, guest shutdown): the release hook has
        # already restored the host; stopping again is a no-op, not a failure.
        print(f"{NAME} is not running (already stopped; host state was restored by the release hook)")
        return
    if a.force:
        print("win-vm: destroying; an unclean stop can leave the RTX 5090 needing a host reboot",
              file=sys.stderr)
        virsh("destroy", NAME)
        return
    # Agent shutdown is the clean one (services flush); ACPI is the fallback
    # for the first boots, before the guest tools are installed.
    if virsh("shutdown", NAME, "--mode", "agent", check=False).returncode != 0:
        virsh("shutdown", NAME, "--mode", "acpi")
    for _ in range(180):
        if not running():
            print(f"{NAME} shut down")
            return
        time.sleep(1)
    die(f"{NAME} still running after 180 s; check the guest, or `win-vm stop --force` "
        "(may leave the GPU needing a host reboot)")


def cmd_status(a):
    print(virsh("domstate", NAME, check=False).stdout.strip() or "not running")


def cmd_viewer(a):
    os.execvp("looking-glass-client", ["looking-glass-client"])


def cmd_find_disk(a):
    part = windows_partition()
    print(part)


def main(argv=None):
    p = argparse.ArgumentParser(prog="win-vm")
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("start")
    s.add_argument("--dry-run", action="store_true", help="print the domain XML and refusals")
    s.add_argument("--mem", type=int, metavar="GIB", help="guest RAM (default: half of host)")
    s.add_argument("--pagesize", choices=["1G", "2M"], default="1G")
    s.add_argument("--no-viewer", action="store_true")
    st = sub.add_parser("stop")
    st.add_argument("--force", action="store_true", help="destroy instead of ACPI shutdown")
    sub.add_parser("status")
    sub.add_parser("viewer")
    sub.add_parser("find-disk", help="print the Windows system partition")
    a = p.parse_args(argv)
    # The systemd unit windows-vm.service (see the module) owns start/stop so
    # that Conflicts= with the llama/handy units flips between them. Direct
    # mode is what the unit itself runs (WIN_VM_DIRECT=1); anything else
    # delegates, so the CLI and the unit cannot diverge.
    unit = os.environ.get("WIN_VM_UNIT", "")
    if a.cmd in ("start", "stop") and unit and os.environ.get("WIN_VM_DIRECT") != "1":
        os.execvp("systemctl", ["systemctl", a.cmd, unit])
    {"start": cmd_start, "stop": cmd_stop, "status": cmd_status,
     "viewer": cmd_viewer, "find-disk": cmd_find_disk}[a.cmd](a)


if __name__ == "__main__":
    main()
