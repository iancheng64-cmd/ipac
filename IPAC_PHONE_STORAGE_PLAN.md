# iPac Phone Storage Feasibility

Date: 2026-11-25

Status: Manual Android tools and Mac image preparation implemented;
device-specific validation is still required.

This is not an implemented network-disk feature or a verified phone setup.
The new tools do not unlock bootloaders, flash kernels, format live phone
partitions, or change iPac's application code. Existing unrelated worktree
changes are preserved.

The identified candidates are an iPhone 7 running jailbroken iOS 15 and a
Samsung Galaxy Note10. The Note10's exact SM-N970 variant, installed kernel,
root status and available storage have not yet been read from the device.

## Delivered Tools

- `tools/phone_ssd/create_apfs_image.py`: creates only a new raw `.img`,
  with GPT and one APFS data partition, using macOS tools. It refuses
  existing files and verifies the newly created file's ownership and its
  whole virtual-disk mapping before partitioning.
- `tools/phone_ssd/android/module/`: a Magisk App tools module containing
  `ipac-phone-ssd`. Installation does not change USB or run the helper at
  boot. `probe` is read-only; manual `start` requires a separate image and
  explicit sole-writer acknowledgement. A busy controller requires an
  additional explicit `--takeover`.
- `tools/phone_ssd/iphone/probe.sh`: read-only iPhone 7 / iOS 15 diagnostics.
  This is not an iOS USB mass-storage driver.
- `tools/phone_ssd/README.md`: provisioning order, validation evidence and
  the remaining physical-device checks.

The Android helper preserves FUA, reads restoration state as data rather
than shell code, and does not displace a third party during recovery. It
rejects raw block devices, linked files, sparse backing files, unsupported
containers and inconsistent GPT/APFS geometry. Its bounded header checks
are not a full filesystem or GPT CRC verification.

The Mac file can be sparse; transfer it with full allocation into the
Android's private, root-owned image directory. The phone's advertised
capacity is not the available image capacity.

## Requirements

- Keep the large VM disk images on another device, rather than downloading a
  complete copy to the 64 GB iPad.
- Preserve the phone's operating system, applications, and existing data.
- Use actual available storage, not the phone's advertised 128/256 GB capacity.
- Keep the iPac application, CPU execution, guest RAM, and JIT on the iPad.
  Sharing storage does not provide the phone's RAM or processor to the VM.
- Support offset-based reads and writes, ordering, and durable flushes.
- Never acknowledge successful durable writes while disconnected.
- Allow only one writer to each exported VM disk.

## Options

| Device / transport | Feasibility | Existing iPac support |
| --- | --- | --- |
| Normal iPhone, direct USB APFS disk | Apple File Sharing is document copying, not an export of the internal APFS disk | Not a supported phone-as-disk path |
| Normal iPhone, custom network server app | Possible experiment while the server remains active; background execution is not an always-on guarantee | Requires a new remote backend and server |
| iPhone 7 / jailbroken iOS 15, direct Lightning cable | No working iOS USB mass-storage driver has been established; jailbreak alone is insufficient | Diagnostic probe only, not a disk driver |
| Jailbroken iPhone, network daemon | Worth evaluating; daemon installation and availability depend on the jailbreak and OS | Requires a new remote backend and a suitable server |
| Root Galaxy Note10, USB mass-storage gadget | Manual prototype implemented; root alone is insufficient and the exact kernel is still unknown | Could reuse the external-file backend if iPadOS mounts it successfully |
| Android, userspace network server | Does not inherently require root or an APFS driver; sleep and power management still matter | Requires a new remote backend and server |

## ADR-PHONE-001: Prefer a Real USB Disk When Supported

### Status

Prototype implemented; pending the exact Note10 variant, kernel capabilities
and hardware test.

### Context

iPac currently opens local or mounted external files with POSIX
`open`/`fstat` and performs `pread`/`pwrite`. It does not accept SMB, SFTP,
WebDAV, or NBD URLs as disk backends. Seeing a remote folder in Files does not
prove that iPac can read and write its VM image without local materialization.

Apple's File Provider APIs ordinarily provide/download local file contents.
The public `NSFileProviderPartialContentFetching` protocol is documented for
macOS, not iPadOS; it cannot be assumed to solve iPad VM streaming.

### Decision

First check whether the Android has a working USB device controller and
mass-storage gadget support. If it does, test a separate, disposable image:

```text
Android ext4/f2fs storage
  -> independent raw whole-disk image
     -> GPT + one APFS data partition
        -> portable iPac VM directory and images
  -> USB mass-storage gadget
  -> iPadOS external volume
  -> existing iPac external-file backend
```

Android only serves the image's blocks; it does not need to mount APFS.
Create the APFS filesystem on a Mac. Never export the phone's live userdata
partition. Never modify or mount the backing image from another process while
the iPad has it attached.

Do not assume an Android file-transfer/MTP setting is mass storage. Root,
kernel configuration, UDC support, vendor USB HAL, and SELinux are separate
requirements. If kernel support is absent, evaluate the network option before
considering any bootloader unlock or kernel replacement.

### Consequences

- Avoids developing a network disk backend if the gadget works correctly.
- Requires a compatible data connection, host/device roles, and adequate power.
- Apple supports APFS external volumes, not every Android gadget implementation.
- Reserve backing-image space on the phone or otherwise prove allocation
  guarantees; a sparse image must not silently overcommit the underlying disk.
- Preserve FUA semantics (`nofua=false`). Stop the VM before detaching.
- Validate actual iPac flush/pause/snapshot behavior before real VM use.
  The existing fast-flush no-op and discarded flush results described below
  are not repaired by a USB gadget; they also matter for mounted external
  files. Successful enumeration alone is not durability acceptance.
- Do not operate the USB switch from an interactive ADB shell: takeover can
  disconnect it. Use an on-device root-capable terminal and retain a recovery
  path that does not depend on USB.
- A vendor USB HAL can reclaim the controller after a successful initial
  bind. Test screen lock, cable reconnect and power transitions; neither
  root nor a passing host mock establishes stable USB ownership.
- Validate with a disposable VM, never the only copy of an existing VM.

### Device-Specific Limits

Samsung publishes separate source packages for Note10 variants such as
SM-N970F and SM-N9700. They are not interchangeable, and the existence of a
source download does not prove that the installed kernel has mass-storage
support. The helper checks runtime and readable kernel evidence rather
than guessing from a model name.

Magisk's Samsung instructions warn about restricted bootloader unlocking on
some USA/Canada models, first-install data wipes and irreversible Knox
changes. No unlocking, rooting or kernel replacement is part of this
toolkit. Determine the exact model and back up personal data before separately
considering any such operation.

For iPhone 7, Project Sandcastle's USB support applies to a separately booted
Android/Linux environment, not a USB-disk tweak running on iOS 15. Its APFS
writing is experimental and disabled for safety. It is not a validated way
to export writable phone storage in this project.

## ADR-PHONE-002: Use Direct Remote Block I/O as the Fallback

### Status

Proposed; no remote transport or companion server has been implemented.

### Proposed Decision

Use a file-based server on the jailbroken iPhone or Android, with an explicit
remote backend in iPac:

```text
Phone filesystem -> VM disk image -> authenticated disk server
                                        |
                              encrypted local-network link
                                        |
iPad iPac -> remote disk backend -> guest macOS/APFS
```

Here APFS is inside the guest disk image. There is no requirement to mount an
APFS volume in Android or expose the iPhone's operating-system partition.
Start with a local Wi-Fi network; direct iPad-to-phone USB networking has not
been verified. A wired alternative can use a powered Lightning USB 3 Camera
Adapter and compatible USB Ethernet adapter on the iPhone, an Ethernet
adapter on the USB-C iPad, and an Ethernet connection between them. Apple's
adapter documentation supports those interface types, not an iPac disk
server. This is not a single phone data cable and still needs the new backend.

Prefer a maintained block protocol implementation where portability and
licensing permit. NBD over an authenticated encrypted transport is a candidate,
not a verified dependency. SFTP would need random I/O, verified durable-sync
support, and an additional exclusive-writer mechanism; file sharing alone is
not enough.

### Required iPac Changes

- Add local/remote operations behind `HvDisk`, preserving the existing
  `hv_disk_read/write/flush` boundary and virtio block device.
- Handle the four disk workers with correct request multiplexing or explicit
  connection serialization.
- Do not inherit the current fast-flush no-op for remote disks. A remote FLUSH
  must confirm durable storage on the server, not just arrival in its RAM.
- Propagate disk flush failures through VM pause and snapshot creation.
  Current `host/vm.c` discards flush results and determines `pause_clean` from
  request idleness; this is not sufficient for remote snapshot safety.
- Add bounded timeouts and a fault state. Arrange VM pause through its control
  path, not a synchronous disk-worker call that could join itself.
- Verify server identity, disk UUID/generation, and a single-writer lease.
  Do not blindly replay writes whose completion is unknown.
- Replace local inode/mtime snapshot identity checks with trustworthy remote
  identities for both root and auxiliary disks.
- Keep caches bounded. Dirty writes must not accumulate indefinitely on the
  storage-limited iPad.
- Define a phone-side provisioning/import route so initial installation does
  not require downloading the complete VM or installer to the iPad.

### Operational Trade-Offs

- Network latency and power management can make this slower than a USB SSD.
  No throughput or boot-time promise is currently justified.
- A normal iPhone app is not a guaranteed background NAS. Newer
  `BGContinuedProcessingTask` APIs can continue work but may still be cancelled
  or terminated; foreground operation with power is an initial test condition.
- Jailbreak daemons require the actual jailbreak's bootstrap, signing, and
  restart behavior. Do not assume palera1n's loopback SSH port 44 is a LAN server.
- Use authenticated pairing and pinned server identity. Never expose an
  unauthenticated writable disk to the internet.
- This solves disk capacity, not the iPad's RAM/JIT limits. The iPac app itself
  still needs to be installed on the iPad.

## Validation and Information Needed

An earlier Xcode device listing reported an iPad Air (5th generation) and a
paired iPhone 13. The current Mac USB inventory did not enumerate the
iPhone 7 or Note10. Neither observation establishes those phones' actual
configuration or proves a working direct phone-to-iPad connection.

Before choosing or changing a phone:

1. Confirm the intended iPad, its OS version, and available local storage.
2. Confirm the iPhone 7's exact iOS 15 build, available storage, jailbreak
   tool and rootful/rootless configuration.
3. Read the Note10's exact SM-N970 model, OS/build, kernel, root status,
   available storage and controller/driver evidence.
4. Perform read-only gadget/kernel checks if evaluating Android USB storage.
5. Use an independent test image to verify mounting, offset writes, flush,
   orderly detach, and remount checksums.
6. With a disposable VM, test boot, install/update, sustained random I/O,
   phone lock/sleep, cable/network loss, disk-full errors, and snapshot recovery.
7. Keep a separate verified backup before migrating any real VM.

## Sources

- [Apple: External storage on iPad](https://support.apple.com/guide/ipad/external-storage-devices-ipad75b7b23f/ipados)
- [Apple: Finder File Sharing](https://support.apple.com/en-us/119585)
- [Apple: File Provider fetchContents](https://developer.apple.com/documentation/fileprovider/nsfileproviderreplicatedextension/fetchcontents(for:version:request:completionhandler:))
- [Apple: Partial content fetching](https://developer.apple.com/documentation/fileprovider/nsfileproviderpartialcontentfetching)
- [Apple: BGContinuedProcessingTask](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
- [Linux: Mass Storage Gadget](https://docs.kernel.org/usb/mass-storage.html)
- [Linux: Gadget configfs](https://docs.kernel.org/usb/gadget_configfs.html)
- [Samsung: SM-N970F source packages](https://opensource.samsung.com/uploadSearch?searchValue=SM-N970F)
- [Samsung: SM-N9700 source packages](https://opensource.samsung.com/uploadSearch?searchValue=SM-N9700)
- [Magisk: Samsung installation warnings](https://topjohnwu.github.io/Magisk/install.html#samsung-devices)
- [Apple: Lightning USB Camera Adapter](https://support.apple.com/en-us/111811)
- [Apple: USB-C iPad connections](https://support.apple.com/en-us/108894)
- [Project Sandcastle: Original support status](https://projectsandcastle.org/status)
- [Android common: Gadget Kconfig](https://android.googlesource.com/kernel/common/+/refs/heads/android-mainline/drivers/usb/gadget/Kconfig)
- [AOSP: GadgetFunction](https://android.googlesource.com/platform/hardware/interfaces/+/refs/heads/main/usb/gadget/aidl/android/hardware/usb/gadget/GadgetFunction.aidl)
- [palera1n: Official manpage](https://github.com/palera1n/palera1n/blob/main/docs/palera1n.1)
- [Theos: Rootless](https://theos.dev/docs/rootless)
