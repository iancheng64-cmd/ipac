# Android Phone SSD tools (experimental)

This module installs `ipac-phone-ssd`, a manual Android shell tool. It does not
install or flash a kernel, unlock a bootloader, change SELinux, stop a vendor
USB HAL, or configure USB at boot. There is no `service.sh` or `post-fs-data.sh`.
No Galaxy Note10 hardware was connected for this implementation.

## Device support is detected, not assumed

`Note10` is a family name, not proof of root or USB mass-storage capability.
The Samsung Open Source portal currently lists different Android 12 source
packages for SM-N970F (EUR) and SM-N9700 (HKTW/CHN). A portal query returning
no entry for SM-N970N or SM-N970U1 does not prove that no source exists.
F/N and U/U1/0 variants must not be treated as interchangeable.

Magisk's official installation guide warns that USA/Canada Samsung models
may not permit unlocking, that first installation on Samsung requires a
data wipe, and that tripping Knox is irreversible. This module performs none
of those operations. It only works when the existing kernel, controller and
policy already permit a configfs mass-storage function.

Sources:

- <https://opensource.samsung.com/uploadSearch?searchValue=SM-N970F>
- <https://opensource.samsung.com/uploadSearch?searchValue=SM-N9700>
- <https://topjohnwu.github.io/Magisk/install.html#samsung-devices>
- <https://docs.kernel.org/usb/mass-storage.html>
- <https://docs.kernel.org/usb/gadget_configfs.html>
- <https://support.apple.com/guide/ipad/external-storage-devices-ipad75b7b23f/ipados>

## Magisk installation layout

The installable archive is the **contents** of `module/`, not its parent
directory: `module.prop`, `customize.sh` and `system/bin/ipac-phone-ssd` must
be at the ZIP root. Install that archive with Magisk App's "Install from
storage" after the device already has working Magisk. `customize.sh` only
installs the command and sets its executable permissions; it contains no
USB, root, bootloader or kernel setup. This is a project-authored tools
module, not a Samsung driver or a prebuilt replacement kernel.

There is intentionally no `META-INF` recovery installer. This archive is for
Magisk App, not for flashing in stock/custom recovery. Reboot may be needed
for Magisk's system overlay to expose the command, but does not start or
change USB. Do not install it as a workaround for a locked bootloader or
missing kernel capabilities.

## Commands

`ipac-phone-ssd probe` is read-only and does not require root. It reports
the actual model, controller, configfs mount, existing owner and driver
evidence. `confirmed` refers to the kernel driver evidence, not proof of
SELinux write permission, iPad enumeration, reliable power or performance.
Unreadable or unavailable evidence is `unknown`, never an assumed success.
Run it again after start: a vendor HAL can reclaim USB after the initial check.

Prepare a separate, fully allocated raw image on the Mac using the project's
image-preparation tool. It must have matching primary/backup GPT geometry,
one APFS data partition (an EFI partition is optional), and a 4096-byte APFS
container. Copy it into `/data/adb/ipac-phone-ssd/images/` using a trusted,
root-controlled transfer. The state and image directories must be root-owned
mode `0700`; the image must be root-owned mode `0600` with one hard link.
This tool neither copies the image nor initializes or formats any disk.

A fully allocated image does **not** guarantee that a nearly full Android
filesystem can sustain rewriting it. F2FS/log-structured storage still needs
free space for metadata, garbage collection and the phone's own operation;
copy-on-write filesystems also need working space. Do not allocate all phone
storage to the image. Check actual free space and test a controlled disk-full
failure with disposable data. This is a phone-storage requirement, separate
from iPac's configurable guest RAM limits.

The helper rejects raw block devices, symbolic/hard links, sparse files,
UDIF/DMG/sparse-image containers, loop-mounted images, unexpected partitions,
out-of-range GPT geometry and missing APFS NXSB data. These are bounded
sanity checks (at most 128 GPT entries, images up to 1 TiB), **not full GPT
CRC validation, APFS checksum validation or fsck**. The Mac-prepared image
must already have passed filesystem validation. Do not use a personal-data
image for the first device test.

Explicit commands, run manually only:

Use a **local root-capable terminal on the Android phone** for `start` and
`stop`. The following `su -c` commands belong in that terminal. `--takeover`
disconnects the existing USB ADB connection; an interactive `adb shell` is
not a reliable control/recovery channel and its process is not guaranteed
to survive USB reconfiguration. Probe may be collected through ADB because
it does not change USB.

```sh
su -c 'ipac-phone-ssd probe'
su -c 'ipac-phone-ssd start /data/adb/ipac-phone-ssd/images/ipac.img --ack-sole-writer'
su -c 'ipac-phone-ssd stop'
```

If more than one controller exists, supply `--udc NAME` from probe.
Start refuses a busy controller by default. The explicit `--takeover`
option authorizes disconnecting the confirmed existing gadget, including
ADB/MTP. Have a non-USB recovery/control method ready before using it.
Preparation and FUA validation finish before the old gadget is unbound.
Private, root-owned restoration fields are read as data, never sourced.
Each start creates a random 128-bit session identifier, stores it in private
state, and uses it as the gadget's USB serial number. Stop and rollback check
both that marker and the actual LUN backing image before unbinding/removing a
prepared gadget. A replaced/missing marker, changed image or same-name gadget
from another session is refused without changing USB or saved state.
The own gadget, mass-storage function and LUN device/inode identities are
also saved and checked. A legal host SCSI eject can leave the backing-file
attribute empty: cleanup is allowed only when all these same-instance
identities, the session marker, boot ID and mount generation still match.
Start preparation still requires the expected open image. A recreated
same-name gadget/function/LUN with an empty file, missing identity evidence,
or a nonempty different image remains refused. Probe reports a matched,
bound but ejected session as `bound-media-ejected`, not usable mounted media.
Partial
preparation cleanup is limited to this invocation's newly created directory
instance, with an empty UDC and no conflicting marker/image. Legacy version-1
state is deliberately refused; inspect it instead of bypassing ownership
checks or deleting it blindly.
The original gadget's device/inode identity is recorded without modifying
its serial number or other attributes. A changed/missing original instance
is not unbound or restored. State also records the boot ID and configfs mount
generation, so old state is refused after reboot, remount or a different USB
mount namespace instead of trusting potentially reused inode numbers.
Binding failure attempts rollback; restoration never displaces a third party.
If a HAL reclaims USB or restoration is unsafe, state is retained and the
command reports failure, not a successful or safe connection.

`stop` must be run **after iPac has stopped the VM and flushed/closed its
files, and iPadOS has finished using the external volume**. It is not an
emergency eject operation and cannot make in-flight writes safe. Do not unplug
during VM operation. Never mount or write the same image on Android or another
host while it is exported. `--ack-sole-writer` is an explicit operator
acknowledgement; it cannot detect every privileged program with an open fd.

The helper keeps `nofua=0`; ignoring FUA for speed is not permitted. Configfs
or SELinux failures stop the operation rather than relaxing system policy.
USB sysfs has no cross-process compare-and-swap ownership transaction:
repeated ownership checks and kernel binding errors minimize races but cannot
guarantee that a vendor HAL will never intervene. SIGKILL/power loss can also
interrupt recovery; saved state is retained for explicit inspection/stop.
A stale operation lock is never automatically removed or used to kill a pid.

## Physical validation still required

Confirm the exact Note10 model/build, existing root status, actual available
space, USB data cable, iPad connector/adapter and power arrangement. Start
with a disposable image. Verify APFS enumeration, read/write/fsync, clean
stop/reconnect, sustained random I/O, screen-lock behavior and vendor-HAL
ownership stability before placing a VM on it. No speed or zero-data-loss
guarantee is made. Android does not need an APFS filesystem driver: the
gadget serves opaque blocks and iPadOS mounts the APFS volume.
Explicitly test whether the vendor USB HAL rebinds its old gadget after
start, screen lock/unlock, cable reconnect or a power transition. A helper
that initially binds successfully has not passed that hardware acceptance.

## Host-only tests

```sh
python3 -m unittest discover -s tests -p test_phone_ssd_android.py
```

Tests run the shell helper against a caller-owned private
`/tmp/ipac-phone-ssd-test.*` tree. All paths remain in that tree; test flags
cannot redirect operations to real `/config`, `/sys`, `/data`, or a device.
No phone, ADB, USB configuration or root operation is used by these tests.
