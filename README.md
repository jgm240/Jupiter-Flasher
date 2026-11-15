# Jupiter Flasher

A Rufus-style USB creator for macOS, written in SwiftUI. Jupiter is the Roman god of thunder – and you *flash* a stick. ⚡

Makes bootable Windows USB drives from an ISO (Windows 11/10/8/7/Vista and XP/2000/2003), writes hybrid images
byte-for-byte, tests drives for fake capacity and bad blocks, and clones drives to image files.

> Not affiliated with Microsoft or the Rufus project. You supply your own Windows ISOs.

## Install

Download `Jupiter-Flasher-<version>.zip` from the [Releases](https://github.com/jgm240/Jupiter-Flasher/releases) page, unzip,
and open **Jupiter Flasher.app**. The app is ad-hoc signed, not notarized, so on first launch right-click → **Open**
(or run `xattr -dr com.apple.quarantine "Jupiter Flasher.app"`).

Windows 10/11 ISOs have an `install.wim` over 4 GB, which FAT32 can't hold; Jupiter Flasher splits it with
[wimlib](https://wimlib.net/): `brew install wimlib`.

## Build from source

    ./scripts/build_app.sh          # builds "build/Jupiter Flasher.app"  (VERSION=1.2.3 ./scripts/build_app.sh to set the version)

Needs macOS 13+ and the Xcode Command Line Tools (`xcode-select --install`). No Xcode required.

## Modes

| Mode | What it does |
|---|---|
| **Windows ISO** | Formats the stick FAT32 (UEFI-bootable), copies the installer, splits `install.wim`, optionally adds legacy-BIOS boot and an unattended-setup answer file, then verifies every file byte-for-byte. |
| **DD image** | Writes an ISO/IMG raw (Linux hybrid ISOs, disk images), optionally verifying by reading back. |
| **Test drive** | Writes unique pseudo-random data to every block (or ~256 samples across the drive in quick mode) and reads it back: catches fake-capacity sticks and bad blocks. Destroys the drive's contents. |
| **Clone drive** | Reads a whole drive into an `.img` file. Nothing on the drive is changed. |

Raw device access needs root on macOS, so DD / Test / Clone ask for your administrator password and run the bundled
`jupiterflash-cli` helper, which re-checks that the target is an external whole disk (never internal or the boot disk).

## Windows ISO details

* **Legacy BIOS (CSM) boot** – takes Windows' own MBR code and FAT32 boot record from `boot/bootsect.exe` on the ISO.
* **Customization** – optional `autounattend.xml`: remove Windows 11 TPM / Secure Boot / RAM / CPU checks, skip the
  Microsoft-account and network screens (optionally creating a local user), skip privacy questions, disable automatic
  BitLocker, reuse this Mac's region and time zone.
* **Vista / 7** – detected; UEFI boot files are extracted from `install.wim` for 64-bit Windows 7.
* **Windows 2000 / XP / 2003** – detected automatically. Legacy BIOS only, MBR scheme. Microsoft's NT5 boot code isn't on
  these discs, so Jupiter Flasher writes its own small MBR + FAT32 loader (`scripts/loaders/*.S`, rebuild with
  `scripts/build_loaders.sh`) that loads `NTLDR`. The stick gets the CD contents plus a `$WIN_NT$.~BT` copy of `I386`,
  and a `winnt.sif` that points text-mode setup at the stick. Needs about twice the CD's size.
  * *Disable ACPI* – for "BIOS is not fully ACPI compliant" (STOP 0xA5) on newer PCs: sets `ACPIEnable = 0` in the setup
    boot files, same effect as pressing F7 at setup start.
  * *Storage driver* – pick a text-mode (F6) driver folder (with `txtsetup.oem`) to be loaded automatically, e.g. Intel
    AHCI/RAID. Written as `$OEM$\TEXTMODE` + `[MassStorageDrivers]` in `winnt.sif`.
* **Checksum** – paste the SHA-256 from the download page and compare it with the ISO before flashing.
* Settings and recent ISOs are remembered; `.iso` files can be dropped on the window or the Dock icon.

## Status / known limits

* XP: boots into setup and reaches the "Welcome to Setup" screen in QEMU. Not yet confirmed on real hardware, and the
  *Storage driver* injection has only been checked statically (no real driver pack was available to test with).
  XP has no built-in AHCI / USB 3.0 drivers: use IDE/Compatible SATA mode and a USB 2.0 port, or supply a driver.
* Not supported yet: Windows 95/98/ME/MS-DOS media, and multi-ISO (Ventoy-style) sticks.
* Drive test and clone use the same admin-password mechanism as DD mode; they're tested against image files, not yet
  against a physical stick.

## CLI

    swift run jupiterflash-cli list
    swift run jupiterflash-cli inspect <iso>
    swift run jupiterflash-cli sha256 <file> [expected-hash]
    swift run jupiterflash-cli flash <iso> <diskN> --yes [--bios] [--no-acpi] [--nt5-drivers DIR] ...

## License

GPL-3.0-or-later – see [LICENSE](LICENSE).

* [wimlib](https://wimlib.net/)'s `wimlib-imagex` (GPLv3+) is run as a separate program and is neither linked nor bundled.
* The boot loaders in `scripts/loaders` are original code. Microsoft's boot code is read from the user's own ISO at
  run time and is not part of this repository.
* Inspired by [Rufus](https://rufus.ie/) (GPLv3); no Rufus code is used.
