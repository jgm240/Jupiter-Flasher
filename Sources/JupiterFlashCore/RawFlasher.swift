// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

// MARK: - Image inspection

public struct RawImageInfo: Sendable {
    public var name: String
    public var size: Int64
    public var hasMBRSignature: Bool   // 0x55AA at offset 510 – present in isohybrid / disk images
    public var isISO9660: Bool         // "CD001" at 0x8001

    /// True when the image carries a boot sector, so writing it raw gives a bootable stick.
    public var looksBootableRaw: Bool { hasMBRSignature }

    public var summary: String {
        var kind = hasMBRSignature ? (isISO9660 ? "hybrid ISO (bootable when written raw)" : "disk image (bootable MBR)")
                                   : (isISO9660 ? "plain ISO (not a hybrid image)" : "raw image")
        if size == 0 { kind = "empty file" }
        return "\(name) · \(ByteFormat.string(size)) · \(kind)"
    }
}

public enum RawImage {
    public static func inspect(_ url: URL) throws -> RawImageInfo {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FlashError.message("Couldn't open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        var sig = [UInt8](repeating: 0, count: 2)
        var iso = [UInt8](repeating: 0, count: 5)
        let a = pread(fd, &sig, 2, 510)
        let b = pread(fd, &iso, 5, 0x8001)
        return RawImageInfo(
            name: url.lastPathComponent, size: Int64(st.st_size),
            hasMBRSignature: a == 2 && sig == [0x55, 0xAA],
            isISO9660: b == 5 && iso == Array("CD001".utf8))
    }
}

// MARK: - The part that runs as root

public enum RawWriter {
    public static let cancelledMarker = "JUPITERFLASH_CANCELLED"
    static let chunk = 4 << 20
    static let sector = 4096

    /// Writes `image` to `device` byte-for-byte, then (optionally) reads it back and compares.
    /// Blocking; called from the privileged helper. `onProgress(phase, done, total)`.
    public static func write(image: URL, device: String, verify: Bool,
                             onProgress: (String, Int64, Int64) -> Void,
                             isCancelled: () -> Bool) throws {
        let src = open(image.path, O_RDONLY)
        guard src >= 0 else { throw FlashError.message("Couldn't open image: \(String(cString: strerror(errno)))") }
        defer { close(src) }
        var st = stat()
        fstat(src, &st)
        let total = Int64(st.st_size)
        guard total > 0 else { throw FlashError.message("The image file is empty.") }

        let dst = open(device, O_WRONLY | O_CREAT, 0o644)   // O_CREAT only matters for the test target (a regular file)
        guard dst >= 0 else { throw FlashError.message("Couldn't open \(device) for writing: \(String(cString: strerror(errno)))") }
        defer { close(dst) }

        var buf = [UInt8](repeating: 0, count: chunk)
        var done: Int64 = 0
        var lastReport = Date.distantPast
        while done < total {
            if isCancelled() { throw FlashError.message(cancelledMarker) }
            let n = readFully(src, &buf, chunk)
            if n < 0 { throw FlashError.message("Read error: \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            // Raw devices only accept whole sectors: zero-pad the final block.
            let padded = (n + sector - 1) / sector * sector
            if padded > n { for i in n..<padded { buf[i] = 0 } }
            var off = 0
            while off < padded {
                let w = buf.withUnsafeBytes { Darwin.write(dst, $0.baseAddress! + off, padded - off) }
                if w < 0 { throw FlashError.message("Write error at \(ByteFormat.string(done)): \(String(cString: strerror(errno)))") }
                off += w
            }
            done += Int64(n)
            if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); onProgress("write", done, total) }
        }
        onProgress("write", total, total)
        onProgress("flush", total, total)
        _ = fcntl(dst, F_FULLFSYNC)

        guard verify else { return }
        // Read back from the device and compare with the image.
        close(src)
        let src2 = open(image.path, O_RDONLY)
        let rd = open(device, O_RDONLY)
        guard src2 >= 0, rd >= 0 else { throw FlashError.message("Couldn't reopen the drive to verify.") }
        defer { close(src2); close(rd) }
        _ = fcntl(rd, F_NOCACHE, 1)
        var a = [UInt8](repeating: 0, count: chunk)
        var b = [UInt8](repeating: 0, count: chunk)
        var checked: Int64 = 0
        lastReport = .distantPast
        while checked < total {
            if isCancelled() { throw FlashError.message(cancelledMarker) }
            let want = Int(min(Int64(chunk), total - checked))
            let na = readFully(src2, &a, want)
            let nb = readFully(rd, &b, want)
            if na != want || nb != want { throw FlashError.message("Verification failed: couldn't read back data near \(ByteFormat.string(checked)).") }
            if memcmp(a, b, want) != 0 {
                throw FlashError.message("Verification failed: the drive differs from the image in the 4 MB block starting at \(ByteFormat.string(checked)). The drive may be faulty.")
            }
            checked += Int64(want)
            if Date().timeIntervalSince(lastReport) > 0.2 { lastReport = Date(); onProgress("verify", checked, total) }
        }
        onProgress("verify", total, total)
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
}

// MARK: - Orchestration from the (unprivileged) app

public struct RawFlashOptions: Sendable {
    public var image: URL
    public var disk: Disk
    public var verify: Bool
    public var ejectWhenDone: Bool
    /// Path of the `jupiterflash-cli` executable that performs the privileged write.
    public var helper: URL
    public init(image: URL, disk: Disk, verify: Bool = true, ejectWhenDone: Bool = true, helper: URL) {
        self.image = image; self.disk = disk; self.verify = verify; self.ejectWhenDone = ejectWhenDone; self.helper = helper
    }
}

public enum RawFlasher {
    static func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// AppleScript that runs `args` (an executable followed by its arguments) as root, via the system password dialog.
    static func adminScript(_ args: [String]) -> String {
        let cmd = args.map(shellQuote).joined(separator: " ")
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\" with administrator privileges"
    }

    /// Parses the helper's progress file: "<phase> <done> <total>" or "error <message>".
    static func readStatus(_ path: String) -> (phase: String, done: Int64, total: Int64, error: String?)? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let line = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("error ") { return ("error", 0, 0, String(line.dropFirst(6))) }
        let p = line.split(separator: " ")
        guard p.count == 3, let d = Int64(p[1]), let t = Int64(p[2]) else { return nil }
        return (String(p[0]), d, t, nil)
    }

    public static func flash(_ o: RawFlashOptions, progress: @escaping ProgressHandler, log: @escaping LogHandler) async throws {
        let info = try RawImage.inspect(o.image)
        if info.size > o.disk.size {
            throw FlashError.message("The image (\(ByteFormat.string(info.size))) is larger than the drive (\(ByteFormat.string(o.disk.size))).")
        }
        try await DiskService.verifySafeTarget(o.disk)
        guard FileManager.default.isExecutableFile(atPath: o.helper.path) else {
            throw FlashError.message("The write helper is missing (\(o.helper.lastPathComponent)). Rebuild the app with scripts/build_app.sh.")
        }

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("jupiterflash-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let progressFile = work.appendingPathComponent("progress").path
        let cancelFile = work.appendingPathComponent("cancel").path

        let cmd = ([o.helper.path, "dd", o.image.path, o.disk.id, "--progress-file", progressFile, "--cancel-file", cancelFile]
                   + (o.verify ? ["--verify"] : []) + ["--yes"]).map(shellQuote).joined(separator: " ")
        let escaped = cmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"

        progress(0.01, "Waiting for administrator permission…")
        log("Requesting administrator permission to write \(o.disk.device)")

        let verify = o.verify
        // Poll the helper's progress file while it runs.
        let poller = Task {
            while !Task.isCancelled {
                if let s = readStatus(progressFile), s.error == nil, s.total > 0 {
                    let f = Double(s.done) / Double(s.total)
                    switch s.phase {
                    case "write": progress(0.03 + (verify ? 0.47 : 0.94) * f,
                                           "Writing image… \(ByteFormat.string(s.done)) of \(ByteFormat.string(s.total))")
                    case "flush": progress(verify ? 0.50 : 0.97, "Flushing to the drive…")
                    case "verify": progress(0.50 + 0.47 * f, "Verifying… \(ByteFormat.string(s.done)) of \(ByteFormat.string(s.total))")
                    default: break
                    }
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        defer { poller.cancel() }

        // The root process must outlive a cancelled Task, so it is signalled through a file
        // (never by killing osascript) and the runner is detached from this Task's cancellation.
        let runner = Task.detached { try await Shell.run("/usr/bin/osascript", ["-e", script]) }
        do {
            try await withTaskCancellationHandler {
                _ = try await runner.value
            } onCancel: {
                FileManager.default.createFile(atPath: cancelFile, contents: Data())
            }
        } catch {
            let helperError = readStatus(progressFile)?.error
            let text = helperError ?? error.localizedDescription
            if text.contains(RawWriter.cancelledMarker) { throw CancellationError() }
            if text.contains("User canceled") || text.contains("-128") {
                throw FlashError.message("Administrator permission was not given. Nothing was written.")
            }
            throw FlashError.message(helperError ?? text)
        }

        log("Image written\(o.verify ? " and verified" : "").")
        if o.ejectWhenDone {
            progress(0.99, "Ejecting…")
            _ = try? await Shell.run("/usr/sbin/diskutil", ["eject", o.disk.device], onLine: { log($0) })
        }
        progress(1, "Done")
    }
}
