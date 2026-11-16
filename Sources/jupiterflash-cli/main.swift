// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import JupiterFlashCore

func usage() -> Never {
    print("""
    usage:
      jupiterflash-cli list [--all]
      jupiterflash-cli inspect <iso>
      jupiterflash-cli verify <iso> <volume-path>      (read-only: compare a flashed drive with the ISO)
      jupiterflash-cli dd <image> <diskN> --yes [--verify] [--progress-file F] [--cancel-file F]   (needs root)
      jupiterflash-cli sha256|sha1|md5|hash <file> [expected-hash]   (hash: algorithm follows the expected hash's length)
      jupiterflash-cli badblocks <diskN> --yes [--quick] [--progress-file F] [--cancel-file F]   (DESTROYS data; needs root)
      jupiterflash-cli clone <diskN> <out.img> --yes [--uid N] [--progress-file F] [--cancel-file F]   (needs root)
      jupiterflash-cli driverinfo <folder>      (check an XP text-mode driver folder)
      jupiterflash-cli unattend [--bypass-hw] [--skip-account] [--local-user NAME] [--privacy] [--no-bitlocker] [--mac-region]
      jupiterflash-cli bios <diskN> --mbr F --pbr F --yes [--progress-file F]   (needs root)
      jupiterflash-cli write-loader <image-file> <NTLDR|BOOTMGR>
      jupiterflash-cli flash <iso> <diskN> [--label NAME] [--gpt] [--no-eject] [--no-verify] [--bios] [--no-acpi] [--nt5-drivers DIR] [--bypass-hw] [--skip-account] [--local-user N] [--privacy] [--no-bitlocker] [--mac-region] --yes
    """)
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { usage() }

func run() async throws {
    switch cmd {
    case "list":
        let disks = try await DiskService.listDisks(includeFixed: args.contains("--all"))
        if disks.isEmpty { print("No USB drives found.") }
        for d in disks { print(d.displayName) }
    case "inspect":
        guard args.count >= 2 else { usage() }
        let info = try await ISOInspector.inspect(iso: URL(fileURLWithPath: args[1]))
        print(info.summary)
        print("windows installer: \(info.isWindowsInstaller), needs split: \(info.needsSplit), UEFI boot files: \(info.hasUEFIBoot)")
    case "verify":
        guard args.count >= 3 else { usage() }
        let mounted = try await ISOInspector.mount(URL(fileURLWithPath: args[1]))
        defer { Task { await ISOInspector.detach(mounted) } }
        var lastPct = -1
        try await Flasher.verifyVolume(isoMount: mounted.url, volume: URL(fileURLWithPath: args[2]),
            progress: { f, msg in let p = Int(f * 100); if p / 10 != lastPct / 10 { lastPct = p; print("[\(p)%] \(msg)") } },
            log: { print("  \($0)") })
        await ISOInspector.detach(mounted)
    case "dd":
        // Privileged helper used by the app's DD mode. Writes <image> raw to /dev/r<diskN>.
        guard args.count >= 3, args.contains("--yes") else { usage() }
        func opt(_ name: String) -> String? {
            if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
            return nil
        }
        let progressFile = opt("--progress-file"), cancelFile = opt("--cancel-file")
        func status(_ s: String) { if let f = progressFile { try? s.write(toFile: f, atomically: true, encoding: .utf8) } }
        do {
            let image = URL(fileURLWithPath: args[1])
            let info = try RawImage.inspect(image)
            var device: String
            if let test = ProcessInfo.processInfo.environment["JUPITERFLASH_TEST_TARGET"] {
                device = test   // test hook: write to a regular file instead of a disk
            } else {
                guard geteuid() == 0 else { throw FlashError.message("The write helper must run as root.") }
                try await DiskService.verifyRawTarget(id: args[2], imageSize: info.size)
                try await DiskService.unmountDisk(id: args[2])
                device = "/dev/r\(args[2])"
            }
            try RawWriter.write(image: image, device: device, verify: args.contains("--verify"),
                onProgress: { phase, done, total in
                    status("\(phase) \(done) \(total)")
                    if progressFile == nil { print("[\(phase)] \(done)/\(total)") }
                },
                isCancelled: { cancelFile.map { FileManager.default.fileExists(atPath: $0) } ?? false })
        } catch {
            let msg = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            status("error \(msg)")
            FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
            exit(1)
        }
    case "sha256", "sha1", "md5", "hash":
        // hash <file> [expected]   (algorithm picked from the expected value's length, else SHA-256)
        // sha256|sha1|md5 <file> [expected]
        guard args.count >= 2 else { usage() }
        var algorithm: HashAlgorithm = HashAlgorithm(rawValue: args[0]) ?? .sha256
        let expected = args.count >= 3 ? Checksum.parse(args[2]) : nil
        if args.count >= 3 {
            guard let e = expected else { print("Expected value isn't a single MD5, SHA-1 or SHA-256 hash."); exit(2) }
            if args[0] == "hash" { algorithm = e.algorithm }
            else if e.algorithm != algorithm { print("Expected value is \(e.algorithm.displayName), not \(algorithm.displayName)."); exit(2) }
        }
        var lastP = -1
        let sum = try Checksum.compute(algorithm, of: URL(fileURLWithPath: args[1]), progress: { f in
            let p = Int(f * 100); if p != lastP, args.count < 3 { lastP = p; FileHandle.standardError.write(Data("\r\(p)%".utf8)) }
        })
        print(sum)
        if let want = expected {
            print(want.hash == sum ? "MATCH (\(algorithm.displayName))" : "MISMATCH (expected \(want.hash))")
            exit(want.hash == sum ? 0 : 1)
        }
    case "driverinfo":
        guard args.count >= 2 else { usage() }
        let pack = try NT5DriverPack.load(URL(fileURLWithPath: args[1]))
        print("controllers: \(pack.descriptions.joined(separator: " | "))")
        print("files: \(pack.files.joined(separator: ", "))")
        print(pack.winntSifSections, terminator: "")
    case "badblocks", "clone":
        // Privileged helpers for "Test drive" and "Clone drive". Never trust the caller: the disk is re-checked here.
        guard args.count >= 2, args.contains("--yes") else { usage() }
        func optC(_ name: String) -> String? {
            if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
            return nil
        }
        let progressPath = optC("--progress-file"), cancelPath = optC("--cancel-file")
        func statusC(_ s: String) { if let f = progressPath { try? s.write(toFile: f, atomically: true, encoding: .utf8) } }
        do {
            var device: String
            var size: Int64
            if let test = ProcessInfo.processInfo.environment["JUPITERFLASH_TEST_TARGET"] {
                device = test      // test hook: a regular file stands in for the disk
                size = Int64(optC("--size") ?? "") ?? ((try? FileManager.default.attributesOfItem(atPath: test)[.size] as? Int64) ?? 0) ?? 0
            } else {
                guard geteuid() == 0 else { throw FlashError.message("The helper must run as root.") }
                try await DiskService.verifyRawTarget(id: args[1], imageSize: 0)
                size = try await DiskService.rawSize(id: args[1])
                try await DiskService.unmountDisk(id: args[1])
                device = "/dev/r\(args[1])"
            }
            let progress: (String, Int64, Int64) -> Void = { phase, done, total in
                statusC("\(phase) \(done) \(total)")
                if progressPath == nil { print("[\(phase)] \(done)/\(total)") }
            }
            let cancelled: () -> Bool = { cancelPath.map { FileManager.default.fileExists(atPath: $0) } ?? false }
            if cmd == "badblocks" {
                let r = try DriveTester.run(device: device, size: size, quick: args.contains("--quick"), onProgress: progress, isCancelled: cancelled)
                print("RESULT bad=\(r.badBlocks) total=\(r.totalBlocks) first=\(r.firstBadOffset.map(String.init) ?? "-") write=\(Int(r.writeMBps)) read=\(Int(r.readMBps)) quick=\(r.quick ? 1 : 0)")
            } else {
                guard args.count >= 3 else { usage() }
                try DriveCloner.clone(device: device, size: size, output: URL(fileURLWithPath: args[2]),
                                      ownerUID: optC("--uid").flatMap { UInt32($0) }, onProgress: progress, isCancelled: cancelled)
                print("RESULT cloned=\(size)")
            }
        } catch {
            let msg = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            statusC("error \(msg)")
            FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
            exit(1)
        }
    case "unattend":
        // Prints the answer file for the given options (for inspection / testing).
        var c = WindowsCustomization()
        c.bypassHardwareChecks = args.contains("--bypass-hw")
        c.skipOnlineAccount = args.contains("--skip-account")
        c.skipPrivacyQuestions = args.contains("--privacy")
        c.disableBitLocker = args.contains("--no-bitlocker")
        c.useMacRegion = args.contains("--mac-region")
        if let i = args.firstIndex(of: "--local-user"), i + 1 < args.count { c.localAccountName = args[i + 1] }
        print(c.unattendXML(architecture: "amd64"), terminator: "")
    case "bios":
        // Privileged helper: installs BIOS boot code (MBR code, active flag, FAT32 boot record).
        guard args.count >= 2, args.contains("--yes") else { usage() }
        func optB(_ name: String) -> String? {
            if let i = args.firstIndex(of: name), i + 1 < args.count { return args[i + 1] }
            return nil
        }
        let statusPath = optB("--progress-file")
        func statusB(_ s: String) { if let f = statusPath { try? s.write(toFile: f, atomically: true, encoding: .utf8) } }
        do {
            guard let m = optB("--mbr"), let p = optB("--pbr"),
                  let mbr = FileManager.default.contents(atPath: m), let pbr = FileManager.default.contents(atPath: p),
                  mbr.count == 440, pbr.count == 1536 || pbr.count == 512 else { throw FlashError.message("Missing or invalid boot code files.") }
            var device: String
            if let test = ProcessInfo.processInfo.environment["JUPITERFLASH_TEST_TARGET"] {
                device = test
            } else {
                guard geteuid() == 0 else { throw FlashError.message("The write helper must run as root.") }
                try await DiskService.verifyRawTarget(id: args[1], imageSize: 0)
                try await DiskService.unmountDisk(id: args[1])
                device = "/dev/r\(args[1])"
            }
            try BiosBootWriter.write(device: device, blobs: BiosBootBlobs(mbrCode: mbr, pbr: pbr))
        } catch {
            let msg = error.localizedDescription.replacingOccurrences(of: "\n", with: " ")
            statusB("error \(msg)")
            FileHandle.standardError.write(Data("ERROR: \(msg)\n".utf8))
            exit(1)
        }
    case "write-loader":
        // Test/scripting helper: writes Jupiter Flasher's own boot loader into an (unmounted) disk-image FILE. No root needed.
        guard args.count >= 3 else { usage() }
        guard FileManager.default.fileExists(atPath: args[1]), !args[1].hasPrefix("/dev/") else {
            print("write-loader only works on a regular image file"); exit(2)
        }
        try BiosBootWriter.write(device: args[1], blobs: BiosBootBlobs.jupiter(bootFile: args[2]))
        print("loader for \(args[2]) written to \(args[1])")
    case "flash":
        guard args.count >= 3 else { usage() }
        guard args.contains("--yes") else { print("Refusing to erase a drive without --yes."); exit(2) }
        let iso = URL(fileURLWithPath: args[1])
        let disks = try await DiskService.listDisks(includeFixed: true)
        guard let disk = disks.first(where: { $0.id == args[2] }) else {
            print("\(args[2]) is not an eligible external disk. Run `jupiterflash-cli list --all`."); exit(1)
        }
        var label = "WINDOWS"
        if let i = args.firstIndex(of: "--label"), i + 1 < args.count { label = args[i + 1] }
        var cust = WindowsCustomization()
        cust.bypassHardwareChecks = args.contains("--bypass-hw")
        cust.skipOnlineAccount = args.contains("--skip-account")
        cust.skipPrivacyQuestions = args.contains("--privacy")
        cust.disableBitLocker = args.contains("--no-bitlocker")
        cust.useMacRegion = args.contains("--mac-region")
        if let i = args.firstIndex(of: "--local-user"), i + 1 < args.count { cust.localAccountName = args[i + 1] }
        let opts = FlashOptions(iso: iso, disk: disk, label: label,
                                scheme: args.contains("--gpt") ? .gpt : .mbr,
                                ejectWhenDone: !args.contains("--no-eject"),
                                verify: !args.contains("--no-verify"),
                                biosBoot: args.contains("--bios"),
                                customization: cust.isEmpty ? nil : cust,
                                helper: URL(fileURLWithPath: CommandLine.arguments[0]),
                                disableACPI: args.contains("--no-acpi"),
                                nt5Drivers: args.firstIndex(of: "--nt5-drivers").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil })
        var lastPct = -1
        try await Flasher.flash(opts, progress: { f, msg in
            let pct = Int(f * 100)
            if pct != lastPct { lastPct = pct; print(String(format: "[%3d%%] %@", pct, msg)) }
        }, log: { print("  \($0)") })
    default: usage()
    }
}

do { try await run() } catch { print("Error: \(error.localizedDescription)"); exit(1) }
