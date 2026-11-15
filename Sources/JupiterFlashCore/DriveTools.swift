// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Drive test (bad blocks / fake capacity)

public struct DriveTestResult: Sendable {
    public var totalBlocks: Int
    public var badBlocks: Int
    public var firstBadOffset: Int64?
    public var writeMBps: Double
    public var readMBps: Double
    public var quick: Bool

    public init(totalBlocks: Int, badBlocks: Int, firstBadOffset: Int64?, writeMBps: Double, readMBps: Double, quick: Bool) {
        self.totalBlocks = totalBlocks; self.badBlocks = badBlocks; self.firstBadOffset = firstBadOffset
        self.writeMBps = writeMBps; self.readMBps = readMBps; self.quick = quick
    }

    public var isHealthy: Bool { badBlocks == 0 }
    public var summary: String {
        if badBlocks == 0 {
            return "No errors in \(totalBlocks) MiB tested\(quick ? " (quick test: samples spread over the whole drive)" : "") · write \(Int(writeMBps)) MB/s · read \(Int(readMBps)) MB/s"
        }
        let at = firstBadOffset.map { " The first bad block is at \(ByteFormat.string($0))." } ?? ""
        return "\(badBlocks) of \(totalBlocks) blocks read back wrong.\(at) The drive is faulty or its real capacity is smaller than advertised – don't trust it with data."
    }
}

/// Destructive write/read-back test. Every 1 MiB block gets unique pseudo-random data, so a drive that silently
/// wraps around (fake capacity) or loses data shows up as mismatching blocks. Runs as root inside the helper.
public enum DriveTester {
    static let block = 1 << 20

    /// Fills `buf` with data derived from (seed, block index): different for every block.
    static func fill(_ buf: inout [UInt8], seed: UInt64, block index: Int64) {
        var x = seed ^ (UInt64(bitPattern: index) &* 0x9E37_79B9_7F4A_7C15) | 1
        buf.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: UInt64.self)
            for i in 0..<p.count {
                x ^= x >> 12; x ^= x << 25; x ^= x >> 27          // xorshift64*
                p[i] = x &* 0x2545_F491_4F6C_DD1D
            }
        }
    }

    public static func run(device: String, size: Int64, quick: Bool,
                           onProgress: (String, Int64, Int64) -> Void,
                           isCancelled: () -> Bool) throws -> DriveTestResult {
        let nBlocks = Int(size / Int64(block))
        guard nBlocks > 0 else { throw FlashError.message("The drive is smaller than 1 MiB.") }
        // Quick mode: ~256 blocks spread evenly (always incl. first and last) – enough to expose wrap-around fakes.
        var indices: [Int64]
        if quick && nBlocks > 256 {
            indices = (0..<256).map { Int64($0) * Int64(nBlocks - 1) / 255 }
        } else {
            indices = (0..<nBlocks).map(Int64.init)
        }
        let seed = UInt64.random(in: 1...UInt64.max)
        let faultBlock = ProcessInfo.processInfo.environment["JUPITERFLASH_TEST_FAULT"].flatMap(Int64.init)   // test hook

        let wfd = open(device, O_WRONLY | O_CREAT, 0o644)
        guard wfd >= 0 else { throw FlashError.message("Couldn't open \(device): \(String(cString: strerror(errno)))") }
        _ = fcntl(wfd, F_NOCACHE, 1)
        var buf = [UInt8](repeating: 0, count: block)
        let total = Int64(indices.count) * Int64(block)
        var done: Int64 = 0
        var last = Date.distantPast
        let t0 = Date()
        do {
            for idx in indices {
                if isCancelled() { close(wfd); throw FlashError.message(RawWriter.cancelledMarker) }
                fill(&buf, seed: seed, block: idx)
                let w = buf.withUnsafeBytes { pwrite(wfd, $0.baseAddress!, block, off_t(idx) * off_t(block)) }
                if w != block { close(wfd); throw FlashError.message("Write error at \(ByteFormat.string(idx * Int64(block))): \(String(cString: strerror(errno)))") }
                done += Int64(block)
                if Date().timeIntervalSince(last) > 0.2 { last = Date(); onProgress("write", done, total) }
            }
        }
        _ = fcntl(wfd, F_FULLFSYNC)
        close(wfd)
        onProgress("write", total, total)
        let writeSecs = max(Date().timeIntervalSince(t0), 0.001)

        let rfd = open(device, O_RDONLY)
        guard rfd >= 0 else { throw FlashError.message("Couldn't reopen \(device) to read it back: \(String(cString: strerror(errno)))") }
        defer { close(rfd) }
        _ = fcntl(rfd, F_NOCACHE, 1)
        var expect = [UInt8](repeating: 0, count: block)
        var got = [UInt8](repeating: 0, count: block)
        var bad = 0
        var firstBad: Int64?
        done = 0
        last = .distantPast
        let t1 = Date()
        for idx in indices {
            if isCancelled() { throw FlashError.message(RawWriter.cancelledMarker) }
            fill(&expect, seed: seed, block: idx)
            let n = got.withUnsafeMutableBytes { pread(rfd, $0.baseAddress!, block, off_t(idx) * off_t(block)) }
            if n == block, faultBlock == idx { got[0] ^= 0xFF }
            if n != block || memcmp(expect, got, block) != 0 {
                bad += 1
                if firstBad == nil { firstBad = idx * Int64(block) }
            }
            done += Int64(block)
            if Date().timeIntervalSince(last) > 0.2 { last = Date(); onProgress("read", done, total) }
        }
        onProgress("read", total, total)
        let readSecs = max(Date().timeIntervalSince(t1), 0.001)
        // Leave the drive blank (the test data would otherwise look like a corrupt partition table to macOS).
        let zfd = open(device, O_WRONLY)
        if zfd >= 0 {
            let zeros = [UInt8](repeating: 0, count: block)
            _ = zeros.withUnsafeBytes { pwrite(zfd, $0.baseAddress!, block, 0) }
            _ = fcntl(zfd, F_FULLFSYNC)
            close(zfd)
        }
        let mib = Double(total) / 1_048_576
        return DriveTestResult(totalBlocks: indices.count, badBlocks: bad, firstBadOffset: firstBad,
                               writeMBps: mib / writeSecs, readMBps: mib / readSecs, quick: quick && nBlocks > 256)
    }
}

// MARK: - Clone a drive to an image file

public enum DriveCloner {
    static let chunk = 4 << 20

    /// Copies `size` bytes of `device` into `output` (via a .part file that is renamed on success).
    public static func clone(device: String, size: Int64, output: URL, ownerUID: UInt32?,
                             onProgress: (String, Int64, Int64) -> Void,
                             isCancelled: () -> Bool) throws {
        let part = output.appendingPathExtension("part")
        let src = open(device, O_RDONLY)
        guard src >= 0 else { throw FlashError.message("Couldn't open \(device): \(String(cString: strerror(errno)))") }
        defer { close(src) }
        _ = fcntl(src, F_NOCACHE, 1)
        let dst = open(part.path, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
        guard dst >= 0 else { throw FlashError.message("Couldn't create \(part.lastPathComponent): \(String(cString: strerror(errno)))") }
        var ok = false
        defer { close(dst); if !ok { unlink(part.path) } }

        var buf = [UInt8](repeating: 0, count: chunk)
        var done: Int64 = 0
        var last = Date.distantPast
        while done < size {
            if isCancelled() { throw FlashError.message(RawWriter.cancelledMarker) }
            let want = Int(min(Int64(chunk), size - done))
            let n = buf.withUnsafeMutableBytes { pread(src, $0.baseAddress!, want, off_t(done)) }
            if n <= 0 { throw FlashError.message("Read error at \(ByteFormat.string(done)): \(n == 0 ? "unexpected end of drive" : String(cString: strerror(errno)))") }
            var off = 0
            while off < n {
                let w = buf.withUnsafeBytes { Darwin.write(dst, $0.baseAddress! + off, n - off) }
                if w < 0 { throw FlashError.message("Couldn't write the image file: \(String(cString: strerror(errno)))") }
                off += w
            }
            done += Int64(n)
            if Date().timeIntervalSince(last) > 0.2 { last = Date(); onProgress("clone", done, size) }
        }
        onProgress("clone", size, size)
        _ = fcntl(dst, F_FULLFSYNC)
        if let uid = ownerUID { _ = fchown(dst, uid, gid_t(20)) }       // 20 = staff
        guard rename(part.path, output.path) == 0 else {
            throw FlashError.message("Couldn't move the finished image into place: \(String(cString: strerror(errno)))")
        }
        ok = true
    }
}

// MARK: - Running a helper command as administrator

public enum AdminJob {
    /// Runs `jupiterflash-cli <arguments> --progress-file F --cancel-file F` as root (password dialog) and returns its stdout.
    /// `onStatus(phase, done, total)` is called while it runs. Cancelling the Task signals the helper through the cancel file.
    public static func run(helper: URL, arguments: [String],
                           onStatus: @escaping @Sendable (String, Int64, Int64) -> Void) async throws -> String {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw FlashError.message("The helper is missing (\(helper.lastPathComponent)). Rebuild the app with scripts/build_app.sh.")
        }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jupiterflash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let progressFile = work.appendingPathComponent("progress").path
        let cancelFile = work.appendingPathComponent("cancel").path
        let script = RawFlasher.adminScript([helper.path] + arguments + ["--progress-file", progressFile, "--cancel-file", cancelFile])

        let poller = Task {
            while !Task.isCancelled {
                if let s = RawFlasher.readStatus(progressFile), s.error == nil, s.total > 0 { onStatus(s.phase, s.done, s.total) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poller.cancel() }

        let runner = Task.detached { try await Shell.run("/usr/bin/osascript", ["-e", script]) }
        do {
            return try await withTaskCancellationHandler {
                try await runner.value
            } onCancel: {
                FileManager.default.createFile(atPath: cancelFile, contents: Data())
            }
        } catch {
            let helperError = RawFlasher.readStatus(progressFile)?.error
            let text = helperError ?? error.localizedDescription
            if text.contains(RawWriter.cancelledMarker) { throw CancellationError() }
            if text.contains("User canceled") || text.contains("-128") {
                throw FlashError.message("Administrator permission was not given. Nothing was changed.")
            }
            throw FlashError.message(helperError ?? text)
        }
    }
}

extension DiskService {
    /// Size in bytes of a whole disk as reported by diskutil (used by the helper, never trusted from the caller).
    public static func rawSize(id: String) async throws -> Int64 {
        let info = try await plist(["info", "-plist", "/dev/\(id)"])
        let size = (info["TotalSize"] as? Int64) ?? (info["Size"] as? Int64) ?? 0
        guard size > 0 else { throw FlashError.message("Couldn't determine the size of \(id).") }
        return size
    }
}
