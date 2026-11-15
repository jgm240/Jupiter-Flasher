// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Text-mode (F6-style) mass-storage drivers for Windows 2000/XP/2003, added to the stick so setup loads them
/// without anyone pressing F6 – e.g. Intel AHCI / RAID drivers so XP installs on a PC that is in AHCI mode.
///
/// Layout used (the documented unattended method): the driver's files go to `\$OEM$\TEXTMODE\` on the install
/// source, and winnt.sif gets `[Unattended] OemPreinstall=Yes`, `[MassStorageDrivers]` and `[OEMBootFiles]`.
public struct NT5DriverPack: Sendable {
    public let folder: URL
    /// Every file in the folder (relative names, flat).
    public let files: [String]
    /// Controller descriptions from the [scsi] section of txtsetup.oem; setup matches them by this exact text.
    public let descriptions: [String]

    public static func load(_ folder: URL) throws -> NT5DriverPack {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).filter { !$0.hasPrefix(".") }
        guard let oem = names.first(where: { $0.lowercased() == "txtsetup.oem" }) else {
            throw FlashError.message("“\(folder.lastPathComponent)” has no txtsetup.oem. Choose the folder of a Windows XP/2003 text-mode (F6) driver.")
        }
        var isDir: ObjCBool = false
        let files = names.filter { fm.fileExists(atPath: folder.appendingPathComponent($0).path, isDirectory: &isDir) && !isDir.boolValue }
        guard let data = fm.contents(atPath: folder.appendingPathComponent(oem).path) else {
            throw FlashError.message("Couldn't read txtsetup.oem.")
        }
        let text = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let desc = parseSCSIDescriptions(text)
        guard !desc.isEmpty else {
            throw FlashError.message("txtsetup.oem has no [SCSI] section, so this isn't a storage driver.")
        }
        return NT5DriverPack(folder: folder, files: files, descriptions: desc)
    }

    /// `[SCSI]` lines look like:  iaAHCI = "Intel(R) ICH8R/DO/DH SATA AHCI Controller"
    static func parseSCSIDescriptions(_ text: String) -> [String] {
        var inSCSI = false
        var out: [String] = []
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inSCSI = line.lowercased().hasPrefix("[scsi]")
                continue
            }
            guard inSCSI, !line.hasPrefix(";"), let eq = line.firstIndex(of: "=") else { continue }
            var value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let semi = value.firstIndex(of: ";"), !value.contains("\"") || value.lastIndex(of: "\"")! < semi { value = String(value[..<semi]).trimmingCharacters(in: .whitespaces) }
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            if !value.isEmpty { out.append(value) }
        }
        return out
    }

    /// Extra winnt.sif sections that make text-mode setup load this pack.
    public var winntSifSections: String {
        var s = "[Unattended]\r\nOemPreinstall = Yes\r\n\r\n[MassStorageDrivers]\r\n"
        for d in descriptions { s += "\"\(d)\" = \"OEM\"\r\n" }
        s += "\r\n[OEMBootFiles]\r\n"
        for f in files { s += "\(f)\r\n" }
        return s
    }
}
