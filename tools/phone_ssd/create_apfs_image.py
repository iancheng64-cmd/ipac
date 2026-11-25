#!/usr/bin/env python3
"""Create a new raw GPT/APFS image for an Android USB mass-storage gadget."""

import argparse
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
from dataclasses import dataclass
from typing import List, Optional, Sequence
from xml.parsers.expat import ExpatError


HDIUTIL = "/usr/bin/hdiutil"
DISKUTIL = "/usr/sbin/diskutil"
GIB = 1024 ** 3
MIN_SIZE_GIB = 1
MAX_SIZE_GIB = 256
WHOLE_DEVICE = re.compile(r"^/dev/disk[0-9]+$")


class ImageCreationError(RuntimeError):
    def __init__(self, message: str, retained_path: Optional[Path] = None):
        super().__init__(message)
        self.retained_path = retained_path


class SystemRunner:
    def __init__(self):
        if sys.platform != "darwin":
            raise ImageCreationError("This tool requires macOS.")

    def run(self, argv: Sequence[str]) -> subprocess.CompletedProcess:
        return subprocess.run(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            timeout=300,
        )


@dataclass
class _NewImage:
    path: Path
    fd: int
    size_bytes: int
    device_id: int
    inode: int
    attach_attempted: bool = False
    detach_attempted: bool = False
    device: Optional[str] = None

    def check_file(self, require_size: bool = True) -> None:
        try:
            current = self.path.lstat()
            opened = os.fstat(self.fd)
        except OSError as error:
            raise ImageCreationError(
                "The new image's file identity cannot be verified."
            ) from error
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_dev != self.device_id
            or current.st_ino != self.inode
            or opened.st_dev != self.device_id
            or opened.st_ino != self.inode
        ):
            raise ImageCreationError(
                "The output path no longer identifies the file created by this tool."
            )
        if require_size and (
            current.st_size != self.size_bytes or opened.st_size != self.size_bytes
        ):
            raise ImageCreationError("The raw image's size changed unexpectedly.")


def _validated_size(size_gib: int) -> int:
    if (
        not isinstance(size_gib, int)
        or isinstance(size_gib, bool)
        or not MIN_SIZE_GIB <= size_gib <= MAX_SIZE_GIB
    ):
        raise ImageCreationError(
            "--size-gib must be an integer from {} to {}.".format(
                MIN_SIZE_GIB, MAX_SIZE_GIB
            )
        )
    return size_gib * GIB


def _validated_path(output) -> Path:
    try:
        text = os.fspath(output)
    except TypeError as error:
        raise ImageCreationError("--output must name a new .img file.") from error
    if not isinstance(text, str) or not text.strip() or "\x00" in text:
        raise ImageCreationError("--output must name a new .img file.")
    try:
        path = Path(text).expanduser()
    except RuntimeError as error:
        raise ImageCreationError("The output's home directory cannot be resolved.") from error
    if path.name in ("", ".", "..") or path.suffix.lower() != ".img":
        raise ImageCreationError("--output must name a new .img file, not a .dmg.")
    try:
        parent = path.parent.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise ImageCreationError("The output's parent directory must exist.") from error
    if not parent.is_dir():
        raise ImageCreationError("The output's parent must be a directory.")
    return parent / path.name


def _run(runner, argv: Sequence[str]) -> subprocess.CompletedProcess:
    try:
        result = runner.run(list(argv))
    except (OSError, subprocess.SubprocessError) as error:
        raise ImageCreationError(
            "{} {} failed: {}.".format(Path(argv[0]).name, argv[1], error)
        ) from error
    if result.returncode != 0:
        detail = result.stderr
        if isinstance(detail, bytes):
            detail = detail.decode("utf-8", errors="replace")
        detail = (detail or "").strip()
        if len(detail) > 1000:
            detail = detail[:1000] + "..."
        raise ImageCreationError(
            "{} {} failed (exit {}){}.".format(
                Path(argv[0]).name,
                argv[1],
                result.returncode,
                ": " + detail if detail else "",
            )
        )
    return result


def _plist(runner, argv: Sequence[str]) -> dict:
    result = _run(runner, argv)
    try:
        value = plistlib.loads(result.stdout)
    except (ValueError, TypeError, OverflowError, ExpatError) as error:
        raise ImageCreationError(
            "{} {} returned an invalid plist.".format(
                Path(argv[0]).name, argv[1]
            )
        ) from error
    if not isinstance(value, dict):
        raise ImageCreationError("The command's plist root is not a dictionary.")
    return value


def _entities(value: dict) -> List[dict]:
    entries = value.get("system-entities")
    if not isinstance(entries, list) or any(
        not isinstance(entry, dict) for entry in entries
    ):
        raise ImageCreationError("The disk image's device mapping is invalid.")
    return entries


def _whole_devices(value: dict) -> List[str]:
    devices = {
        entry["dev-entry"]
        for entry in _entities(value)
        if isinstance(entry.get("dev-entry"), str)
        and WHOLE_DEVICE.fullmatch(entry["dev-entry"])
    }
    return sorted(devices)


def _images(info: dict) -> List[dict]:
    images = info.get("images")
    if not isinstance(images, list) or any(
        not isinstance(image, dict)
        or not isinstance(image.get("image-path"), str)
        or not image["image-path"]
        for image in images
    ):
        raise ImageCreationError("hdiutil's image inventory cannot be verified.")
    for image in images:
        _entities(image)
    return images


def _is_image_path(image: dict, path: Path) -> bool:
    image_path = image["image-path"]
    if not os.path.isabs(image_path) or "\x00" in image_path:
        return False
    try:
        return Path(image_path).resolve(strict=False) == path
    except (OSError, RuntimeError, ValueError):
        raise ImageCreationError("hdiutil reported an unverifiable image path.")


def _matching_images(info: dict, path: Path) -> List[dict]:
    return [image for image in _images(info) if _is_image_path(image, path)]


def _image_info(runner) -> dict:
    return _plist(runner, [HDIUTIL, "info", "-plist"])


def _verify_owned_device(
    image: _NewImage, device: str, info: dict, runner, require_size: bool = True
) -> None:
    image.check_file(require_size=require_size)
    if not WHOLE_DEVICE.fullmatch(device):
        raise ImageCreationError("Refusing an invalid whole-device identifier.")
    matches = _matching_images(info, image.path)
    if len(matches) != 1:
        raise ImageCreationError(
            "The new image does not have one unambiguous hdiutil mapping."
        )
    devices = [entry.get("dev-entry") for entry in _entities(matches[0])]
    if device not in devices:
        raise ImageCreationError(
            "The attached whole device is not mapped to the new image."
        )
    for other in _images(info):
        if other is not matches[0] and any(
            entry.get("dev-entry") == device for entry in _entities(other)
        ):
            raise ImageCreationError("Another image also claims this device.")

    device_info = _plist(runner, [DISKUTIL, "info", "-plist", device])
    if (
        device_info.get("WholeDisk") is not True
        or device_info.get("VirtualOrPhysical") != "Virtual"
        or device_info.get("DeviceNode") != device
    ):
        raise ImageCreationError(
            "Refusing to operate on a device not verified as this whole virtual disk."
        )
    image.check_file(require_size=require_size)


def _verify_partition_layout(image: _NewImage, runner) -> None:
    layout = _plist(runner, [DISKUTIL, "list", "-plist", image.device])
    disks = layout.get("AllDisksAndPartitions")
    if not isinstance(disks, list):
        raise ImageCreationError("diskutil returned an invalid partition list.")
    identifier = image.device[len("/dev/"):]
    matches = [
        disk
        for disk in disks
        if isinstance(disk, dict) and disk.get("DeviceIdentifier") == identifier
    ]
    if (
        len(matches) != 1
        or matches[0].get("Content") != "GUID_partition_scheme"
        or matches[0].get("Size") != image.size_bytes
    ):
        raise ImageCreationError("The new image does not contain the expected GPT disk.")
    partitions = matches[0].get("Partitions")
    if not isinstance(partitions, list) or not partitions:
        raise ImageCreationError("The new image has no APFS data partition.")
    apfs_count = 0
    efi_count = 0
    seen = set()
    for partition in partitions:
        if not isinstance(partition, dict):
            raise ImageCreationError("The new image has an invalid partition entry.")
        name = partition.get("DeviceIdentifier")
        size = partition.get("Size")
        if (
            not isinstance(name, str)
            or not re.fullmatch(re.escape(identifier) + r"s[0-9]+", name)
            or name in seen
            or not isinstance(size, int)
            or isinstance(size, bool)
            or not 0 < size <= image.size_bytes
        ):
            raise ImageCreationError("The new image has an invalid partition identity.")
        seen.add(name)
        if partition.get("Content") == "Apple_APFS":
            apfs_count += 1
        elif partition.get("Content") == "EFI":
            efi_count += 1
        else:
            raise ImageCreationError("The new image contains an unexpected partition.")
    if apfs_count != 1 or efi_count > 1:
        raise ImageCreationError("Exactly one APFS data partition is required.")


def _ensure_unattached(image: _NewImage, runner) -> None:
    image.check_file(require_size=False)
    info = _image_info(runner)
    matches = _matching_images(info, image.path)
    if not matches:
        if image.device and any(
            entry.get("dev-entry") == image.device
            for other in _images(info)
            for entry in _entities(other)
        ):
            raise ImageCreationError(
                "The previous device now maps to another image; cleanup is uncertain."
            )
        return
    if len(matches) != 1:
        raise ImageCreationError("The new image has ambiguous attachments.")
    if image.detach_attempted:
        raise ImageCreationError("The previous detach attempt did not release the image.")
    devices = _whole_devices(matches[0])
    device = image.device
    if device is None:
        if len(devices) != 1:
            raise ImageCreationError("The new image's whole device is ambiguous.")
        device = devices[0]
    _verify_owned_device(image, device, info, runner, require_size=False)
    image.device = device
    image.detach_attempted = True
    detach_error = None
    try:
        _run(runner, [HDIUTIL, "detach", device])
    except ImageCreationError as error:
        detach_error = error

    # A failed attach/detach command can still change state. Trust a fresh
    # inventory, never a stale disk number or the command's exit status alone.
    remaining = _matching_images(_image_info(runner), image.path)
    if remaining:
        if detach_error is not None:
            raise detach_error
        raise ImageCreationError("hdiutil still reports the new image as attached.")


def _verify_raw_image(image: _NewImage) -> None:
    image.check_file()
    os.fsync(image.fd)
    if os.pread(image.fd, 8, 512) != b"EFI PART":
        raise ImageCreationError("The raw image is missing its primary GPT header.")
    tail = os.pread(image.fd, 512, image.size_bytes - 512)
    if tail[:4] == b"koly" or tail[:8] != b"EFI PART":
        raise ImageCreationError("The raw image is missing its backup GPT header.")


def _cleanup_failure(image: _NewImage, runner) -> Optional[str]:
    try:
        image.check_file(require_size=False)
        if image.attach_attempted:
            _ensure_unattached(image, runner)
        image.check_file(require_size=False)
        image.path.unlink()
    except (Exception, KeyboardInterrupt) as error:
        return (
            "Cleanup could not be proven safe: {} "
            "No output file was removed; inspect {} before reusing it."
        ).format(error, image.path)
    return None


def create_apfs_image(output, size_gib: int, runner=None) -> Path:
    """Create only a new regular file; never accept an existing disk or image."""
    size_bytes = _validated_size(size_gib)
    path = _validated_path(output)
    if runner is None:
        runner = SystemRunner()
    if not hasattr(os, "O_NOFOLLOW"):
        raise ImageCreationError("This platform cannot safely create the image file.")
    try:
        fd = os.open(
            path, os.O_CREAT | os.O_EXCL | os.O_RDWR | os.O_NOFOLLOW, 0o600
        )
    except OSError as error:
        raise ImageCreationError(
            "Cannot create a new output file; existing files and symlinks are refused: {}."
            .format(error)
        ) from error
    opened = os.fstat(fd)
    image = _NewImage(path, fd, size_bytes, opened.st_dev, opened.st_ino)
    try:
        if not stat.S_ISREG(opened.st_mode):
            raise ImageCreationError("The newly created output is not a regular file.")
        os.fchmod(fd, 0o600)
        os.ftruncate(fd, size_bytes)
        os.fsync(fd)
        image.check_file()
        image.attach_attempted = True
        attached = _plist(
            runner,
            [
                HDIUTIL,
                "attach",
                "-nomount",
                "-readwrite",
                "-imagekey",
                "diskimage-class=CRawDiskImage",
                "-plist",
                str(path),
            ],
        )
        devices = _whole_devices(attached)
        if len(devices) != 1:
            raise ImageCreationError("Attach did not identify exactly one whole device.")
        image.device = devices[0]
        _verify_owned_device(image, image.device, _image_info(runner), runner)
        _run(
            runner,
            [
                DISKUTIL,
                "partitionDisk",
                image.device,
                "GPT",
                "APFS",
                "iPac SSD",
                "100%",
            ],
        )
        _verify_partition_layout(image, runner)
        _ensure_unattached(image, runner)
        _verify_raw_image(image)
        return path
    except (Exception, KeyboardInterrupt) as error:
        cleanup_warning = _cleanup_failure(image, runner)
        message = "Interrupted." if isinstance(error, KeyboardInterrupt) else str(error)
        if cleanup_warning:
            message += " " + cleanup_warning
        retained_path = path if cleanup_warning else None
        if isinstance(error, KeyboardInterrupt):
            raise KeyboardInterrupt(message) from error
        raise ImageCreationError(message, retained_path=retained_path) from error
    finally:
        os.close(fd)


def _size_argument(text: str) -> int:
    if not re.fullmatch(r"[0-9]+", text):
        raise argparse.ArgumentTypeError("--size-gib must be a whole number.")
    try:
        value = int(text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("--size-gib is not a valid integer.") from error
    try:
        _validated_size(value)
    except ImageCreationError as error:
        raise argparse.ArgumentTypeError(str(error)) from error
    return value


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", required=True, help="A new .img file in an existing directory."
    )
    parser.add_argument(
        "--size-gib",
        required=True,
        type=_size_argument,
        help="Raw disk size in GiB ({}-{}).".format(MIN_SIZE_GIB, MAX_SIZE_GIB),
    )
    arguments = parser.parse_args(argv)
    try:
        path = create_apfs_image(arguments.output, arguments.size_gib)
    except ImageCreationError as error:
        print("Error: " + str(error), file=sys.stderr)
        return 1
    except KeyboardInterrupt as error:
        print(str(error), file=sys.stderr)
        return 130
    print("Created raw GPT/APFS image: {}".format(path))
    print("Size: {} GiB; no UDIF/.dmg wrapper.".format(arguments.size_gib))
    print(
        "The Mac file may be sparse. Fully allocate it after transfer to Android; "
        "do not overcommit the phone's free space."
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
