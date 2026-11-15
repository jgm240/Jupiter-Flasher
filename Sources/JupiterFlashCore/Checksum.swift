// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

public enum Checksum {
    /// Streaming SHA-256 of a file. `progress` gets 0...1. Blocking: call from a background task.
    public static func sha256(of url: URL, progress: ((Double) -> Void)? = nil, isCancelled: () -> Bool = { false }) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FlashError.message("Couldn't open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let total = max(Int64(st.st_size), 1)
        var hasher = SHA256()
        let chunk = 4 << 20
        var buf = [UInt8](repeating: 0, count: chunk)
        var done: Int64 = 0
        var last = Date.distantPast
        while true {
            if isCancelled() { throw CancellationError() }
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress!, chunk) }
            if n < 0 { throw FlashError.message("Read error: \(String(cString: strerror(errno)))") }
            if n == 0 { break }
            buf.withUnsafeBytes { hasher.update(bufferPointer: UnsafeRawBufferPointer(rebasing: $0[0..<n])) }
            done += Int64(n)
            if Date().timeIntervalSince(last) > 0.1 { last = Date(); progress?(Double(done) / Double(total)) }
        }
        progress?(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Pulls a 64-hex-digit SHA-256 out of whatever the user pasted (a bare hash, or a line like
    /// "SHA256 (file.iso) = abc…" / "abc…  file.iso"). Returns nil when there isn't exactly one.
    public static func parseExpected(_ text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{64}(?![0-9A-Fa-f])") else { return nil }
        let ns = text as NSString
        let found = Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() })
        return found.count == 1 ? found.first : nil
    }
}
