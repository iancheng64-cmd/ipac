import gzip
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import uuid
import zlib


REPO = Path(__file__).resolve().parents[1]
MODULE = REPO / "tools/phone_ssd/android/module"
HELPER = MODULE / "system/bin/ipac-phone-ssd"
APFS_GUID = uuid.UUID("7c3457ef-0000-11aa-aa11-00306543ecac").bytes_le
EFI_GUID = uuid.UUID("c12a7328-f81f-11d2-ba4b-00a0c93ec93b").bytes_le
DISK_BYTES = 2 * 1024 * 1024
LAST_LBA = DISK_BYTES // 512 - 1
APFS_START = 40
APFS_END = 4055


def partition(kind, start, end, identifier=1):
    entry = bytearray(128)
    entry[:16] = kind
    entry[16:32] = uuid.UUID(int=identifier).bytes_le
    struct.pack_into("<QQ", entry, 32, start, end)
    return entry


def raw_disk(entries=None):
    # Only a parser fixture, not a mountable or filesystem-validated APFS disk.
    disk = bytearray(b"\xa5" * DISK_BYTES)
    disk[:512] = b"\0" * 512
    disk[450] = 0xEE
    struct.pack_into("<II", disk, 454, 1, LAST_LBA)
    disk[510:512] = b"\x55\xaa"
    table = bytearray(128 * 128)
    if entries is None:
        entries = [partition(APFS_GUID, APFS_START, APFS_END)]
    for index, entry in enumerate(entries):
        table[index * 128:(index + 1) * 128] = entry
    disk[1024:1024 + len(table)] = table
    backup_table = LAST_LBA - 32
    disk[backup_table * 512:backup_table * 512 + len(table)] = table
    for current, other, table_lba in (
        (1, LAST_LBA, 2), (LAST_LBA, 1, backup_table)
    ):
        header = bytearray(512)
        header[:8] = b"EFI PART"
        struct.pack_into("<III", header, 8, 0x10000, 92, 0)
        struct.pack_into("<QQQQ", header, 24, current, other, 34, LAST_LBA - 33)
        header[56:72] = uuid.UUID(int=123).bytes_le
        struct.pack_into("<QIII", header, 72, table_lba, 128, 128,
                         zlib.crc32(table))
        struct.pack_into("<I", header, 16, zlib.crc32(header[:92]))
        disk[current * 512:(current + 1) * 512] = header
    apfs = APFS_START * 512
    disk[apfs:apfs + 4096] = b"\0" * 4096
    disk[apfs + 32:apfs + 36] = b"NXSB"
    struct.pack_into("<IQ", disk, apfs + 36, 4096,
                     (APFS_END - APFS_START + 1) // 8)
    return disk


def tree_snapshot(root):
    result = {}
    for directory, directories, files in os.walk(root, followlinks=False):
        for name in directories + files:
            path = Path(directory) / name
            relative = str(path.relative_to(root))
            if path.is_symlink():
                result[relative] = ("symlink", os.readlink(path))
            elif path.is_dir():
                result[relative] = ("directory", path.stat().st_mode & 0o7777)
            else:
                result[relative] = (
                    "file", path.stat().st_mode & 0o7777,
                    hashlib.sha256(path.read_bytes()).hexdigest(),
                )
    return result


class PhoneSSDTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="ipac-phone-ssd-test.", dir="/tmp"
        )
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.root.chmod(0o700)
        self.config = self.root / "config/usb_gadget"
        self.state = self.root / "data/adb/ipac-phone-ssd"
        self.gadget = self.config / "ipac_phone_ssd"
        for relative in (
            "config/usb_gadget", "sys/class/udc/udc0", "sys/block",
            "sys/module/usb_f_mass_storage", "proc", "mock",
            "data/adb/ipac-phone-ssd/images",
        ):
            (self.root / relative).mkdir(parents=True, exist_ok=True)
        for path in (self.root / "data/adb", self.state, self.state / "images"):
            path.chmod(0o700)
        self.write("sys/class/udc/udc0/state", "configured\n")
        self.boot_id = self.write(
            "proc/sys/kernel/random/boot_id",
            "11111111-2222-3333-4444-555555555555\n",
        )
        self.mountinfo = self.write(
            "proc/self/mountinfo",
            "100 1 0:42 / " + str(self.root / "config") +
            " rw - configfs configfs rw\n",
        )
        self.write("mock/properties", "ro.product.model=Fake Note10\n"
                   "ro.build.version.release=12\nro.boot.flash.locked=0\n")
        self.entropy = self.root / "mock/session_random"
        self.entropy.write_bytes(os.urandom(16))
        self.entropy.chmod(0o600)
        self.vendor = self.add_gadget("vendor", "udc0")
        self.image = self.state / "images/ipac.img"
        self.write_image(raw_disk())
        self.env = os.environ.copy()
        self.env["IPAC_PHONE_SSD_TEST_ROOT"] = str(self.root)
        self.env["IPAC_PHONE_SSD_TEST_UID"] = "0"

    def write(self, relative, value):
        path = self.root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding="ascii")
        path.chmod(0o600)
        return path

    def write_image(self, data):
        self.image.write_bytes(data)
        self.image.chmod(0o600)
        self.assertGreaterEqual(self.image.stat().st_blocks * 512,
                                self.image.stat().st_size)

    def add_gadget(self, name, binding=""):
        gadget = self.config / name
        (gadget / "functions").mkdir(parents=True)
        (gadget / "UDC").write_text(binding + "\n", encoding="ascii")
        return gadget

    def outside(self):
        temporary = tempfile.TemporaryDirectory(
            prefix="ipac-phone-ssd-outside.", dir="/tmp"
        )
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name).resolve()

    def run_helper(self, *arguments, env=None, trace=False):
        command = ["sh"]
        if trace:
            command.append("-x")
        return subprocess.run(
            command + [str(HELPER), *map(str, arguments)],
            env=self.env if env is None else env,
            capture_output=True, text=True, timeout=20,
        )

    def run_internal_operation(self, name):
        self.assertIn(name, ("unbind_own", "remove_own_gadget", "rollback"))
        program = (
            'set -- help\n. "$IPAC_PHONE_SSD_SOURCE"\n'
            "take_lock\nselect_config || exit 1\nload_state || exit 1\n"
            "CREATED=1\n" + name + "\n"
        )
        env = dict(self.env, IPAC_PHONE_SSD_SOURCE=str(HELPER))
        return subprocess.run(
            ["sh", "-c", program], env=env, capture_output=True,
            text=True, timeout=20,
        )

    def start(self, takeover=True):
        arguments = ["start", self.image, "--ack-sole-writer"]
        if takeover:
            arguments.append("--takeover")
        return self.run_helper(*arguments)

    def assert_success(self, process):
        self.assertEqual(process.returncode, 0, process.stdout + process.stderr)

    def assert_failure(self, process, reason=None):
        self.assertNotEqual(process.returncode, 0,
                            process.stdout + process.stderr)
        if reason:
            self.assertIn(reason, process.stderr)

    def assert_original_intact(self):
        self.assertEqual((self.vendor / "UDC").read_text().strip(), "udc0")
        self.assertFalse(self.gadget.exists())
        self.assertFalse((self.state / "active").exists())
        self.assertFalse((self.state / "lock").exists())

    def test_probe_is_read_only_without_root(self):
        before = tree_snapshot(self.root)
        self.env["IPAC_PHONE_SSD_TEST_UID"] = "1000"
        process = self.run_helper("probe")
        self.assert_success(process)
        self.assertIn("model=Fake Note10", process.stdout)
        self.assertIn("mass_storage=confirmed", process.stdout)
        self.assertIn("udc_owner=vendor", process.stdout)
        self.assertEqual(before, tree_snapshot(self.root))

    def test_missing_config_with_saved_state_never_reads_root_udc(self):
        self.assert_success(self.start())
        shutil.rmtree(self.config)
        before = tree_snapshot(self.root)
        process = self.run_helper("probe", trace=True)
        self.assert_success(process)
        self.assertIn("configfs=unknown", process.stdout)
        self.assertNotIn("+ read_one /UDC", process.stderr)
        self.assertEqual(before, tree_snapshot(self.root))

    def test_start_requires_ack_and_root(self):
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("start", self.image),
                            "--ack-sole-writer")
        self.assertEqual(before, tree_snapshot(self.root))
        self.env["IPAC_PHONE_SSD_TEST_UID"] = "1000"
        self.assert_failure(self.start(), "require root")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_busy_controller_refused_by_default(self):
        before = tree_snapshot(self.root)
        self.assert_failure(self.start(takeover=False), "controller is busy")
        self.assert_original_intact()
        self.assertEqual(before, tree_snapshot(self.root))

    def test_takeover_and_stop_restore_original_with_fua(self):
        process = self.start()
        self.assert_success(process)
        self.assertIn("fua=preserved", process.stdout)
        self.assertEqual((self.vendor / "UDC").read_text().strip(), "")
        lun = self.gadget / "functions/mass_storage.0/lun.0"
        for name, value in (("ro", "0"), ("cdrom", "0"),
                            ("removable", "1"), ("nofua", "0")):
            self.assertEqual((lun / name).read_text().strip(), value)
        self.assertEqual((lun / "file").read_text().strip(), str(self.image))
        self.assertEqual((self.gadget / "UDC").read_text().strip(), "udc0")
        active = self.state / "active"
        self.assertEqual(active.stat().st_mode & 0o777, 0o700)
        for path in active.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assert_success(self.run_helper("stop"))
        self.assert_original_intact()

    def test_free_controller_start_and_stop(self):
        (self.vendor / "UDC").write_text("\n")
        self.assert_success(self.start(takeover=False))
        process = self.run_helper("stop")
        self.assert_success(process)
        self.assertIn("restored_owner=none", process.stdout)
        self.assertEqual((self.vendor / "UDC").read_text().strip(), "")
        self.assertFalse(self.gadget.exists())

    def test_bind_failure_rolls_back_original(self):
        self.write("mock/bind_error", "1\n")
        self.assert_failure(self.start(), "binding failed")
        self.assert_original_intact()

    def test_competitor_race_never_steals_and_retains_recovery_state(self):
        competitor = self.add_gadget("competitor")
        marker = self.write("mock/competitor_before_bind", "competitor\n")
        self.assert_failure(self.start(), "binding failed")
        self.assertEqual((competitor / "UDC").read_text().strip(), "udc0")
        self.assertEqual((self.vendor / "UDC").read_text().strip(), "")
        self.assertFalse(self.gadget.exists())
        self.assertTrue((self.state / "active").is_dir())
        marker.unlink()
        self.assert_failure(self.run_helper("stop"), "restoration state retained")
        self.assertEqual((competitor / "UDC").read_text().strip(), "udc0")
        (competitor / "UDC").write_text("\n")
        self.assert_success(self.run_helper("stop"))
        self.assert_original_intact()

    def test_stop_does_not_displace_hal_or_unrelated_controller(self):
        self.assert_success(self.start())
        (self.gadget / "UDC").write_text("\n")
        competitor = self.add_gadget("competitor", "udc0")
        self.assert_failure(self.run_helper("stop"), "restoration state retained")
        self.assertEqual((competitor / "UDC").read_text().strip(), "udc0")
        self.assertTrue((self.state / "active").exists())
        self.assertFalse(self.gadget.exists())

    def test_stop_accepts_original_already_restored_by_hal(self):
        self.assert_success(self.start())
        (self.gadget / "UDC").write_text("\n")
        (self.vendor / "UDC").write_text("udc0\n")
        self.assert_success(self.run_helper("stop"))
        self.assert_original_intact()

    def test_stop_refuses_changed_own_binding(self):
        self.assert_success(self.start())
        (self.gadget / "UDC").write_text("other_udc\n")
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "own binding changed")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_stop_rejects_changed_lun_for_saved_session(self):
        self.assert_success(self.start())
        (self.gadget / "functions/mass_storage.0/lun.0/file").write_text(
            "/someone-else/private.img\n", encoding="ascii"
        )
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "session identity")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_stop_rejects_changed_session_marker(self):
        self.assert_success(self.start())
        (self.gadget / "strings/0x409/serialnumber").write_text(
            "ipac-another-session\n", encoding="ascii"
        )
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "session identity")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_stop_rejects_missing_session_marker(self):
        self.assert_success(self.start())
        (self.gadget / "strings/0x409/serialnumber").unlink()
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "session identity")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_stop_rejects_recreated_gadget_with_different_session(self):
        self.assert_success(self.start())
        retired = self.config / "retired_gadget"
        self.gadget.rename(retired)
        (retired / "UDC").write_text("\n")
        shutil.copytree(retired, self.gadget, symlinks=True)
        (self.gadget / "UDC").write_text("udc0\n")
        (self.gadget / "strings/0x409/serialnumber").write_text(
            "ipac-a-new-owner\n", encoding="ascii"
        )
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "session identity")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_host_ejected_media_can_stop_and_restore_original(self):
        self.assert_success(self.start())
        (self.gadget / "functions/mass_storage.0/lun.0/file").write_bytes(b"")
        probe = self.run_helper("probe")
        self.assert_success(probe)
        self.assertIn("saved_session=bound-media-ejected", probe.stdout)
        process = self.run_helper("stop")
        self.assert_success(process)
        self.assert_original_intact()

    def test_empty_lun_recreated_gadget_is_refused_even_with_same_marker(self):
        self.assert_success(self.start())
        (self.gadget / "functions/mass_storage.0/lun.0/file").write_bytes(b"")
        retired = self.config / "retired_gadget"
        self.gadget.rename(retired)
        (retired / "UDC").write_text("\n")
        shutil.copytree(retired, self.gadget, symlinks=True)
        (self.gadget / "UDC").write_text("udc0\n")
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"))
        self.assertEqual(before, tree_snapshot(self.root))

    def test_empty_lun_missing_session_marker_is_refused(self):
        self.assert_success(self.start())
        (self.gadget / "functions/mass_storage.0/lun.0/file").write_bytes(b"")
        (self.gadget / "strings/0x409/serialnumber").unlink()
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"))
        self.assertEqual(before, tree_snapshot(self.root))

    def test_empty_lun_recreated_function_is_refused(self):
        self.assert_success(self.start())
        function = self.gadget / "functions/mass_storage.0"
        (function / "lun.0/file").write_bytes(b"")
        retired = function.with_name("retired_function")
        function.rename(retired)
        shutil.copytree(retired, function, symlinks=True)
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"))
        self.assertEqual(before, tree_snapshot(self.root))

    def test_empty_lun_recreated_lun_is_refused(self):
        self.assert_success(self.start())
        lun = self.gadget / "functions/mass_storage.0/lun.0"
        (lun / "file").write_bytes(b"")
        retired = lun.with_name("retired_lun")
        lun.rename(retired)
        shutil.copytree(retired, lun, symlinks=True)
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"))
        self.assertEqual(before, tree_snapshot(self.root))

    def test_missing_saved_own_instance_identity_is_refused(self):
        self.assert_success(self.start())
        saved_id = self.state / "active/gadget_id"
        if saved_id.exists():
            saved_id.unlink()
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"))
        self.assertEqual(before, tree_snapshot(self.root))

    def test_each_session_receives_fresh_persistent_identity(self):
        self.assert_success(self.start())
        first = (self.state / "active/session").read_text().strip()
        self.assertRegex(first, "^[0-9a-f]{32}$")
        self.assertEqual(
            (self.gadget / "strings/0x409/serialnumber").read_text().strip(),
            "ipac-" + first,
        )
        self.assert_success(self.run_helper("stop"))
        self.entropy.write_bytes(os.urandom(16))
        self.assert_success(self.start())
        second = (self.state / "active/session").read_text().strip()
        self.assertNotEqual(first, second)
        self.assert_success(self.run_helper("stop"))

    def test_cleanup_and_exit_trap_refuse_replaced_session(self):
        self.assert_success(self.start())
        (self.gadget / "functions/mass_storage.0/lun.0/file").write_text(
            "/someone-else/private.img\n", encoding="ascii"
        )
        for name in ("unbind_own", "remove_own_gadget", "rollback"):
            with self.subTest(operation=name):
                before = tree_snapshot(self.root)
                self.assert_failure(self.run_internal_operation(name),
                                    "session identity")
                self.assertEqual(before, tree_snapshot(self.root))

    def replace_vendor(self, binding):
        retired = self.config / "retired_vendor"
        self.vendor.rename(retired)
        shutil.copytree(retired, self.vendor, symlinks=True)
        (retired / "UDC").write_text("\n")
        (self.vendor / "UDC").write_text(binding + "\n")

    def test_stop_rejects_original_vendor_replacement(self):
        self.assert_success(self.start())
        self.replace_vendor("")
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "original gadget instance")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_stop_rejects_original_vendor_replacement_already_bound(self):
        self.assert_success(self.start())
        (self.gadget / "UDC").write_text("\n")
        self.replace_vendor("udc0")
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "original gadget instance")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_saved_state_from_another_boot_refuses_all_usb_changes(self):
        self.assert_success(self.start())
        self.boot_id.write_text("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n")
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "invalid/untrusted")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_saved_state_from_replaced_configfs_mount_refuses_all_changes(self):
        self.assert_success(self.start())
        self.mountinfo.write_text(
            "101 1 0:42 / " + str(self.root / "config") +
            " rw - configfs configfs rw\n", encoding="ascii"
        )
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "invalid/untrusted")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_missing_identity_evidence_refuses_start_without_usb_changes(self):
        for path in (self.entropy, self.boot_id, self.mountinfo):
            with self.subTest(path=path):
                held = path.with_name(path.name + ".held")
                path.rename(held)
                try:
                    self.assert_failure(self.start())
                    self.assert_original_intact()
                finally:
                    held.rename(path)

    def test_no_state_stop_does_not_change_usb(self):
        before = tree_snapshot(self.root)
        self.assert_success(self.run_helper("stop"))
        self.assertEqual(before, tree_snapshot(self.root))

    def test_reserved_gadget_and_stale_lock_are_never_deleted(self):
        reserved = self.add_gadget("ipac_phone_ssd")
        self.assert_failure(self.start(), "reserved gadget already exists")
        self.assertTrue(reserved.is_dir())
        shutil.rmtree(reserved)
        self.write("data/adb/ipac-phone-ssd/lock/pid", "987654321\n")
        (self.state / "lock").chmod(0o700)
        before = tree_snapshot(self.root)
        self.assert_failure(self.start(), "stale lock exists")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_missing_driver_and_fua_fail_before_takeover(self):
        (self.root / "sys/module/usb_f_mass_storage").rmdir()
        self.assert_failure(self.start(), "mass-storage function is unavailable")
        self.assert_original_intact()
        (self.root / "sys/module/usb_f_mass_storage").mkdir()
        self.write("mock/no_nofua", "1\n")
        self.assert_failure(self.start(), "FUA preserved")
        self.assert_original_intact()

    def test_existing_mass_storage_function_is_valid_driver_evidence(self):
        (self.root / "sys/module/usb_f_mass_storage").rmdir()
        (self.vendor / "functions/mass_storage.other").mkdir()
        process = self.run_helper("probe")
        self.assert_success(process)
        self.assertIn("mass_storage_evidence=existing-configfs-function",
                      process.stdout)

    def test_ambiguous_controller_requires_explicit_selection(self):
        (self.root / "sys/class/udc/udc1").mkdir()
        self.assert_failure(self.start(), "missing/ambiguous")
        self.assert_original_intact()
        self.assert_success(self.run_helper("start", self.image,
                            "--ack-sole-writer", "--takeover", "--udc", "udc0"))
        self.assert_success(self.run_helper("stop"))

    def test_raw_device_and_non_image_path_are_rejected_without_access(self):
        before = tree_snapshot(self.root)
        for path in ("/dev/disk0", "/dev/null", self.root / "elsewhere.img",
                     self.state / "images/../ipac.img"):
            with self.subTest(path=path):
                self.assert_failure(self.run_helper(
                    "start", path, "--ack-sole-writer", "--takeover"
                ))
        self.assertEqual(before, tree_snapshot(self.root))

    def test_image_permissions_and_links_are_rejected(self):
        self.image.chmod(0o644)
        self.assert_failure(self.start(), "mode 0600")
        self.image.chmod(0o600)
        link = self.image.with_name("hardlink.img")
        os.link(self.image, link)
        self.assert_failure(self.start(), "exactly one hard link")
        link.unlink()
        target = self.image.with_suffix(".bin")
        self.image.rename(target)
        self.image.symlink_to(target)
        self.assert_failure(self.start(), "not a device, directory or symlink")
        self.image.unlink()
        self.image.mkdir()
        self.assert_failure(self.start(), "not a device, directory or symlink")
        self.assert_original_intact()

    def test_sparse_image_rejected(self):
        self.image.unlink()
        with self.image.open("wb") as file:
            file.write(b"EFI PART")
            file.seek(64 * 1024 * 1024 - 1)
            file.write(b"x")
        self.image.chmod(0o600)
        if self.image.stat().st_blocks * 512 >= self.image.stat().st_size:
            self.skipTest("host filesystem does not expose sparse allocation")
        self.assert_failure(self.start(), "sparse")
        self.assert_original_intact()

    def test_unaligned_image_rejected(self):
        self.write_image(raw_disk() + b"x")
        self.assert_failure(self.start(), "512-aligned")
        self.assert_original_intact()

    def test_malformed_image_signatures_and_geometry(self):
        mutations = (
            (510, b"\0\0", "protective-MBR"),
            (512, b"BAD PART", "primary GPT"),
            (512 + 24, struct.pack("<Q", 2), "primary GPT"),
            (512 + 72, struct.pack("<Q", LAST_LBA), "out of bounds"),
            (512 + 80, struct.pack("<I", 129), "primary GPT"),
            (LAST_LBA * 512, b"BAD PART", "backup GPT"),
            (LAST_LBA * 512 + 56, b"\xff" * 16, "backup GPT"),
            ((LAST_LBA - 32) * 512 + 16, b"\xff", "tables differ"),
            (APFS_START * 512 + 32, b"NOPE", "NXSB"),
            (APFS_START * 512 + 36, struct.pack("<I", 8192), "block size"),
            (APFS_START * 512 + 40, struct.pack("<Q", 1), "container size"),
            (DISK_BYTES - 512, b"koly", "UDIF/DMG"),
            (0, b"sprs", "sparse disk-image containers"),
        )
        for offset, value, error in mutations:
            with self.subTest(offset=offset, error=error):
                data = raw_disk()
                data[offset:offset + len(value)] = value
                self.write_image(data)
                self.assert_failure(self.start(), error)
                self.assert_original_intact()

    def test_optional_efi_and_bad_partition_layouts(self):
        self.write_image(raw_disk([
            partition(EFI_GUID, 34, 39, 2),
            partition(APFS_GUID, APFS_START, APFS_END),
        ]))
        self.assert_success(self.start())
        self.assert_success(self.run_helper("stop"))
        for entries in (
            [partition(EFI_GUID, 34, 40, 2),
             partition(APFS_GUID, APFS_START, APFS_END)],
            [partition(APFS_GUID, APFS_START, APFS_END),
             partition(APFS_GUID, 40, 55, 2)],
            [partition(uuid.UUID(int=456).bytes_le, APFS_START, APFS_END)],
            [partition(APFS_GUID, APFS_START - 1, APFS_END)],
        ):
            with self.subTest(entries=entries):
                self.write_image(raw_disk(entries))
                self.assert_failure(self.start(), "one APFS data partition")
                self.assert_original_intact()

    def test_loop_backing_file_rejected(self):
        self.write("sys/block/loop0/loop/backing_file", str(self.image) + "\n")
        self.assert_failure(self.start(), "in use by a loop device")
        self.assert_original_intact()

    def test_untrusted_parent_state_and_image_directories_rejected(self):
        for path in (self.root / "data/adb", self.state, self.state / "images"):
            with self.subTest(path=path):
                path.chmod(0o777)
                self.assert_failure(self.start())
                self.assert_original_intact()
                path.chmod(0o700)

    def test_state_values_are_data_not_shell_programs(self):
        self.assert_success(self.start())
        sentinel = self.root / "executed"
        (self.state / "active/original").write_text(
            "$(touch " + str(sentinel) + ")\n", encoding="ascii"
        )
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "invalid/untrusted")
        self.assertFalse(sentinel.exists())
        self.assertEqual(before, tree_snapshot(self.root))

    def test_extra_or_untrusted_state_fields_refuse_all_usb_changes(self):
        self.assert_success(self.start())
        extra = self.write("data/adb/ipac-phone-ssd/active/extra", "untrusted\n")
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "invalid/untrusted")
        self.assertEqual(before, tree_snapshot(self.root))
        extra.unlink()
        image_field = self.state / "active/image"
        image_field.chmod(0o644)
        before = tree_snapshot(self.root)
        self.assert_failure(self.run_helper("stop"), "invalid/untrusted")
        self.assertEqual(before, tree_snapshot(self.root))

    def test_mock_root_validation_and_standalone_uid_rejected(self):
        for value in ("/", "/Users", str(self.root / "../..")):
            with self.subTest(value=value):
                env = dict(self.env, IPAC_PHONE_SSD_TEST_ROOT=value)
                self.assert_failure(self.run_helper("probe", env=env))
        alias = self.root / "alias"
        alias.symlink_to(self.outside(), target_is_directory=True)
        self.assert_failure(self.run_helper(
            "probe", env=dict(self.env, IPAC_PHONE_SSD_TEST_ROOT=str(alias))
        ), "must not be a symlink")
        self.root.chmod(0o755)
        self.assert_failure(self.run_helper("probe"), "mode 0700")
        self.root.chmod(0o700)
        env = self.env.copy()
        env.pop("IPAC_PHONE_SSD_TEST_ROOT")
        self.assert_failure(self.run_helper("probe", env=env))

    def test_property_parent_symlink_never_reads_outside_tree(self):
        outside = self.outside()
        (outside / "properties").write_text(
            "ro.product.model=OUTSIDE_PRIVATE_DATA\n", encoding="ascii"
        )
        shutil.rmtree(self.root / "mock")
        (self.root / "mock").symlink_to(outside, target_is_directory=True)
        process = self.run_helper("probe")
        self.assert_success(process)
        self.assertNotIn("OUTSIDE_PRIVATE_DATA", process.stdout)

    def test_driver_parent_symlinks_never_confirm_outside_evidence(self):
        (self.root / "sys/module/usb_f_mass_storage").rmdir()
        outside = self.outside()
        (outside / "usb_f_mass_storage").mkdir()
        (self.root / "sys/module").rmdir()
        (self.root / "sys/module").symlink_to(outside, target_is_directory=True)
        process = self.run_helper("probe")
        self.assert_success(process)
        self.assertIn("mass_storage=unknown", process.stdout)
        (self.root / "sys/module").unlink()
        (self.root / "sys/module").mkdir()
        (outside / "mass_storage.outside").mkdir()
        (self.vendor / "functions").rmdir()
        (self.vendor / "functions").symlink_to(outside, target_is_directory=True)
        process = self.run_helper("probe")
        self.assert_success(process)
        self.assertIn("mass_storage=unknown", process.stdout)
        (self.vendor / "functions").unlink()
        (self.vendor / "functions").mkdir()
        (outside / "config.gz").write_bytes(gzip.compress(
            b"CONFIG_USB_CONFIGFS_MASS_STORAGE=y\n"
        ))
        shutil.rmtree(self.root / "proc")
        (self.root / "proc").symlink_to(outside, target_is_directory=True)
        process = self.run_helper("probe", trace=True)
        self.assert_success(process)
        self.assertIn("mass_storage=unknown", process.stdout)
        self.assertNotIn("+ zcat ", process.stderr)

    def test_owner_and_udc_state_parent_symlinks_never_read_outside(self):
        outside = self.outside()
        (outside / "UDC").write_text("udc0\n", encoding="ascii")
        (outside / "functions").mkdir()
        self.vendor.rename(self.config / "hidden_vendor")
        self.vendor.symlink_to(outside, target_is_directory=True)
        (self.config / "hidden_vendor/UDC").write_text("\n")
        process = self.run_helper("probe")
        self.assert_success(process)
        self.assertNotIn("udc_owner=vendor", process.stdout)
        shutil.rmtree(self.root / "sys/class/udc/udc0")
        (outside / "state").write_text("OUTSIDE_PRIVATE_DATA\n", encoding="ascii")
        (self.root / "sys/class/udc/udc0").symlink_to(
            outside, target_is_directory=True
        )
        process = self.run_helper("probe")
        self.assert_success(process)
        self.assertNotIn("OUTSIDE_PRIVATE_DATA", process.stdout)

    def test_image_parent_symlink_cannot_escape(self):
        outside = self.outside()
        self.image.rename(outside / "ipac.img")
        (self.state / "images").rmdir()
        (self.state / "images").symlink_to(outside, target_is_directory=True)
        before = tree_snapshot(outside)
        self.assert_failure(self.start())
        self.assertEqual(before, tree_snapshot(outside))
        self.assert_original_intact()

    def test_mock_marker_parent_symlink_cannot_read_or_write_outside(self):
        outside = self.outside()
        (outside / "no_nofua").write_text("1\n", encoding="ascii")
        shutil.rmtree(self.root / "mock")
        (self.root / "mock").symlink_to(outside, target_is_directory=True)
        process = self.start()
        self.assert_failure(process, "mock")
        self.assert_original_intact()

    def test_cleanup_parent_symlink_cannot_delete_outside_files(self):
        self.assert_success(self.start())
        outside = self.outside()
        protected = outside / "configuration"
        protected.write_text("PRIVATE_DATA", encoding="ascii")
        directory = self.gadget / "configs/c.1/strings/0x409"
        shutil.rmtree(directory)
        directory.symlink_to(outside, target_is_directory=True)
        self.assert_failure(self.run_helper("stop"))
        self.assertTrue(protected.exists())
        self.assertEqual(protected.read_text(), "PRIVATE_DATA")
        self.assertTrue((self.state / "active").is_dir())

    def test_module_layout_has_no_automatic_usb_switching(self):
        self.assertTrue((MODULE / "module.prop").is_file())
        self.assertTrue((MODULE / "customize.sh").is_file())
        self.assertTrue(HELPER.is_file())
        for name in ("service.sh", "post-fs-data.sh", "system.prop",
                     "sepolicy.rule"):
            self.assertFalse((MODULE / name).exists())
        customize = (MODULE / "customize.sh").read_text()
        self.assertNotIn("ipac-phone-ssd start", customize)
        self.assertNotIn("setenforce", customize)
        self.assertNotIn("/UDC", customize)


if __name__ == "__main__":
    unittest.main()
