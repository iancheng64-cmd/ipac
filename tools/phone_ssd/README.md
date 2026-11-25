# iPac Phone SSD Toolkit

Date: 2026-11-25

Experimental manual tools for using a phone's spare storage without moving
iPac's CPU execution, RAM or JIT off the iPad. No phone or iPad acceptance test
has passed yet. The toolkit does not root, jailbreak, flash or format a phone.

## Device Paths

| Device | Current result |
| --- | --- |
| Samsung Galaxy Note10, already rooted | A manual USB mass-storage tools module is implemented. The exact variant, installed kernel, controller, SELinux policy and iPad enumeration still need physical validation. |
| iPhone 7, jailbroken iOS 15 | A read-only diagnostic probe is implemented. There is no verified iOS USB SSD driver in this toolkit. |

The preferred route is:

```text
Note10 private storage
  -> fully allocated, independent raw GPT/APFS image
  -> Linux USB mass-storage function
  -> USB data cable
  -> iPadOS external APFS volume
  -> iPac's existing external-file storage
```

Android serves opaque blocks and does not need to mount APFS. Never export
the phone's live userdata or system partitions. Never mount or modify the
backing image on the phone or another host while the iPad owns it.

## Provisioning Order

1. Read the exact Note10 model, Android build, kernel, root status and available
   space. Run the Android helper's read-only `probe` before making any USB
   change. Unknown evidence is not support.
2. On a Mac, create a new disposable 1 GiB image first:

   ```sh
   python3 /Users/ian/Documents/html/Henge-Custom/Henge/tools/phone_ssd/create_apfs_image.py \
     --output "$HOME/Documents/ipac-phone-test.img" --size-gib 1
   ```

   The output's parent must exist. Existing files, `.dmg` files and devices
   are refused. The tool formats only its verified, newly created virtual
   image and normally detaches it before returning.
3. Transfer the image using a trusted root-controlled path into
   `/data/adb/ipac-phone-ssd/images/`. Fully allocate the destination;
   the helper refuses sparse images. State/image directories must be
   root-owned `0700`, and the image root-owned `0600` with one hard link.
   Compare the destination's SHA-256 with the Mac source before export.
   A filesystem-full error is a failed transfer, not a usable disk.
4. Install `tools/phone_ssd/dist/ipac-phone-ssd-magisk-0.2.0.zip` in an already
   working Magisk App, or use the standalone shell helper. The ZIP root
   contains `module.prop`, `customize.sh` and `system/bin/ipac-phone-ssd`.
   It is not a recovery flashing ZIP and does not start USB at boot.
   Stop the VM and the helper before disabling or uninstalling the module.
5. From a local root-capable terminal on the phone, follow
   `android/README.md`. `start` requires `--ack-sole-writer`; occupied USB
   requires a separate explicit `--takeover`. ADB may disconnect, so do not
   depend on an interactive ADB shell for switching or recovery.
6. Connect the Note10 to the iPad with a compatible data cable and adequate
   power. Check that Files enumerates the APFS volume, then use disposable
   files to test writes, flush, clean stop and checksum-preserving reconnect.
   Stop if the vendor USB HAL reclaims the controller.
7. Only after physical validation, create a larger image based on real free
   space and provision a disposable VM directly on the external volume.
   Leave free space for the phone OS, filesystem metadata and garbage
   collection; a fully allocated image does not guarantee continued
   overwrites on a full F2FS/ext4 filesystem. Test disk-full behavior.
   Keep a separate verified backup before migrating any real VM.

The Mac image builder accepts whole-number sizes from 1 to 256 GiB. This is a
tool limit, not a claim that a phone can spare that much. Allocate storage
according to actual free space and the phone's continued operation.

## iPhone 7 Limit

Root privileges do not supply a USB mass-storage function or SCSI driver.
Linux configfs scripts cannot be applied to the running iOS kernel.
Project Sandcastle is a separate boot environment with experimental APFS
writing, not an iOS 15 disk-export plugin.

A powered Lightning USB 3 Camera Adapter plus compatible Ethernet adapter,
an Ethernet adapter on the iPad and an Ethernet link are a possible wired
network route. This needs an authenticated server and a new random-access
disk backend in iPac. Neither is implemented here. A shared folder in Files
does not establish VM streaming without a full local copy.

Run `iphone/probe.sh` from an existing iPhone terminal or SSH session for
read-only environment evidence. It does not start SSH or export a disk.

## Verification

Host-only suites:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p test_phone_apfs_image.py
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -p test_phone_ssd_android.py
sh tests/test_iphone_ssd_probe.sh
```

Final host-only results: 38 image-builder tests, 51 Android tests (no
skips), and 24 iPhone probe checks passed. An independent Android safety
review also passed nine focused regressions. These results do not establish
physical-device compatibility.

The release archive is `dist/ipac-phone-ssd-magisk-0.2.0.zip`. Its SHA-256 is
`08c10d09705b7ec716bbeee632ac27e14186d8d7075854a8b2e1bd9e9c7944d1`.
Verify the included checksum from `dist/`:

```sh
shasum -a 256 -c ipac-phone-ssd-magisk-0.2.0.zip.sha256
```

A real disposable 1 GiB image was created on the Mac. `diskutil
verifyVolume` ran `fsck_apfs -n` successfully. Separate read-only checks
validated primary/backup GPT header CRCs, both entry-array CRCs, matching
partition tables, a protective MBR, one APFS partition and its NXSB marker.
After writing a disposable test file, normal detach and read-only reattach
preserved its SHA-256 exactly. The test image and its mount directory were
then removed after confirming the image was no longer attached.
The image builder itself only checks raw size/GPT signatures and
`diskutil`'s layout; Android's header checks are likewise not a replacement
for complete filesystem verification.

`diskutil verifyDisk` declined the 1 GiB image with "target disk is too
small" (-69771). It is not counted as a passing verification; the GPT CRC
checks and APFS filesystem check above are the independent evidence.

Physical USB enumeration, transfer/allocation on the Note10, power, sustained
random I/O, phone lock/sleep, vendor HAL behavior, VM boot and snapshot
recovery remain unverified. Neither a passing mock nor a Mac image test is a
successful phone SSD installation.

Before relying on VM durability, also validate iPac's existing fast-flush
and pause/snapshot behavior. The previously inspected `HV_K_FLUSH=1` path
skips the disk flush, and the VM pause path discards flush results. This
toolkit does not repair those existing core contracts. A phone honoring FUA
does not prove that iPac issued every required flush. Real VM acceptance
must cover durable writes and error propagation, not just successful file
opening or USB enumeration.

See `IPAC_PHONE_STORAGE_PLAN.md`, `android/README.md` and `iphone/README.md`
for detailed boundaries and primary-source links.
