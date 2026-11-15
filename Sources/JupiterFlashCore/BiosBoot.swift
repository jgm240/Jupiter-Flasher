// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

/// Legacy-BIOS boot code, taken from the ISO's own boot/bootsect.exe (the same templates Windows'
/// `bootsect /nt60` writes): the Windows 7+ MBR code and the FAT32 boot record that loads bootmgr.
public struct BiosBootBlobs: Sendable {
    public let mbrCode: Data   // 440 bytes (code area; disk signature and partition table are kept)
    /// 3 sectors as stored in bootsect.exe: [0] boot record (goes to partition sector 0), [1] FSInfo template
    /// (unused – the volume keeps its own), [2] stage-2 loader which the boot record reads from partition sector 12.
    public let pbr: Data
    public init(mbrCode: Data, pbr: Data) { self.mbrCode = mbrCode; self.pbr = pbr }

    /// Jupiter Flasher's own loader (original code): a 1-sector FAT32 boot record that loads `bootFile`
    /// ("NTLDR" or "BOOTMGR") from the root directory to 2000:0000, plus a plain MBR loader.
    /// Used where no Microsoft boot code is available, e.g. Windows XP/2000/2003 media.
    public static func jupiter(bootFile: String) -> BiosBootBlobs {
        var sector = BootLoaders.fat32Sector
        var name = Array(bootFile.uppercased().utf8.prefix(11))
        while name.count < 11 { name.append(0x20) }
        sector.replaceSubrange(BootLoaders.nameOffset..<(BootLoaders.nameOffset + 11), with: name)
        return BiosBootBlobs(mbrCode: Data(BootLoaders.mbrCode), pbr: Data(sector))
    }
}

public enum BiosBootCode {
    static let mbrPrefix: [UInt8] = [
        0x33, 0xC0, 0x8E, 0xD0, 0xBC, 0x00, 0x7C, 0x8E, 0xC0, 0x8E, 0xD8, 0xBE, 0x00, 0x7C, 0xBF, 0x00, 0x06,
        0xB9, 0x00, 0x02, 0xFC, 0xF3, 0xA4, 0x50, 0x68, 0x1C, 0x06, 0xCB, 0xFB, 0xB9, 0x04, 0x00, 0xBD, 0xBE, 0x07,
    ]

    public static func extract(from isoMount: URL) throws -> BiosBootBlobs {
        guard let url = ISOInspector.find(isoMount, ["boot", "bootsect.exe"]),
              let data = try? Data(contentsOf: url) else {
            throw FlashError.message("This ISO has no boot/bootsect.exe, so legacy BIOS boot can't be set up.")
        }
        let d = [UInt8](data)
        func matches(_ i: Int, _ pat: [UInt8]) -> Bool {
            i >= 0 && i + pat.count <= d.count && d[i..<(i + pat.count)].elementsEqual(pat)
        }
        var mbr: Data?
        var pbr: Data?
        for i in 0..<max(0, d.count - 1536) {
            if mbr == nil, d[i] == 0x33, matches(i, mbrPrefix), d[i + 510] == 0x55, d[i + 511] == 0xAA {
                mbr = Data(d[i..<(i + 440)])
            }
            // FAT32 boot record of the NT6 family: EB 58 90, "BOOTMGR" in sector 0, FSInfo template next, 55AA after 3 sectors.
            if pbr == nil, d[i] == 0xEB, d[i + 1] == 0x58, d[i + 2] == 0x90,
               matches(i + 512, Array("RRaA".utf8)), d[i + 510] == 0x55, d[i + 511] == 0xAA,
               d[i + 1534] == 0x55, d[i + 1535] == 0xAA,
               Data(d[i..<(i + 512)]).range(of: Data("BOOTMGR".utf8)) != nil {
                pbr = Data(d[i..<(i + 1536)])
            }
            if mbr != nil && pbr != nil { break }
        }
        guard let mbr, let pbr else {
            throw FlashError.message("Couldn't find the Windows boot code inside bootsect.exe (unfamiliar version).")
        }
        return BiosBootBlobs(mbrCode: mbr, pbr: pbr)
    }
}

public enum BiosBootWriter {
    static let sector = 512

    /// Writes the MBR code, marks partition 1 active and installs the FAT32 boot record (with backup copy).
    /// `device` is the raw whole-disk node (or a regular file in tests). Needs root for real devices.
    public static func write(device: String, blobs: BiosBootBlobs) throws {
        let fd = open(device, O_RDWR)
        guard fd >= 0 else { throw FlashError.message("Couldn't open \(device) for writing: \(String(cString: strerror(errno)))") }
        defer { close(fd) }

        func read(_ lba: Int64) throws -> [UInt8] {
            var b = [UInt8](repeating: 0, count: sector)
            guard pread(fd, &b, sector, off_t(lba * Int64(sector))) == sector else {
                throw FlashError.message("Couldn't read sector \(lba): \(String(cString: strerror(errno)))")
            }
            return b
        }
        func write(_ lba: Int64, _ b: [UInt8]) throws {
            precondition(b.count == sector)
            guard pwrite(fd, b, sector, off_t(lba * Int64(sector))) == sector else {
                throw FlashError.message("Couldn't write sector \(lba): \(String(cString: strerror(errno)))")
            }
        }
        func le32(_ b: [UInt8], _ o: Int) -> UInt32 { UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24 }
        func le16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) { for k in 0..<4 { b[o + k] = UInt8((v >> (8 * UInt32(k))) & 0xFF) } }

        // --- MBR ---
        var mbr = try read(0)
        guard mbr[510] == 0x55, mbr[511] == 0xAA else {
            throw FlashError.message("The drive has no MBR partition table. BIOS boot needs the MBR scheme.")
        }
        let type = mbr[446 + 4]
        let start = Int64(le32(mbr, 446 + 8))
        guard start > 0, type == 0x0B || type == 0x0C else {
            throw FlashError.message("The first partition isn't FAT32 (type \(String(format: "0x%02X", type))).")
        }
        var newMBR = [UInt8](blobs.mbrCode) + Array(mbr[440..<512])      // keep disk signature + partition table
        // Windows names disks by their MBR signature (\ArcName\multi(0)disk(0)rdisk(0)partition(1) etc.). A blank
        // signature can't be matched, which broke XP setup's lookup of its source on a freshly formatted stick.
        if newMBR[440..<444].allSatisfy({ $0 == 0 }) {
            var sig = UInt32.random(in: 1...UInt32.max)
            for k in 0..<4 { newMBR[440 + k] = UInt8(sig & 0xFF); sig >>= 8 }
        }
        newMBR[446] = 0x80                                                // partition 1 active
        for e in [462, 478, 494] { newMBR[e] = 0x00 }

        // --- FAT32 boot record ---
        let oldVBR = try read(start)
        guard oldVBR[510] == 0x55, oldVBR[511] == 0xAA, Array(oldVBR[0x52..<0x5A]) == Array("FAT32   ".utf8) else {
            throw FlashError.message("The first partition doesn't contain a FAT32 volume.")
        }
        let backup = le16(oldVBR, 0x32), reserved = le16(oldVBR, 0x0E)
        let stage2Offset = 12      // the Windows boot record loads its second stage from partition sector 12
        let singleSector = blobs.pbr.count == 512     // Jupiter Flasher's own loader needs no second stage
        guard reserved > (singleSector ? 1 : stage2Offset) else {
            throw FlashError.message("The FAT32 volume has too few reserved sectors (\(reserved)).")
        }

        let tmpl = [UInt8](blobs.pbr)
        var s0 = Array(tmpl[0..<512])
        s0.replaceSubrange(11..<0x5A, with: oldVBR[11..<0x5A])           // keep the volume's own BPB
        put32(&s0, 0x1C, UInt32(start))                                   // hidden sectors = partition start
        if le16(s0, 0x18) == 0 { s0[0x18] = 63; s0[0x19] = 0 }            // sectors/track
        if le16(s0, 0x1A) == 0 { s0[0x1A] = 255; s0[0x1B] = 0 }           // heads
        s0[0x40] = 0x80                                                   // BIOS drive number
        let stage2: [UInt8]? = singleSector ? nil : Array(tmpl[1024..<1536])

        var plan: [(Int64, [UInt8])] = [(0, newMBR), (start, s0)]
        if let stage2 { plan.append((start + Int64(stage2Offset), stage2)) }
        if backup >= 3, backup + (singleSector ? 0 : stage2Offset) < reserved {   // backup boot record (+ its stage 2)
            plan.append((start + Int64(backup), s0))
            if let stage2 { plan.append((start + Int64(backup + stage2Offset), stage2)) }
        }
        for (lba, bytes) in plan { try write(lba, bytes) }
        _ = fcntl(fd, F_FULLFSYNC)
        for (lba, bytes) in plan {
            guard try read(lba) == bytes else { throw FlashError.message("Boot code verification failed at sector \(lba).") }
        }
    }
}

public enum BiosBootRunner {
    /// Installs BIOS boot code on `disk` (which must be formatted MBR + FAT32). Asks for the administrator
    /// password through the bundled helper. Unmounts the disk; the caller remounts it.
    public static func apply(disk: Disk, blobs: BiosBootBlobs, helper: URL?, log: LogHandler) async throws {
        if let test = ProcessInfo.processInfo.environment["JUPITERFLASH_BIOS_TEST_TARGET"] {
            // Test hook: write into a regular file (the backing image) instead of a device, no root needed.
            try await DiskService.unmountDisk(id: disk.id)
            try BiosBootWriter.write(device: test, blobs: blobs)
            log("[test] BIOS boot code written to \(test)")
            return
        }
        guard let helper, FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw FlashError.message("The write helper is missing. Rebuild the app with scripts/build_app.sh.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jupiterflash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let mbrFile = work.appendingPathComponent("mbr.bin"), pbrFile = work.appendingPathComponent("pbr.bin")
        let statusFile = work.appendingPathComponent("status").path
        try blobs.mbrCode.write(to: mbrFile)
        try blobs.pbr.write(to: pbrFile)

        let script = RawFlasher.adminScript([helper.path, "bios", disk.id, "--mbr", mbrFile.path, "--pbr", pbrFile.path,
                                             "--progress-file", statusFile, "--yes"])
        log("Requesting administrator permission to write the BIOS boot code")
        do {
            _ = try await Shell.run("/usr/bin/osascript", ["-e", script])
        } catch {
            let text = RawFlasher.readStatus(statusFile)?.error ?? error.localizedDescription
            if text.contains("User canceled") || text.contains("-128") {
                throw FlashError.message("Administrator permission was not given. Nothing was changed on the drive's boot sectors.")
            }
            throw FlashError.message("Couldn't install the BIOS boot code: \(text)")
        }
        log("BIOS boot code installed.")
    }
}
