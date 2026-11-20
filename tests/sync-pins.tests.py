#!/usr/bin/env python3
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1] / "sync-pins"
loader = importlib.machinery.SourceFileLoader("windows_sync_pins", str(SOURCE))
spec = importlib.util.spec_from_loader(loader.name, loader)
sync_pins = importlib.util.module_from_spec(spec)
loader.exec_module(sync_pins)


def item(package_id, silent_args=None):
    return {
        "id": package_id,
        "name": package_id,
        "kind": "installer",
        "source": {"url": f"https://example.invalid/{package_id}", "version": "1"},
        "silentArgs": silent_args,
    }


class SyncPinsTests(unittest.TestCase):
    def test_flat_list_remains_accepted_for_pin_migration(self):
        items = [item("one"), item("two")]
        self.assertEqual(sync_pins.flatten_items(items), items)

    def test_three_sets_flatten_in_stable_order(self):
        data = {
            "common": [item("common")],
            "bareOnly": [item("bare")],
            "vmOnly": [item("vm")],
        }
        self.assertEqual([i["id"] for i in sync_pins.flatten_items(data)], ["common", "bare", "vm"])

    def test_unknown_set_is_rejected(self):
        with self.assertRaisesRegex(SystemExit, "unknown package set"):
            sync_pins.flatten_items({"metalOnly": []})

    def test_selective_refresh_preserves_other_pins_and_overrides_silent_args(self):
        items = [item("one", "/quiet"), item("two")]
        existing = {"one": {"version": "old"}, "two": {"version": "keep"}, "retired": {"version": "keep"}}

        def resolve(current):
            return {"version": "new", "silentArgs": None}

        pins = sync_pins.refreshed_pins(items, existing, {"one"}, resolve)
        self.assertEqual(pins["one"], {"version": "new", "silentArgs": "/quiet"})
        self.assertEqual(pins["two"], existing["two"])
        self.assertEqual(pins["retired"], existing["retired"])

    def test_unknown_selection_and_duplicate_ids_are_rejected(self):
        with self.assertRaisesRegex(SystemExit, "unknown selected"):
            sync_pins.refreshed_pins([item("one")], {}, {"missing"}, lambda i: {})
        with self.assertRaisesRegex(SystemExit, "duplicate"):
            sync_pins.refreshed_pins([item("one"), item("one")], {}, set(), lambda i: {})

    def test_winget_string_is_normalized_without_explicit_fields(self):
        normalized = sync_pins.flatten_items({"common": ["Publisher.Application"]})[0]
        self.assertEqual(normalized["id"], "publisher-application")
        self.assertEqual(normalized["name"], "Publisher.Application")
        self.assertEqual(normalized["kind"], "auto")
        self.assertEqual(normalized["source"], {"winget": "Publisher.Application"})

    def test_auto_resolution_selects_kind_and_display_name_detection(self):
        normalized = sync_pins.flatten_items(["Publisher.Application"])[0]
        manifest = {
            "PackageVersion": "2.0",
            "Installers": [{
                "Architecture": "x64",
                "Scope": "machine",
                "InstallerType": "msi",
                "InstallerUrl": "https://example.invalid/app.msi",
                "InstallerSha256": "A" * 64,
                "AppsAndFeaturesEntries": [{
                    "DisplayName": "Publisher Application",
                    "DisplayVersion": "2.0",
                }],
            }],
        }
        with mock.patch.object(sync_pins, "winget_manifest", return_value=iter([manifest])):
            pin = sync_pins.resolve(normalized)
        self.assertEqual(pin["kind"], "msi")
        self.assertEqual(pin["version"], "2.0")
        self.assertEqual(pin["detect"], {"displayName": "^Publisher\\ Application$"})

    def test_auto_resolution_uses_msi_product_code_fallback(self):
        normalized = sync_pins.flatten_items(["Microsoft.PowerShell"])[0]
        manifest = {
            "PackageVersion": "7.6.9.0",
            "Installers": [{
                "Architecture": "x64",
                "Scope": "machine",
                "InstallerType": "wix",
                "InstallerUrl": "https://example.invalid/powershell.msi",
                "InstallerSha256": "A" * 64,
                "ProductCode": "{5417B253-1A6D-4638-BC94-743A6EC2E6F4}",
            }],
        }
        with mock.patch.object(sync_pins, "winget_manifest", return_value=iter([manifest])):
            pin = sync_pins.resolve(normalized)
        self.assertEqual(pin["kind"], "msi")
        self.assertEqual(pin["detect"], {"productCode": "{5417B253-1A6D-4638-BC94-743A6EC2E6F4}"})

    def test_auto_resolution_rejects_plain_portable_zip(self):
        normalized = sync_pins.flatten_items(["Publisher.Portable"])[0]
        manifest = {
            "PackageVersion": "1",
            "Installers": [{
                "Architecture": "x64",
                "InstallerType": "zip",
                "InstallerUrl": "https://example.invalid/app.zip",
                "InstallerSha256": "A" * 64,
            }],
        }
        with mock.patch.object(sync_pins, "winget_manifest", return_value=iter([manifest])):
            with self.assertRaisesRegex(SystemExit, "no auto installer"):
                sync_pins.resolve(normalized)

    def test_explicit_paths_work_outside_the_checkout(self):
        data = {"common": [item("one")], "bareOnly": [], "vmOnly": []}
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            package_file = root / "consumer" / "software.nix"
            output = root / "state" / "resolved.json"
            package_file.parent.mkdir()
            package_file.write_text("{ }")
            argv = ["windows-sync-pins", "--config", str(package_file), "--output", str(output)]
            with mock.patch.object(sys, "argv", argv), \
                    mock.patch.object(sync_pins, "run", return_value=json.dumps(data)) as run, \
                    mock.patch.object(sync_pins, "ensure_winget") as ensure, \
                    mock.patch.object(sync_pins, "resolve", return_value={"version": "1"}):
                sync_pins.main()
            self.assertEqual(json.loads(output.read_text())["one"]["version"], "1")
            self.assertEqual(Path(run.call_args.args[-1]), package_file)
            ensure.assert_not_called()


if __name__ == "__main__":
    unittest.main()
