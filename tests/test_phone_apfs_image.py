"""Mock-only tests: these never invoke hdiutil, diskutil, or real formatting."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


TOOL_PATH = (
    Path(__file__).resolve().parents[1]
    / "tools"
    / "phone_ssd"
    / "create_apfs_image.py"
)
SPEC = importlib.util.spec_from_file_location("phone_apfs_image", TOOL_PATH)
image_tool = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = image_tool
SPEC.loader.exec_module(image_tool)


class FakeMacRunner:
    def __init__(self):
        self.calls = []
        self.path = None
        self.device = "/dev/disk42"
        self.devices = [self.device]
        self.attached = False
        self.attach_status = 0
        self.attach_stdout = None
        self.info_stdout = None
        self.info_status = 0
        self.mapping_path = None
        self.mapping_devices = None
        self.extra_images = []
        self.device_info_overrides = {}
        self.device_info_missing_keys = set()
        self.partition_status = 0
        self.layout = None
        self.detach_status = 0
        self.keep_attached = False
        self.write_headers = True
        self.before_info = None

    def _result(self, argv, data=None, status=0, stdout=None):
        if stdout is None:
            stdout = plistlib.dumps(data) if data is not None else b""
        return subprocess.CompletedProcess(
            argv, status, stdout=stdout, stderr=b"mock failure" if status else b""
        )

    def _inventory(self):
        images = list(self.extra_images)
        if self.attached:
            images.append(
                {
                    "image-path": self.mapping_path or str(self.path),
                    "system-entities": [
                        {"dev-entry": device}
                        for device in (
                            self.mapping_devices
                            if self.mapping_devices is not None
                            else self.devices
                        )
                    ],
                }
            )
        return {"images": images}

    def _layout(self):
        return {
            "AllDisksAndPartitions": [
                {
                    "DeviceIdentifier": "disk42",
                    "Content": "GUID_partition_scheme",
                    "Size": self.path.stat().st_size,
                    "Partitions": [
                        {
                            "DeviceIdentifier": "disk42s1",
                            "Content": "EFI",
                            "Size": 200 * 1024 ** 2,
                        },
                        {
                            "DeviceIdentifier": "disk42s2",
                            "Content": "Apple_APFS",
                            "Size": 824 * 1024 ** 2,
                        },
                    ],
                }
            ]
        }

    def run(self, argv):
        self.calls.append(list(argv))
        if argv[:2] == [image_tool.HDIUTIL, "attach"]:
            self.path = Path(argv[-1])
            self.attached = True
            return self._result(
                argv,
                {"system-entities": [{"dev-entry": d} for d in self.devices]},
                status=self.attach_status,
                stdout=self.attach_stdout,
            )
        if argv == [image_tool.HDIUTIL, "info", "-plist"]:
            if self.before_info is not None:
                self.before_info()
            return self._result(
                argv,
                self._inventory(),
                status=self.info_status,
                stdout=self.info_stdout,
            )
        if argv[:3] == [image_tool.DISKUTIL, "info", "-plist"]:
            data = {
                "WholeDisk": True,
                "VirtualOrPhysical": "Virtual",
                "DeviceNode": argv[3],
            }
            data.update(self.device_info_overrides)
            for key in self.device_info_missing_keys:
                data.pop(key, None)
            return self._result(argv, data)
        if argv[:2] == [image_tool.DISKUTIL, "partitionDisk"]:
            if self.partition_status == 0 and self.write_headers:
                with self.path.open("r+b") as output:
                    output.seek(512)
                    output.write(b"EFI PART")
                    output.seek(self.path.stat().st_size - 512)
                    output.write(b"EFI PART")
            return self._result(argv, status=self.partition_status)
        if argv[:3] == [image_tool.DISKUTIL, "list", "-plist"]:
            return self._result(argv, self.layout or self._layout())
        if argv[:2] == [image_tool.HDIUTIL, "detach"]:
            if self.detach_status == 0 and not self.keep_attached:
                self.attached = False
            return self._result(argv, status=self.detach_status)
        raise AssertionError("Unexpected mock command: {!r}".format(argv))

    def commands(self, binary, verb):
        return [call for call in self.calls if call[:2] == [binary, verb]]


class PhoneAPFSImageTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="ipac-apfs-mock-")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name).resolve()
        self.output = self.directory / "phone.img"
        self.runner = FakeMacRunner()

    def create(self):
        return image_tool.create_apfs_image(self.output, 1, runner=self.runner)

    def assert_not_formatted(self):
        self.assertEqual(
            self.runner.commands(image_tool.DISKUTIL, "partitionDisk"), []
        )

    def assert_not_detached(self):
        self.assertEqual(self.runner.commands(image_tool.HDIUTIL, "detach"), [])

    def assert_retained(self):
        with self.assertRaises(image_tool.ImageCreationError) as result:
            self.create()
        self.assertEqual(result.exception.retained_path, self.output)
        self.assertTrue(self.output.exists())
        return result.exception

    def test_success_is_exact_raw_gpt_file_with_private_permissions(self):
        self.assertEqual(self.create(), self.output)
        self.assertEqual(self.output.stat().st_size, image_tool.GIB)
        self.assertEqual(stat.S_IMODE(self.output.stat().st_mode), 0o600)
        with self.output.open("rb") as output:
            output.seek(512)
            self.assertEqual(output.read(8), b"EFI PART")
            output.seek(image_tool.GIB - 512)
            self.assertEqual(output.read(8), b"EFI PART")
        self.assertFalse(self.runner.attached)
        self.assertEqual(
            self.runner.commands(image_tool.DISKUTIL, "partitionDisk"),
            [
                [
                    image_tool.DISKUTIL,
                    "partitionDisk",
                    "/dev/disk42",
                    "GPT",
                    "APFS",
                    "iPac SSD",
                    "100%",
                ]
            ],
        )
        self.assertEqual(
            self.runner.commands(image_tool.HDIUTIL, "attach")[0],
            [
                image_tool.HDIUTIL,
                "attach",
                "-nomount",
                "-readwrite",
                "-imagekey",
                "diskimage-class=CRawDiskImage",
                "-plist",
                str(self.output),
            ],
        )
        verbs = [(Path(call[0]).name, call[1]) for call in self.runner.calls]
        self.assertEqual(
            verbs[:4],
            [
                ("hdiutil", "attach"),
                ("hdiutil", "info"),
                ("diskutil", "info"),
                ("diskutil", "partitionDisk"),
            ],
        )

    def test_invalid_sizes_never_create_or_call_commands(self):
        for size in (0, -1, 257, True, 1.5, "1"):
            with self.subTest(size=size):
                with self.assertRaises(image_tool.ImageCreationError):
                    image_tool.create_apfs_image(
                        self.output, size, runner=self.runner
                    )
                self.assertFalse(self.output.exists())
        self.assertEqual(self.runner.calls, [])
        self.assertEqual(
            image_tool._validated_size(256), 256 * image_tool.GIB
        )

    def test_invalid_paths_never_call_commands(self):
        for path in (
            "",
            None,
            b"phone.img",
            self.directory / "phone.dmg",
            self.directory / "missing" / "phone.img",
            str(self.directory / "bad\x00.img"),
        ):
            with self.subTest(path=path):
                with self.assertRaises(image_tool.ImageCreationError):
                    image_tool.create_apfs_image(path, 1, runner=self.runner)
        self.assertEqual(self.runner.calls, [])

    def test_existing_file_is_not_overwritten(self):
        self.output.write_bytes(b"important existing content")
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assertEqual(self.output.read_bytes(), b"important existing content")
        self.assertEqual(self.runner.calls, [])

    def test_existing_directory_is_not_overwritten(self):
        self.output.mkdir()
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assertTrue(self.output.is_dir())
        self.assertEqual(self.runner.calls, [])

    def test_symlink_is_not_followed_or_removed(self):
        target = self.directory / "important.bin"
        target.write_bytes(b"important")
        self.output.symlink_to(target)
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assertTrue(self.output.is_symlink())
        self.assertEqual(target.read_bytes(), b"important")
        self.assertEqual(self.runner.calls, [])

    def test_ftruncate_failure_removes_only_new_unattached_file(self):
        with mock.patch.object(os, "ftruncate", side_effect=OSError("no space")):
            with self.assertRaises(image_tool.ImageCreationError):
                self.create()
        self.assertFalse(self.output.exists())
        self.assertEqual(self.runner.calls, [])

    def test_ambiguous_whole_devices_are_retained_without_format_or_detach(self):
        self.runner.devices = ["/dev/disk42", "/dev/disk43"]
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_slice_only_attach_is_retained_without_format_or_detach(self):
        self.runner.devices = ["/dev/disk42s1"]
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_failed_attach_can_be_recovered_for_safe_cleanup(self):
        self.runner.attach_status = 1
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assert_not_formatted()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.runner.attached)
        self.assertEqual(len(self.runner.commands(image_tool.HDIUTIL, "detach")), 1)

    def test_invalid_attach_plist_can_be_recovered_for_safe_cleanup(self):
        self.runner.attach_stdout = b"not a plist"
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assert_not_formatted()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.runner.attached)

    def test_malformed_xml_attach_plist_can_be_safely_cleaned_up(self):
        self.runner.attach_stdout = b"<?xml version='1.0'?><plist><dict>"
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assert_not_formatted()
        self.assertFalse(self.output.exists())
        self.assertFalse(self.runner.attached)

    def test_invalid_inventory_plist_retains_image_without_format_or_detach(self):
        self.runner.info_stdout = b"not a plist"
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_malformed_xml_inventory_retains_image_without_format_or_detach(self):
        self.runner.info_stdout = b"<?xml version='1.0'?><plist><dict>"
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_missing_inventory_retains_image_without_format_or_detach(self):
        self.runner.info_stdout = plistlib.dumps({})
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_inventory_command_failure_retains_image(self):
        self.runner.info_status = 1
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_wrong_image_mapping_retains_file_and_never_touches_other_image(self):
        self.runner.mapping_path = str(self.directory / "other.img")
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_wrong_device_mapping_is_not_formatted_or_detached(self):
        self.runner.mapping_devices = ["/dev/disk43"]
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_duplicate_image_mappings_are_not_formatted_or_detached(self):
        self.runner.extra_images = [
            {
                "image-path": str(self.output),
                "system-entities": [{"dev-entry": "/dev/disk43"}],
            }
        ]
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_another_image_claiming_same_device_is_not_touched(self):
        self.runner.extra_images = [
            {
                "image-path": str(self.directory / "other.img"),
                "system-entities": [{"dev-entry": "/dev/disk42"}],
            }
        ]
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_physical_device_is_not_formatted_or_detached(self):
        self.runner.device_info_overrides["VirtualOrPhysical"] = "Physical"
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_non_whole_device_is_not_formatted_or_detached(self):
        self.runner.device_info_overrides["WholeDisk"] = False
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_integer_one_is_not_accepted_as_whole_boolean(self):
        self.runner.device_info_overrides["WholeDisk"] = 1
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_missing_whole_disk_key_is_not_formatted_or_detached(self):
        self.runner.device_info_missing_keys.add("WholeDisk")
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_fake_whole_key_is_not_accepted_as_whole_disk_fallback(self):
        self.runner.device_info_missing_keys.add("WholeDisk")
        self.runner.device_info_overrides["Whole"] = True
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_wrong_device_node_is_not_formatted_or_detached(self):
        self.runner.device_info_overrides["DeviceNode"] = "/dev/disk1"
        self.assert_retained()
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_replaced_path_is_not_formatted_detached_or_removed(self):
        moved = self.directory / "original.img"

        def replace_output():
            self.runner.before_info = None
            self.output.rename(moved)
            self.output.write_bytes(b"replacement owned by somebody else")

        self.runner.before_info = replace_output
        self.assert_retained()
        self.assertEqual(
            self.output.read_bytes(), b"replacement owned by somebody else"
        )
        self.assertTrue(moved.exists())
        self.assert_not_formatted()
        self.assert_not_detached()

    def test_partition_failure_detaches_verified_device_then_removes_new_file(self):
        self.runner.partition_status = 1
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assertEqual(
            len(self.runner.commands(image_tool.DISKUTIL, "partitionDisk")), 1
        )
        self.assertEqual(len(self.runner.commands(image_tool.HDIUTIL, "detach")), 1)
        self.assertFalse(self.output.exists())

    def test_bad_partition_layouts_fail_and_clean_up(self):
        mutations = (
            lambda disk: disk.update(Content="FDisk_partition_scheme"),
            lambda disk: disk.update(DeviceIdentifier="disk99"),
            lambda disk: disk.update(Size=image_tool.GIB * 2),
            lambda disk: disk["Partitions"][1].update(Content="Apple_HFS"),
            lambda disk: disk["Partitions"].append(
                {
                    "DeviceIdentifier": "disk42s3",
                    "Content": "Apple_APFS",
                    "Size": 1024,
                }
            ),
            lambda disk: disk["Partitions"][1].update(
                DeviceIdentifier="disk99s2"
            ),
        )
        for index, mutation in enumerate(mutations):
            with self.subTest(index=index):
                self.runner = FakeMacRunner()
                self.runner.path = self.output
                self.output.touch()
                with self.output.open("r+b") as output:
                    output.truncate(image_tool.GIB)
                layout = self.runner._layout()
                self.output.unlink()
                mutation(layout["AllDisksAndPartitions"][0])
                self.runner.layout = layout
                with self.assertRaises(image_tool.ImageCreationError):
                    self.create()
                self.assertFalse(self.output.exists())
                self.assertFalse(self.runner.attached)

    def test_missing_raw_gpt_headers_fails_after_safe_detach(self):
        self.runner.write_headers = False
        with self.assertRaises(image_tool.ImageCreationError):
            self.create()
        self.assertFalse(self.runner.attached)
        self.assertFalse(self.output.exists())

    def test_detach_failure_retains_file_without_force_or_retry(self):
        self.runner.detach_status = 1
        self.assert_retained()
        self.assertTrue(self.runner.attached)
        self.assertEqual(
            self.runner.commands(image_tool.HDIUTIL, "detach"),
            [[image_tool.HDIUTIL, "detach", "/dev/disk42"]],
        )

    def test_successful_detach_exit_with_still_attached_image_retains_file(self):
        self.runner.keep_attached = True
        self.assert_retained()
        self.assertTrue(self.runner.attached)
        self.assertEqual(len(self.runner.commands(image_tool.HDIUTIL, "detach")), 1)

    def test_unverifiable_inventory_after_detach_retains_file(self):
        def fail_post_detach_info():
            if not self.runner.attached:
                self.runner.info_stdout = b"not a plist"

        self.runner.before_info = fail_post_detach_info
        self.assert_retained()
        self.assertFalse(self.runner.attached)
        self.assertEqual(len(self.runner.commands(image_tool.HDIUTIL, "detach")), 1)

    def test_interrupt_after_attach_detaches_safely_and_removes_new_file(self):
        def interrupt_info_once():
            self.runner.before_info = None
            raise KeyboardInterrupt()

        self.runner.before_info = interrupt_info_once
        with self.assertRaises(KeyboardInterrupt):
            self.create()
        self.assert_not_formatted()
        self.assertFalse(self.runner.attached)
        self.assertFalse(self.output.exists())
        self.assertEqual(len(self.runner.commands(image_tool.HDIUTIL, "detach")), 1)

    def test_reused_device_number_is_never_detached_during_failure_cleanup(self):
        original_run = self.runner.run

        def run_with_device_reuse(argv):
            result = original_run(argv)
            if argv[:2] == [image_tool.DISKUTIL, "partitionDisk"]:
                self.runner.attached = False
                self.runner.extra_images = [
                    {
                        "image-path": str(self.directory / "other.img"),
                        "system-entities": [{"dev-entry": "/dev/disk42"}],
                    }
                ]
            return result

        self.runner.partition_status = 1
        with mock.patch.object(self.runner, "run", side_effect=run_with_device_reuse):
            self.assert_retained()
        self.assert_not_detached()

    def test_size_argument_rejects_fractional_negative_and_too_large_values(self):
        for value in ("1.5", "-1", "0", "257", "not-a-number"):
            with self.subTest(value=value):
                with self.assertRaises(image_tool.argparse.ArgumentTypeError):
                    image_tool._size_argument(value)
        self.assertEqual(image_tool._size_argument("1"), 1)

    def test_cli_cannot_use_real_disk_tools_off_macos(self):
        with mock.patch.object(sys, "platform", "linux"):
            with contextlib.redirect_stderr(io.StringIO()) as output:
                status = image_tool.main(
                    ["--output", str(self.output), "--size-gib", "1"]
                )
        self.assertEqual(status, 1)
        self.assertIn("requires macOS", output.getvalue())
        self.assertFalse(self.output.exists())

    def test_system_runner_uses_shell_free_argv(self):
        command = [image_tool.HDIUTIL, "info", "-plist"]
        with mock.patch.object(sys, "platform", "darwin"):
            with mock.patch.object(subprocess, "run") as run:
                image_tool.SystemRunner().run(command)
        args, kwargs = run.call_args
        self.assertEqual(args, (command,))
        self.assertNotIn("shell", kwargs)
        self.assertIs(kwargs["check"], False)


if __name__ == "__main__":
    unittest.main()
