// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct ISOInfo: Sendable {
    public var label: String
    public var hasBootmgr: Bool
    public var hasUEFIBoot: Bool
    public var installImageName: String?   // e.g. "install.wim"
    public var installImageSize: Int64
    public var editions: [String]          // from wimlib, when available
    public var architecture = "amd64"      // "amd64", "x86" or "arm64" – used for the answer file
    public var hasBootsect = false         // boot/bootsect.exe, the source of the BIOS boot code
    public var versionMajor = 0            // from the install image (via wimlib); 0 = unknown
    public var versionMinor = 0
    public var versionBuild = 0
    public var isServer = false
    /// Windows 2000 / XP / Server 2003 media: no install.wim, setup runs from \I386 (or \AMD64) via setupldr.bin.
    public var isNT5 = false
    public var nt5Dir = "I386"             // folder that holds txtsetup.sif / setupldr.bin as spelled on the ISO

    /// Human-readable Windows generation, e.g. "Windows 7", or nil when unknown.
    public var windowsName: String? {
        switch (versionMajor, versionMinor) {
        case (0, _): return nil
        case (5, 0): return "Windows 2000"
        case (5, 1): return "Windows XP"
        case (5, 2): return isServer ? "Windows Server 2003" : "Windows XP x64"
        case (6, 0): return isServer ? "Windows Server 2008" : "Windows Vista"
        case (6, 1): return isServer ? "Windows Server 2008 R2" : "Windows 7"
        case (6, 2): return isServer ? "Windows Server 2012" : "Windows 8"
        case (6, 3): return isServer ? "Windows Server 2012 R2" : "Windows 8.1"
        case (10, 0): return isServer ? "Windows Server (build \(versionBuild))" : (versionBuild >= 22000 ? "Windows 11" : "Windows 10")
        default: return "Windows \(versionMajor).\(versionMinor)"
        }
    }

    /// Windows Vista / 7 media (NT 6.0–6.1) – boots with bootmgr but predates UEFI media.
    public var isVistaOr7: Bool { versionMajor == 6 && versionMinor <= 1 }
    /// Windows 8 / 8.1 media (NT 6.2–6.3).
    public var isWindows8: Bool { versionMajor == 6 && (versionMinor == 2 || versionMinor == 3) }

    // Which answer-file options mean something for this Windows. When the version couldn't be read
    // (wimlib missing) everything is allowed, as before.
    private var versionKnown: Bool { versionMajor > 0 }
    /// Windows 11's TPM / Secure Boot / RAM / CPU checks (Windows 10 and older have none, but the keys are harmless on 10).
    public var hasHardwareChecks: Bool { !versionKnown || versionMajor >= 10 }
    /// Microsoft-account sign-in page in OOBE: Windows 8 and later. Vista/7 have no such page.
    public var hasOnlineAccountScreens: Bool { !versionKnown || versionMajor >= 10 || (versionMajor == 6 && versionMinor >= 2) }
    /// Automatic device encryption: Windows 8.1 and later.
    public var hasDeviceEncryption: Bool { !versionKnown || versionMajor >= 10 || (versionMajor == 6 && versionMinor >= 3) }

    /// 64-bit Vista/7 ISOs ship no UEFI boot loader; it can be extracted from install.wim.
    public var needsUEFIFiles: Bool {
        !hasUEFIBoot && hasBootmgr && architecture == "amd64" && versionMajor == 6 && installImageName == "install.wim"
    }

    /// Legacy BIOS boot needs bootmgr (absent on ARM64 media) and the boot code from bootsect.exe.
    public var supportsBIOSBoot: Bool { hasBootmgr && hasBootsect }

    public var isWindowsInstaller: Bool { isNT5 || (installImageName != nil && (hasBootmgr || hasUEFIBoot)) }
    public var needsSplit: Bool { installImageSize > Limits.fat32MaxFile }

    /// True when the install image carries an LTSC/IoT edition (long-term-servicing / embedded media).
    public var isLTSCOrIoT: Bool { editions.contains { $0.localizedCaseInsensitiveContains("LTSC") || $0.localizedCaseInsensitiveContains("IoT") } }
    public var isIoT: Bool { editions.contains { $0.localizedCaseInsensitiveContains("IoT") } }

    public var summary: String {
        var parts: [String] = []
        if let n = windowsName { parts.append(versionBuild > 0 ? "\(n) (build \(versionBuild))" : n) }
        parts.append(label)
        if let n = installImageName { parts.append("\(n) \(ByteFormat.string(installImageSize))") }
        if let first = editions.first { parts.append(editions.count > 1 ? "\(first) +\(editions.count - 1) more" : first) }
        return parts.joined(separator: " · ")
    }
}

public enum Limits {
    /// Largest file FAT32 can hold (4 GiB - 1). Overridable for testing.
    public static var fat32MaxFile: Int64 {
        if let s = ProcessInfo.processInfo.environment["JUPITERFLASH_MAX_FILE_BYTES"], let v = Int64(s) { return v }
        return 4_294_967_295
    }
    /// Size of each split part in MiB. Overridable for testing.
    public static var splitPartMiB: Int {
        if let s = ProcessInfo.processInfo.environment["JUPITERFLASH_SPLIT_MIB"], let v = Int(s) { return v }
        return 3800
    }
}

public enum Wimlib {
    /// Locates wimlib-imagex: bundled copy first, then Homebrew, then PATH.
    public static var executable: String? {
        var candidates: [String] = []
        if let r = Bundle.main.resourcePath { candidates.append(r + "/wimlib-imagex") }
        candidates += ["/opt/homebrew/bin/wimlib-imagex", "/usr/local/bin/wimlib-imagex"]
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/wimlib-imagex")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

public enum ISOInspector {
    /// A mounted ISO. `weAttached` is false when the image was already mounted (e.g. by Finder);
    /// in that case we reuse the mount and leave it mounted afterwards.
    public struct Mounted: Sendable {
        public let url: URL
        public let weAttached: Bool
    }

    /// Finds the mount point of `iso` if it is already attached.
    static func existingMount(of iso: URL) async -> URL? {
        guard let data = try? await Shell.runData("/usr/bin/hdiutil", ["info", "-plist"]),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return nil }
        let want = iso.resolvingSymlinksInPath().path
        for image in images {
            guard let path = image["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == want else { continue }
            let entities = image["system-entities"] as? [[String: Any]] ?? []
            if let mp = entities.compactMap({ $0["mount-point"] as? String }).first { return URL(fileURLWithPath: mp) }
        }
        return nil
    }

    /// Mounts the ISO read-only (or reuses an existing mount) and returns its mount point.
    public static func mount(_ iso: URL) async throws -> Mounted {
        if let existing = await existingMount(of: iso) { return Mounted(url: existing, weAttached: false) }

        var lastError: Error?
        for attempt in 0..<4 {
            if attempt > 0 {
                try await Task.sleep(nanoseconds: 700_000_000)
                // Another process may have finished attaching it in the meantime.
                if let existing = await existingMount(of: iso) { return Mounted(url: existing, weAttached: false) }
            }
            do {
                let data = try await Shell.runData("/usr/bin/hdiutil",
                    ["attach", "-readonly", "-nobrowse", "-noverify", "-noautoopen", "-plist", iso.path],
                    mergeStderr: false)
                guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                      let entities = plist["system-entities"] as? [[String: Any]],
                      let mp = entities.compactMap({ $0["mount-point"] as? String }).first
                else { throw FlashError.message("Couldn't mount \(iso.lastPathComponent). Is it a valid ISO image?") }
                return Mounted(url: URL(fileURLWithPath: mp), weAttached: true)
            } catch let e as ShellError where e.output.contains("temporarily unavailable") {
                lastError = e   // transient (image busy) – retry
            }
        }
        throw lastError ?? FlashError.message("Couldn't mount \(iso.lastPathComponent).")
    }

    /// Unmounts only what we mounted ourselves.
    public static func detach(_ mounted: Mounted) async {
        guard mounted.weAttached else { return }
        _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mounted.url.path, "-force"])
    }

    /// Case-insensitive path lookup (UDF/ISO volumes may differ in case from what we expect).
    public static func find(_ root: URL, _ components: [String]) -> URL? {
        var cur = root
        for c in components {
            guard let items = try? FileManager.default.contentsOfDirectory(atPath: cur.path),
                  let match = items.first(where: { $0.caseInsensitiveCompare(c) == .orderedSame })
            else { return nil }
            cur = cur.appendingPathComponent(match)
        }
        return cur
    }

    public static func fileSize(_ url: URL) -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    /// Inspects an already-mounted ISO.
    public static func inspect(mountPoint: URL) async -> ISOInfo {
        let bootmgr = find(mountPoint, ["bootmgr"]) != nil
        let efi = find(mountPoint, ["efi", "boot", "bootx64.efi"]) != nil
            || find(mountPoint, ["efi", "boot", "bootaa64.efi"]) != nil
        var imageURL: URL?
        for name in ["install.wim", "install.esd", "install.swm"] {
            if let u = find(mountPoint, ["sources", name]) { imageURL = u; break }
        }
        var info = ISOInfo(
            label: mountPoint.lastPathComponent, hasBootmgr: bootmgr, hasUEFIBoot: efi,
            installImageName: imageURL?.lastPathComponent, installImageSize: imageURL.map(fileSize) ?? 0,
            editions: [])
        info.hasBootsect = find(mountPoint, ["boot", "bootsect.exe"]) != nil
        // Windows 2000 / XP / 2003: \I386 (or \AMD64) with setupldr.bin + txtsetup.sif
        if imageURL == nil {
            for dir in ["i386", "amd64"] {
                guard let sif = find(mountPoint, [dir, "txtsetup.sif"]),
                      find(mountPoint, [dir, "setupldr.bin"]) != nil,
                      find(mountPoint, [dir, "ntdetect.com"]) != nil else { continue }
                info.isNT5 = true
                info.nt5Dir = sif.deletingLastPathComponent().lastPathComponent
                info.architecture = dir == "amd64" ? "amd64" : "x86"
                if let data = try? Data(contentsOf: sif), let text = String(data: data, encoding: .isoLatin1) {
                    var inSetup = false
                    for raw in text.split(whereSeparator: \.isNewline) {
                        let line = raw.trimmingCharacters(in: .whitespaces)
                        if line.hasPrefix("[") { inSetup = line.lowercased() == "[setupdata]"; continue }
                        guard inSetup, let eq = line.firstIndex(of: "=") else { continue }
                        let key = line[..<eq].trimmingCharacters(in: .whitespaces).lowercased()
                        let val = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                        switch key {
                        case "majorversion": info.versionMajor = Int(val) ?? 0
                        case "minorversion": info.versionMinor = Int(val) ?? 0
                        case "producttype": info.isServer = (Int(val) ?? 0) != 0
                        default: break
                        }
                    }
                }
                break
            }
        }
        if find(mountPoint, ["efi", "boot", "bootaa64.efi"]) != nil { info.architecture = "arm64" }
        else if find(mountPoint, ["efi", "boot", "bootx64.efi"]) != nil { info.architecture = "amd64" }
        else if find(mountPoint, ["efi", "boot", "bootia32.efi"]) != nil { info.architecture = "x86" }
        if let imageURL, let wim = Wimlib.executable,
           let text = try? await Shell.run(wim, ["info", imageURL.path]) {
            var seen: [String] = []
            var gotVersion = false
            for line in text.split(whereSeparator: \.isNewline) {
                func value(_ key: String) -> String? {
                    line.hasPrefix(key) ? line.dropFirst(key.count).trimmingCharacters(in: .whitespaces) : nil
                }
                if let n = value("Name:"), !n.isEmpty, !seen.contains(n) { seen.append(n) }
                // Version/architecture are taken from the first image only.
                if !gotVersion {
                    if let v = value("Major Version:"), let i = Int(v) { info.versionMajor = i }
                    if let v = value("Minor Version:"), let i = Int(v) { info.versionMinor = i }
                    if let v = value("Build:"), let i = Int(v) { info.versionBuild = i; gotVersion = true }
                    if let v = value("Installation Type:") { info.isServer = v.lowercased().contains("server") }
                    if let v = value("Architecture:") {
                        switch v.lowercased() {
                        case "x86_64", "amd64": info.architecture = "amd64"
                        case "x86": info.architecture = "x86"
                        case "arm64": info.architecture = "arm64"
                        default: break
                        }
                    }
                }
            }
            info.editions = seen
        }
        return info
    }

    /// Convenience for the UI: mount, inspect, unmount.
    public static func inspect(iso: URL) async throws -> ISOInfo {
        let mounted = try await mount(iso)
        let info = await inspect(mountPoint: mounted.url)
        await detach(mounted)
        return info
    }
}
