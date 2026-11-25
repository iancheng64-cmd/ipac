# iPhone 7 wired storage diagnostics

This directory contains a read-only probe, not a USB mass-storage driver, a
jailbreak package, or a running disk server. A matching device result does not
mean that an iPad can mount the phone as a disk.

## Probe

Run `sh probe.sh` from an existing terminal or SSH session on the iPhone. The
probe does not enable SSH, invoke a server, obtain root, change USB settings,
mount anything, or read keys and personal files.

It reports only public platform/model identifiers, the `ProductVersion` from
`SystemVersion.plist`, the current UID, and known bootstrap/binary path markers.
The targeted model identifiers are `iPhone9,1` and `iPhone9,3`, with iOS 15.
Absent markers mean unknown, not proof of a non-jailbroken device. Rootless
paths can differ by jailbreak; no specific jailbreak tool is inferred.

`usb_mass_storage_driver` remains `not-implemented` and capability remains
`unverified`. The presence of an SSH binary is not proof of a running or
reachable server.

For offline tests only:

```sh
sh tests/test_iphone_ssd_probe.sh
```

The fixture option tags its output as `fixture_mode: true`; it is not device
acceptance.

## Wired routes

- A Lightning data cable alone does not establish that iOS 15 exports a USB
  mass-storage function. A SpringBoard tweak cannot substitute for a tested
  USB device-controller/function implementation. Linux configfs instructions
  do not apply to a running iOS kernel.
- Project Sandcastle boots a separate Android/Linux environment. Its original
  status page lists iPhone 7 USB support but marks APFS writing experimental
  and disabled for safety. It is not an iOS USB-disk plugin, and this project
  does not install it or export a live phone APFS partition.
- A possible wired-network fallback uses a powered Lightning USB 3 Camera
  Adapter plus a supported USB Ethernet adapter on the iPhone, a compatible
  Ethernet adapter on the iPad, and an Ethernet connection. This still needs
  an iPac network-disk backend, secure server, flush ordering, and disconnect
  protection. It is not a one-data-cable USB SSD.

Sources:

- https://projectsandcastle.org/status
- https://github.com/corellium/projectsandcastle
- https://support.apple.com/en-us/111811
- https://support.apple.com/en-us/108894
