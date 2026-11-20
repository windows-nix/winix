#!/usr/bin/env python3
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import textwrap
import unittest

DEPLOY = Path(__file__).resolve().parents[1] / "deploy.sh"
REQUIRED = [
    "apply.ps1", "apply.cmd", "common.ps1", "startup.ps1", "items.json",
    "machine.json", "startup.json", "config.dsc.yaml", "config.win11.dsc.yaml",
]

MOCK = r'''#!/usr/bin/env python3
import base64
import json
import os
from pathlib import Path
import sys

name = Path(sys.argv[0]).name
args = sys.argv[1:]
entry = {"command": name, "args": args}
script = ""
if "-EncodedCommand" in args:
    encoded = args[args.index("-EncodedCommand") + 1]
    script = base64.b64decode(encoded).decode("utf-16-le")
    entry["script"] = script
with open(os.environ["MOCK_LOG"], "a") as log:
    log.write(json.dumps(entry) + "\n")

is_tar = name == "tar.exe" or (name == "ssh" and any(a.startswith("tar -xf") for a in args))
if is_tar:
    Path(os.environ["MOCK_TAR"]).write_bytes(sys.stdin.buffer.read())
    sys.exit(int(os.environ.get("MOCK_TAR_EXIT", "0")))
if "apply.cmd" in script:
    sys.exit(int(os.environ.get("MOCK_APPLY_EXIT", "0")))
if "Get-FileHash" in script and "Get-ChildItem" in script:
    sys.stdout.write(os.environ.get("MOCK_REMOTE", ""))
sys.exit(int(os.environ.get("MOCK_PS_EXIT", "0")))
'''


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.src = self.root / "source"
        self.src.mkdir()
        for index, name in enumerate(REQUIRED):
            (self.src / name).write_text(f"{name}\n{index}\n")
        (self.src / "payload with space.txt").write_text("payload\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        mock = self.bin / "windows-mock"
        mock.write_text(MOCK.replace("/usr/bin/env python3", sys.executable))
        mock.chmod(0o755)
        for name in ("ssh", "powershell.exe", "tar.exe"):
            (self.bin / name).symlink_to(mock)
        self.log = self.root / "calls.jsonl"
        self.tar = self.root / "sent.tar"
        self.env = os.environ.copy()
        self.env.update({
            "PATH": str(self.bin) + os.pathsep + self.env["PATH"],
            "MOCK_LOG": str(self.log),
            "MOCK_TAR": str(self.tar),
            "WSL_DISTRO_NAME": "",
            "WSL_INTEROP": "",
        })
        self.env.pop("WINDOWS_HOST", None)
        self.env.pop("WINDOWS_TRANSPORT", None)

    def tearDown(self):
        self.temp.cleanup()

    def remote_manifest(self, *extra):
        digest = hashlib.sha256((self.src / "apply.ps1").read_bytes()).hexdigest()
        return "\n".join([f"{digest} apply.ps1", *extra]) + "\n"

    def run_deploy(self, *args, env=None):
        environment = self.env.copy()
        if env:
            environment.update(env)
        return subprocess.run(
            ["bash", str(DEPLOY), *map(str, args)],
            env=environment,
            text=True,
            capture_output=True,
        )

    def calls(self):
        if not self.log.exists():
            return []
        return [json.loads(line) for line in self.log.read_text().splitlines()]

    def scripts(self):
        return [call.get("script", "") for call in self.calls()]

    def sent_files(self):
        with tarfile.open(self.tar) as archive:
            return sorted(archive.getnames())

    def test_ssh_merge_sends_only_changes_preserves_stale_and_passes_apply_args(self):
        stale = "0" * 64 + " old.txt"
        result = self.run_deploy(
            "--transport", "ssh", "--host", "windows.example", "--dir", r"C:\Config",
            "--mode", "merge", self.src, "--apply", "--", "-DryRun", "-Platform", "vm",
            env={"MOCK_REMOTE": self.remote_manifest(stale)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("apply.ps1", self.sent_files())
        self.assertIn("payload with space.txt", self.sent_files())
        all_scripts = "\n".join(self.scripts())
        self.assertNotIn("$stale=", all_scripts)
        self.assertIn("apply.cmd", all_scripts)
        for argument in ("-DryRun", "-Platform", "vm"):
            self.assertIn(base64.b64encode(argument.encode()).decode(), all_scripts)
        self.assertTrue(any(call["command"] == "ssh" for call in self.calls()))

    def test_enforce_prunes_only_unmanaged_manifest_files(self):
        stale = "0" * 64 + " old.txt"
        result = self.run_deploy(
            "--transport", "ssh", "--host", "windows.example", "--mode", "enforce", self.src,
            env={"MOCK_REMOTE": self.remote_manifest(stale)},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        prune = next(script for script in self.scripts() if "$stale=" in script)
        self.assertIn(base64.b64encode(b"old.txt").decode(), prune)
        self.assertNotIn(base64.b64encode(b"apply.ps1").decode(), prune)
        hash_script = self.scripts()[0]
        for protected in ("logs", "virtio-staged", "debloat-applied", ".apply.lock", ".deploy-"):
            self.assertIn(protected, hash_script)

    def test_wsl_auto_uses_windows_interop_and_never_ssh(self):
        result = self.run_deploy(
            self.src,
            env={"WSL_DISTRO_NAME": "NixOS", "MOCK_REMOTE": self.remote_manifest()},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = {call["command"] for call in self.calls()}
        self.assertIn("powershell.exe", commands)
        self.assertIn("tar.exe", commands)
        self.assertNotIn("ssh", commands)
        self.assertIn("transport=wsl", result.stderr)

    def test_unchanged_folder_sends_no_archive(self):
        remote = "\n".join(
            f"{hashlib.sha256(path.read_bytes()).hexdigest()} {path.relative_to(self.src).as_posix()}"
            for path in self.src.rglob("*") if path.is_file()
        ) + "\n"
        result = self.run_deploy("--transport", "ssh", "--host", "windows.example", self.src,
                                 env={"MOCK_REMOTE": remote})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.tar.exists())
        self.assertIn("0 of", result.stderr)

    def test_transfer_failure_does_not_apply(self):
        result = self.run_deploy(
            "--transport", "ssh", "--host", "windows.example", self.src, "--apply",
            env={"MOCK_REMOTE": self.remote_manifest(), "MOCK_TAR_EXIT": "7"},
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any("apply.cmd" in script for script in self.scripts()))

    def test_apply_failure_is_deploy_failure(self):
        result = self.run_deploy(
            "--transport", "ssh", "--host", "windows.example", self.src, "--apply",
            env={"MOCK_REMOTE": self.remote_manifest(), "MOCK_APPLY_EXIT": "9"},
        )
        self.assertEqual(result.returncode, 9, result.stderr)

    def test_legacy_single_dash_apply_arguments_remain_accepted(self):
        result = self.run_deploy(
            "--transport", "ssh", "--host", "windows.example", self.src, "--apply", "-DryRun",
            env={"MOCK_REMOTE": self.remote_manifest()},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(base64.b64encode(b"-DryRun").decode(), "\n".join(self.scripts()))

    def test_ambiguous_auto_and_incomplete_source_fail_before_remote_calls(self):
        result = self.run_deploy(self.src)
        self.assertEqual(result.returncode, 2)
        self.assertIn("cannot auto-select", result.stderr)
        self.assertEqual(self.calls(), [])
        (self.src / "items.json").unlink()
        result = self.run_deploy("--transport", "ssh", "--host", "windows.example", self.src)
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing items.json", result.stderr)
        self.assertEqual(self.calls(), [])


if __name__ == "__main__":
    unittest.main()
