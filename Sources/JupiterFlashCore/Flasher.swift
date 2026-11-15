// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public enum FlashError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case .message(let m) = self { return m } else { return nil } }
}

public enum PartitionScheme: String, CaseIterable, Identifiable, Sendable {
    case mbr = "MBR", gpt = "GPT"
    public var id: String { rawValue }
    var diskutilName: String { self == .mbr ? "MBRFormat" : "GPTFormat" }
}

public struct FlashOptions: Sendable {
    public var iso: URL
    public var disk: Disk
    public var label: String
    public var scheme: PartitionScheme
    public var ejectWhenDone: Bool
    public var verify: Bool
    public var biosBoot: Bool                          // also make the drive bootable on legacy BIOS / CSM
    public var customization: WindowsCustomization?    // written as autounattend.xml
    public var helper: URL?                            // privileged helper, needed for biosBoot
    public var disableACPI: Bool                       // XP/2000/2003: force the generic non-ACPI HAL (same as pressing F7)
    public var nt5Drivers: URL?                        // XP/2000/2003: folder with a text-mode (F6) storage driver incl. txtsetup.oem
    public init(iso: URL, disk: Disk, label: String, scheme: PartitionScheme = .mbr,
                ejectWhenDone: Bool = true, verify: Bool = true,
                biosBoot: Bool = false, customization: WindowsCustomization? = nil, helper: URL? = nil,
                disableACPI: Bool = false, nt5Drivers: URL? = nil) {
        self.iso = iso; self.disk = disk; self.label = label; self.scheme = scheme
        self.ejectWhenDone = ejectWhenDone; self.verify = verify
        self.biosBoot = biosBoot; self.customization = customization; self.helper = helper
        self.disableACPI = disableACPI; self.nt5Drivers = nt5Drivers
    }
}

public typealias ProgressHandler = @Sendable (_ fraction: Double, _ message: String) -> Void
public typealias LogHandler = @Sendable (String) -> Void

public enum Flasher {
    /// FAT32 volume labels: upper-case, max 11 chars, no reserved characters.
    public static func sanitizeLabel(_ s: String) -> String {
        let bad = CharacterSet(charactersIn: "*?.,;:/\\|+=<>[]\"")
        let cleaned = s.uppercased().unicodeScalars.filter { !bad.contains($0) && $0.isASCII && $0.value >= 32 }
        let str = String(String.UnicodeScalarView(cleaned)).trimmingCharacters(in: .whitespaces)
        let cut = String(str.prefix(11))
        return cut.isEmpty ? "WINDOWS" : cut
    }

    public static func flash(_ o: FlashOptions, progress: @escaping ProgressHandler, log: @escaping LogHandler) async throws {
        let label = sanitizeLabel(o.label)
        var isoMount: ISOInspector.Mounted?
        func cleanup() async { if let m = isoMount { await ISOInspector.detach(m); isoMount = nil } }

        do {
            // 1. Mount ISO & validate -------------------------------------------------
            progress(0.01, "Mounting ISO…")
            log("Mounting \(o.iso.lastPathComponent)")
            let mounted = try await ISOInspector.mount(o.iso)
            isoMount = mounted
            let mp = mounted.url
            if !mounted.weAttached { log("ISO was already mounted – reusing \(mp.path)") }
            let info = await ISOInspector.inspect(mountPoint: mp)
            guard info.isWindowsInstaller else {
                throw FlashError.message("This doesn't look like a Windows installation ISO (no sources/install.wim and boot files found).")
            }
            if !info.hasUEFIBoot && !info.needsUEFIFiles {
                log("Warning: no efi/boot/bootx64.efi found – the drive may not boot in UEFI mode.")
            }

            var biosBlobs: BiosBootBlobs?
            if info.isNT5 {
                // Windows 2000 / XP / 2003: NTLDR-based, legacy BIOS only. Needs MBR and our own boot loader.
                guard o.scheme == .mbr else { throw FlashError.message("\(info.windowsName ?? "This Windows") needs the MBR partition scheme (it can't boot in UEFI mode).") }
                biosBlobs = BiosBootBlobs.jupiter(bootFile: "NTLDR")
                log("\(info.windowsName ?? "Windows 2000/XP/2003") media: legacy BIOS boot with Jupiter Flasher's own NTLDR loader.")
            } else if o.biosBoot {
                guard o.scheme == .mbr else { throw FlashError.message("Legacy BIOS boot needs the MBR partition scheme.") }
                guard info.supportsBIOSBoot else {
                    throw FlashError.message("This ISO can't boot in legacy BIOS mode (it has no bootmgr / boot/bootsect.exe – ARM64 media, for example).")
                }
                biosBlobs = try BiosBootCode.extract(from: mp)
                log("Found the Windows BIOS boot code in boot/bootsect.exe")
            }

            var wimSource: URL?
            if info.needsSplit {
                guard info.installImageName?.lowercased() == "install.wim" else {
                    throw FlashError.message("\(info.installImageName ?? "The install image") is larger than 4 GB and can't be split. Use a Windows ISO that contains install.wim.")
                }
                guard Wimlib.executable != nil else {
                    throw FlashError.message("This ISO contains an install.wim larger than 4 GB, which has to be split to fit on a FAT32 drive. Install wimlib first:\n\nbrew install wimlib")
                }
                wimSource = ISOInspector.find(mp, ["sources", "install.wim"])
                log("install.wim is \(ByteFormat.string(info.installImageSize)) – it will be split into \(Limits.splitPartMiB) MiB parts.")
            }

            // 2. Size everything up -----------------------------------------------------
            let (files, dirs) = try enumerate(mp)
            let prefix = mp.standardizedFileURL.path
            let wimRel = wimSource.map { String($0.standardizedFileURL.path.dropFirst(prefix.count + 1)) }
            let copyFiles = files.filter { $0.rel != wimRel }
            let copyBytes = copyFiles.reduce(Int64(0)) { $0 + $1.size }
            let splitBytes = wimSource == nil ? 0 : info.installImageSize
            // Windows 2000/XP/2003: setup's loader reads its boot files from $WIN_NT$.~BT, so \I386 is copied twice.
            let nt5Prefix = info.isNT5 ? info.nt5Dir.lowercased() + "/" : nil
            let nt5Files = files.filter { f in nt5Prefix.map { f.rel.lowercased().hasPrefix($0) } ?? false }
            let nt5Bytes = nt5Files.reduce(Int64(0)) { $0 + $1.size }
            let totalBytes = max(copyBytes + splitBytes + nt5Bytes, 1)

            let needed = copyBytes + splitBytes + nt5Bytes + 64 * 1_048_576 + (o.scheme == .gpt ? 210 * 1_048_576 : 0)
            if o.disk.size < needed {
                throw FlashError.message("The drive (\(ByteFormat.string(o.disk.size))) is too small. This ISO needs about \(ByteFormat.string(needed)).")
            }

            // 3. Format -----------------------------------------------------------------
            try Task.checkCancellation()
            try await DiskService.verifySafeTarget(o.disk)
            progress(0.03, "Formatting \(o.disk.id) as FAT32 (\(o.scheme.rawValue))…")
            log("diskutil eraseDisk FAT32 \(label) \(o.scheme.diskutilName) \(o.disk.device)")
            _ = try await Shell.run("/usr/sbin/diskutil",
                ["eraseDisk", "FAT32", label, o.scheme.diskutilName, o.disk.device],
                onLine: { log($0) })
            if let blobs = biosBlobs {
                try Task.checkCancellation()
                progress(0.045, "Making the drive BIOS-bootable (administrator permission needed)…")
                try await BiosBootRunner.apply(disk: o.disk, blobs: blobs, helper: o.helper, log: log)
                _ = try await Shell.run("/usr/sbin/diskutil", ["mountDisk", o.disk.device], onLine: { log($0) })
            }
            let target = try await DiskService.mountPoint(of: label, on: o.disk)
            log("Target volume mounted at \(target.path)")

            // 4. Copy -------------------------------------------------------------------
            let start = 0.06, span = o.verify ? 0.50 : 0.91
            var done: Int64 = 0
            var lastReport = Date.distantPast
            func report(_ extra: Int64 = 0, _ msg: String) {
                let f = start + span * Double(done + extra) / Double(totalBytes)
                progress(min(f, start + span), msg)
            }

            for d in dirs {
                try FileManager.default.createDirectory(at: target.appendingPathComponent(d), withIntermediateDirectories: true)
            }
            for (i, f) in copyFiles.enumerated() {
                try Task.checkCancellation()
                let dst = target.appendingPathComponent(f.rel)
                try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                let base = done
                try copyFile(from: f.src, to: dst) { n in
                    done += Int64(n)
                    if Date().timeIntervalSince(lastReport) > 0.1 {
                        lastReport = Date()
                        report(0, "Copying \(f.src.lastPathComponent) (\(i + 1)/\(copyFiles.count))")
                    }
                }
                done = base + f.size
                await Task.yield()
            }
            log("Copied \(copyFiles.count) files (\(ByteFormat.string(copyBytes)))")

            // 5. Split install.wim -----------------------------------------------------
            if let wimSource, let wimlib = Wimlib.executable {
                try Task.checkCancellation()
                let srcDir = target.appendingPathComponent("sources")
                try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
                let dest = srcDir.appendingPathComponent("install.swm")
                log("Splitting install.wim → install.swm")
                let poller = Task {
                    while !Task.isCancelled {
                        let written = ((try? FileManager.default.contentsOfDirectory(atPath: srcDir.path)) ?? [])
                            .filter { $0.lowercased().hasPrefix("install") && $0.lowercased().hasSuffix(".swm") }
                            .reduce(Int64(0)) { $0 + ISOInspector.fileSize(srcDir.appendingPathComponent($1)) }
                        report(min(written, splitBytes), "Splitting install.wim (\(ByteFormat.string(written)) of \(ByteFormat.string(splitBytes)))")
                        try? await Task.sleep(nanoseconds: 300_000_000)
                    }
                }
                defer { poller.cancel() }
                _ = try await Shell.run(wimlib, ["split", wimSource.path, dest.path, String(Limits.splitPartMiB)],
                                        onLine: { log($0) })
                done += splitBytes
            }

            // 5-nt5. Windows 2000 / XP / 2003 ---------------------------------------------
            // Layout (found by booting it in QEMU against a real XP SP3 ISO):
            //  \NTLDR            = I386\SETUPLDR.BIN, loaded by Jupiter Flasher's own FAT32 boot sector
            //  \NTDETECT.COM, \TXTSETUP.SIF
            //  \$WIN_NT$.~BT\   = copy of I386 (setupldr reads its boot files from here when started from a hard disk)
            //  \$WIN_NT$.~BT\winnt.sif points text-mode setup at this drive as the install source (the CD copy in \I386)
            if info.isNT5, let prefix = nt5Prefix {
                for (src, dst) in [("setupldr.bin", "NTLDR"), ("ntdetect.com", "NTDETECT.COM"), ("txtsetup.sif", "TXTSETUP.SIF")] {
                    guard let from = ISOInspector.find(mp, [info.nt5Dir, src]) else {
                        throw FlashError.message("\(info.nt5Dir)\\\(src.uppercased()) is missing from the ISO.")
                    }
                    let to = target.appendingPathComponent(dst)
                    try? FileManager.default.removeItem(at: to)
                    try FileManager.default.copyItem(at: from, to: to)
                }
                let bt = target.appendingPathComponent("$WIN_NT$.~BT")
                try FileManager.default.createDirectory(at: bt, withIntermediateDirectories: true)
                for f in nt5Files {
                    try Task.checkCancellation()
                    let dst = bt.appendingPathComponent(String(f.rel.dropFirst(prefix.count)))
                    try FileManager.default.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
                    let base = done
                    try copyFile(from: f.src, to: dst) { n in
                        done += Int64(n)
                        if Date().timeIntervalSince(lastReport) > 0.1 {
                            lastReport = Date()
                            report(0, "Copying setup boot files: \(f.src.lastPathComponent)")
                        }
                    }
                    done = base + f.size
                    await Task.yield()
                }
                if o.disableACPI {
                    // setupldr reads ACPIEnable from TXTSETUP.SIF: 2 = detect, 0 = never use ACPI (what F7 does at the prompt).
                    // Only the boot copies are patched; \I386 stays identical to the CD.
                    for url in [target.appendingPathComponent("TXTSETUP.SIF"), bt.appendingPathComponent("txtsetup.sif")] {
                        guard let data = try? Data(contentsOf: url) else { continue }
                        var text = String(decoding: data, as: UTF8.self)
                        if String(data: data, encoding: .isoLatin1) != nil { text = String(data: data, encoding: .isoLatin1)! }
                        guard let re = try? NSRegularExpression(pattern: "(?im)^(ACPIEnable\\s*=\\s*)\\d+"),
                              re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil else {
                            throw FlashError.message("Couldn't find the ACPIEnable setting in TXTSETUP.SIF to disable ACPI.")
                        }
                        text = re.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$10")
                        try text.data(using: .isoLatin1)!.write(to: url)
                    }
                    log("ACPI disabled in the setup boot files (generic \"Standard PC\" HAL will be installed).")
                }
                var sif = "[SetupData]\r\nSetupSourceDevice = \"\\ArcName\\multi(0)disk(0)rdisk(0)partition(1)\"\r\nSetupSourcePath = \"\\\"\r\n"
                if let drv = o.nt5Drivers {
                    let pack = try NT5DriverPack.load(drv)
                    let textmode = target.appendingPathComponent("$OEM$/TEXTMODE")
                    try FileManager.default.createDirectory(at: textmode, withIntermediateDirectories: true)
                    for f in pack.files {
                        let dst = textmode.appendingPathComponent(f)
                        try? FileManager.default.removeItem(at: dst)
                        try FileManager.default.copyItem(at: pack.folder.appendingPathComponent(f), to: dst)
                    }
                    sif += "\r\n" + pack.winntSifSections
                    log("Added text-mode storage driver(s) from \(drv.lastPathComponent): \(pack.descriptions.joined(separator: "; ")) (\(pack.files.count) files in $OEM$\\TEXTMODE).")
                }
                try sif.write(to: bt.appendingPathComponent("winnt.sif"), atomically: false, encoding: .ascii)
                log("Windows setup layout written: NTLDR, NTDETECT.COM, TXTSETUP.SIF, $WIN_NT$.~BT (\(nt5Files.count) files) and winnt.sif.")
            }

            // 5a. UEFI boot files for Windows Vista/7 media --------------------------------
            if info.needsUEFIFiles {
                if let wimlib = Wimlib.executable, let wimURL = ISOInspector.find(mp, ["sources", "install.wim"]) {
                    do {
                        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("jupiterflash-efi-\(UUID().uuidString)")
                        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                        defer { try? FileManager.default.removeItem(at: tmp) }
                        progress(0.96 - (o.verify ? 0.46 : 0), "Adding UEFI boot files from install.wim…")
                        _ = try await Shell.run(wimlib, ["extract", wimURL.path, "1", "/Windows/Boot/EFI/bootmgfw.efi",
                                                         "--dest-dir=\(tmp.path)", "--no-acls"])
                        let efi = tmp.appendingPathComponent("bootmgfw.efi")
                        guard FileManager.default.fileExists(atPath: efi.path) else { throw FlashError.message("bootmgfw.efi wasn't found in install.wim") }
                        let bootDir = target.appendingPathComponent("efi/boot")
                        let msDir = target.appendingPathComponent("efi/microsoft/boot")
                        try FileManager.default.createDirectory(at: bootDir, withIntermediateDirectories: true)
                        try FileManager.default.createDirectory(at: msDir, withIntermediateDirectories: true)
                        try FileManager.default.copyItem(at: efi, to: bootDir.appendingPathComponent("bootx64.efi"))
                        if let bcd = ISOInspector.find(mp, ["boot", "bcd"]) {
                            try FileManager.default.copyItem(at: bcd, to: msDir.appendingPathComponent("bcd"))
                        }
                        log("Added efi/boot/bootx64.efi (from install.wim) and efi/microsoft/boot/bcd so \(info.windowsName ?? "this Windows") can boot in UEFI mode.")
                    } catch {
                        log("Warning: couldn't add UEFI boot files (\(error.localizedDescription)). The drive will boot in legacy BIOS mode only.")
                    }
                } else {
                    log("Note: \(info.windowsName ?? "this Windows") has no UEFI boot files; install wimlib (brew install wimlib) to add them. Legacy BIOS boot only.")
                }
            }

            // 5b. Windows customizations ------------------------------------------------
            if let c = o.customization, !c.isEmpty {
                let xml = c.unattendXML(architecture: info.architecture)
                try xml.write(to: target.appendingPathComponent("autounattend.xml"), atomically: false, encoding: .utf8)
                log("Wrote autounattend.xml (\(info.architecture)) with the selected Windows customizations")
            }

            // 6. Verify -----------------------------------------------------------------
            if o.verify {
                try Task.checkCancellation()
                let vStart = start + span, vSpan = 0.97 - vStart
                progress(vStart, "Re-reading the drive to verify…")
                _ = try? await Shell.run("/bin/sync", [])
                let check = try await DiskService.remount(label: label, on: o.disk)
                log("Verifying against the ISO (drive re-mounted at \(check.path))")
                try await verifyVolume(isoMount: mp, volume: check,
                                       progress: { f, msg in progress(vStart + vSpan * f, msg) }, log: log)
            }

            // 7. Flush & eject ----------------------------------------------------------
            try Task.checkCancellation()
            progress(0.98, "Flushing writes to the drive…")
            _ = try? await Shell.run("/bin/sync", [])
            await cleanup()
            if o.ejectWhenDone {
                progress(0.99, "Ejecting…")
                _ = try await Shell.run("/usr/sbin/diskutil", ["eject", o.disk.device], onLine: { log($0) })
            }
            progress(1.0, "Done")
            log("Finished.")
        } catch {
            await cleanup()
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    // MARK: Verification

    /// Compares a flashed volume with the mounted ISO: every file byte-for-byte, and the split
    /// install.swm parts via wimlib's SHA-1 check. `progress` receives 0...1.
    public static func verifyVolume(isoMount mp: URL, volume: URL,
                                    progress: @escaping ProgressHandler, log: @escaping LogHandler) async throws {
        let (files, _) = try enumerate(mp)
        let srcDir = ISOInspector.find(volume, ["sources"])
        let swmFirst = ISOInspector.find(volume, ["sources", "install.swm"])
        let volumeHasWim = ISOInspector.find(volume, ["sources", "install.wim"]) != nil
        let skipWim = swmFirst != nil && !volumeHasWim
        let toCompare = files.filter { !(skipWim && $0.rel.lowercased() == "sources/install.wim") }

        var swmBytes: Int64 = 0
        if skipWim, let srcDir {
            swmBytes = ((try? FileManager.default.contentsOfDirectory(atPath: srcDir.path)) ?? [])
                .filter { $0.lowercased().hasPrefix("install") && $0.lowercased().hasSuffix(".swm") }
                .reduce(Int64(0)) { $0 + ISOInspector.fileSize(srcDir.appendingPathComponent($1)) }
        }
        let total = Double(max(toCompare.reduce(Int64(0)) { $0 + $1.size } + swmBytes, 1))
        var verified: Int64 = 0
        var last = Date.distantPast

        for (i, f) in toCompare.enumerated() {
            try Task.checkCancellation()
            // Direct path first (FAT volumes are case-insensitive); the directory-listing search is O(n) per file,
            // which made folders with thousands of files (XP's I386) quadratic.
            let direct = volume.appendingPathComponent(f.rel)
            guard let dst = FileManager.default.fileExists(atPath: direct.path)
                    ? direct
                    : ISOInspector.find(volume, f.rel.split(separator: "/").map(String.init)) else {
                throw FlashError.message("Verification failed: \(f.rel) is missing from the drive.")
            }
            let base = verified
            try compareFiles(f.src, dst) { n in
                verified += Int64(n)
                if Date().timeIntervalSince(last) > 0.1 {
                    last = Date()
                    progress(min(Double(verified) / total, 1), "Verifying \(f.src.lastPathComponent) (\(i + 1)/\(toCompare.count))")
                }
            }
            verified = base + f.size
            await Task.yield()
        }
        log("Verified \(toCompare.count) files match the ISO.")

        if skipWim, let swmFirst, let srcDir {
            guard let wimlib = Wimlib.executable else {
                log("wimlib not found – skipped checking the split install.swm.")
                return
            }
            log("Verifying split install image (install.swm)…")
            let base = Double(verified)
            let part = Double(swmBytes)
            do {
                _ = try await Shell.run(wimlib, ["verify", swmFirst.path, "--ref=\(srcDir.path)/install*.swm"],
                                        onLine: { line in
                    if let pct = percent(in: line) {
                        progress(min((base + part * pct) / total, 1), "Verifying install image (\(Int(pct * 100))%)")
                    }
                })
            } catch {
                throw FlashError.message("Verification failed: the split Windows image on the drive is damaged. The drive may be faulty – try another USB port or stick.\n\(error.localizedDescription)")
            }
            log("install.swm verified.")
        }
        progress(1, "Verified")
        log("Verification passed.")
    }

    /// "… (42%) done" → 0.42
    static func percent(in line: String) -> Double? {
        guard let close = line.range(of: "%)"),
              let open = line[..<close.lowerBound].lastIndex(of: "(") else { return nil }
        return Double(line[line.index(after: open)..<close.lowerBound]).map { $0 / 100 }
    }

    static func compareFiles(_ a: URL, _ b: URL, chunk: Int = 4 << 20, onBytes: (Int) -> Void) throws {
        let fa = open(a.path, O_RDONLY)
        guard fa >= 0 else { throw posixError("open \(a.lastPathComponent)") }
        defer { close(fa) }
        let fb = open(b.path, O_RDONLY)
        guard fb >= 0 else { throw FlashError.message("Verification failed: \(b.lastPathComponent) can't be read from the drive.") }
        defer { close(fb) }
        _ = fcntl(fa, F_NOCACHE, 1)
        _ = fcntl(fb, F_NOCACHE, 1)
        var bufA = [UInt8](repeating: 0, count: chunk)
        var bufB = [UInt8](repeating: 0, count: chunk)
        var offset: Int64 = 0
        while true {
            try Task.checkCancellation()
            let na = readFully(fa, &bufA, chunk)
            let nb = readFully(fb, &bufB, chunk)
            if na < 0 || nb < 0 { throw posixError("read \(b.lastPathComponent) while verifying") }
            if na != nb || memcmp(bufA, bufB, na) != 0 {
                throw FlashError.message("Verification failed: \(b.lastPathComponent) on the drive differs from the ISO (in the 4 MB block starting at byte \(offset)). The drive may be faulty – try another USB port or stick.")
            }
            if na == 0 { break }
            offset += Int64(na)
            onBytes(na)
        }
    }

    static func readFully(_ fd: Int32, _ buf: inout [UInt8], _ count: Int) -> Int {
        var total = 0
        while total < count {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress! + total, count - total) }
            if n < 0 { return -1 }
            if n == 0 { break }
            total += n
        }
        return total
    }

    /// Lists every file/dir in a mounted ISO (relative paths, symlinks and ._ files skipped).
    static func enumerate(_ mp: URL) throws -> (files: [(src: URL, rel: String, size: Int64)], dirs: [String]) {
        var files: [(src: URL, rel: String, size: Int64)] = []
        var dirs: [String] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .isSymbolicLinkKey]
        guard let en = FileManager.default.enumerator(at: mp, includingPropertiesForKeys: keys, options: []) else {
            throw FlashError.message("Couldn't read the ISO contents.")
        }
        let prefix = mp.standardizedFileURL.path
        for case let url as URL in en {
            let rel = String(url.standardizedFileURL.path.dropFirst(prefix.count + 1))
            let v = try url.resourceValues(forKeys: Set(keys))
            if v.isSymbolicLink == true { continue }
            if v.isDirectory == true { dirs.append(rel); continue }
            if url.lastPathComponent.hasPrefix("._") { continue }
            files.append((url, rel, Int64(v.fileSize ?? 0)))
        }
        return (files, dirs)
    }

    /// Plain POSIX copy – avoids Finder/`cp` metadata (._ files, xattrs) that FAT32 volumes don't need.
    static func copyFile(from: URL, to: URL, chunk: Int = 4 << 20, onBytes: (Int) -> Void) throws {
        let src = open(from.path, O_RDONLY)
        guard src >= 0 else { throw posixError("open \(from.lastPathComponent)") }
        defer { close(src) }
        let dst = open(to.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard dst >= 0 else { throw posixError("create \(to.lastPathComponent)") }
        defer { close(dst) }
        var buf = [UInt8](repeating: 0, count: chunk)
        while true {
            try Task.checkCancellation()
            let n = read(src, &buf, chunk)
            if n < 0 { throw posixError("read \(from.lastPathComponent)") }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { write(dst, $0.baseAddress! + off, n - off) }
                if w < 0 { throw posixError("write \(to.lastPathComponent)") }
                off += w
            }
            onBytes(n)
        }
    }

    static func posixError(_ what: String) -> FlashError {
        FlashError.message("Couldn't \(what): \(String(cString: strerror(errno)))")
    }
}
