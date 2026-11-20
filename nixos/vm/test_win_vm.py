# Run: python3 nixos/windows-vm/test_win_vm.py
import os
import sys
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path


def fake_cpu(root, ccds, l3_sizes, smt=True):
    """ccds: cores per CCD. Linux numbering: thread 0 of every core first, then siblings."""
    base = Path(root, "sys/devices/system/cpu")
    ncores = sum(ccds)
    total = ncores * (2 if smt else 1)
    base.mkdir(parents=True)
    (base / "online").write_text(f"0-{total - 1}\n")
    core = 0
    for ccd, n in enumerate(ccds):
        cpus = [c for k in range(core, core + n) for c in ((k, k + ncores) if smt else (k,))]
        shared = ",".join(map(str, sorted(cpus)))
        for k in range(core, core + n):
            sib = f"{k},{k + ncores}" if smt else str(k)
            for c in ((k, k + ncores) if smt else (k,)):
                d = base / f"cpu{c}"
                (d / "topology").mkdir(parents=True)
                (d / "cache/index3").mkdir(parents=True)
                (d / "topology/thread_siblings_list").write_text(sib)
                (d / "cache/index3/shared_cpu_list").write_text(shared)
                (d / "cache/index3/size").write_text(l3_sizes[ccd])
        core += n


def load(root):
    os.environ["WIN_VM_ROOT"] = root
    sys.path.insert(0, str(Path(__file__).parent))
    import importlib
    import win_vm
    return importlib.reload(win_vm)


with tempfile.TemporaryDirectory() as r:  # 9950X3D: V-cache on CCD0 (holds CPU 0)
    fake_cpu(r, [8, 8], ["98304K", "32768K"])
    w = load(r)
    cores, host = w.choose_cpus(*w.topology())
    assert cores[0] == (0, 16) and len(cores) == 8, cores
    assert host == list(range(8, 16)) + list(range(24, 32)), host

with tempfile.TemporaryDirectory() as r:  # 9950X: tie -> the CCD without CPU 0
    fake_cpu(r, [8, 8], ["32768K", "32768K"])
    w = load(r)
    cores, host = w.choose_cpus(*w.topology())
    assert cores[0] == (8, 24) and 0 in host, (cores, host)

with tempfile.TemporaryDirectory() as r:  # one CCD: host keeps core 0
    fake_cpu(r, [8], ["32768K"])
    w = load(r)
    cores, host = w.choose_cpus(*w.topology())
    assert host == [0, 8] and len(cores) == 7, (cores, host)

    G = 1 << 20  # GiB in KiB
    assert w.guest_mem_kib(64 * G, G) == 32 * G
    assert w.guest_mem_kib(16 * G, G) == 8 * G
    assert w.guest_mem_kib(64 * G, G, want_gib=60) == 56 * G  # RAM - 8 GiB ceiling
    assert w.guest_mem_kib(64 * G + 1000, 2048) % 2048 == 0

    xml = w.render(cores, host, 32 * G, G, "<disk/>", ["0000:01:00.0", "0000:01:00.1"], 134217728)
    d = ET.fromstring(xml)
    pins = [p.get("cpuset") for p in d.iter("vcpupin")]
    assert "0" not in pins and "8" not in pins and len(pins) == 14, pins
    assert d.find("cputune/emulatorpin").get("cpuset") == "0,8"
    assert d.find("cpu/topology").attrib == {"sockets": "1", "cores": "7", "threads": "2"}
    assert d.find("cpu/maxphysaddr").get("mode") == "passthrough"
    assert d.find("os/firmware/feature[@name='secure-boot']").get("enabled") == "no"
    assert d.find("features/kvm/hidden").get("state") == "off"
    assert len(d.findall("devices/hostdev")) == 2
    meta = d.find("metadata/{urn:mbox:win-vm}vm")
    assert meta.get("hostcpus") == "0,8" and meta.get("pages") == "32", meta.attrib
    assert "X-PciMmio64Mb,string=65536" in xml
    assert {h.get("managed") for h in d.findall("devices/hostdev")} == {"no"}
    assert meta.get("handover") == "0"

    d = ET.fromstring(w.render(cores, host, 32 * G, G, "<disk/>", ["0000:01:00.0"], 134217728, handover=True))
    assert d.find("devices/hostdev").get("managed") == "yes"
    assert d.find("metadata/{urn:mbox:win-vm}vm").get("handover") == "1"

print("ok")
