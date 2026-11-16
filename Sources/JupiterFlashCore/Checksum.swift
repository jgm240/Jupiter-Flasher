// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import CryptoKit

/// Hash functions offered for checking an image. MD5 and SHA-1 are broken as security hashes, but older
/// downloads (Windows 7 and earlier, Linux ISOs, …) are only published with them. They still catch
/// corrupt downloads; for tamper-proofing prefer SHA-256 whenever the publisher offers it.
public enum HashAlgorithm: String, CaseIterable, Sendable {
    case md5, sha1, sha256

    public var displayName: String {
        switch self { case .md5: return "MD5"; case .sha1: return "SHA-1"; case .sha256: return "SHA-256" }
    }
    /// Length of the hex digest.
    public var hexLength: Int {
        switch self { case .md5: return 32; case .sha1: return 40; case .sha256: return 64 }
    }
    /// True for the algorithms that are no longer collision resistant.
    public var isWeak: Bool { self != .sha256 }

    public static func forHexLength(_ n: Int) -> HashAlgorithm? { allCases.first { $0.hexLength == n } }
}

public enum Checksum {
    /// Streaming hash of a file. `progress` gets 0...1. Blocking: call from a background task.
    public static func compute(_ algorithm: HashAlgorithm, of url: URL, progress: ((Double) -> Void)? = nil,
                               isCancelled: () -> Bool = { false }) throws -> String {
        switch algorithm {
        case .md5: return try run(Insecure.MD5(), url, progress, isCancelled)
        case .sha1: return try run(Insecure.SHA1(), url, progress, isCancelled)
        case .sha256: return try run(SHA256(), url, progress, isCancelled)
        }
    }

    /// Streaming SHA-256 of a file (kept for existing callers).
    public static func sha256(of url: URL, progress: ((Double) -> Void)? = nil, isCancelled: () -> Bool = { false }) throws -> String {
        try compute(.sha256, of: url, progress: progress, isCancelled: isCancelled)
    }

    private static func run<H: HashFunction>(_ start: H, _ url: URL, _ progress: ((Double) -> Void)?,
                                             _ isCancelled: () -> Bool) throws -> String {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { throw FlashError.message("Couldn't open \(url.lastPathComponent): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var st = stat()
        fstat(fd, &st)
        let total = max(Int64(st.st_size), 1)
        var hasher = start
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

    /// Pulls a hash out of whatever the user pasted (a bare hash, or a line like "SHA256 (file.iso) = abc…" /
    /// "abc…  file.iso"). The algorithm follows from the length: 32 hex digits = MD5, 40 = SHA-1, 64 = SHA-256.
    /// Returns nil when there isn't exactly one hash (a paste with several different ones is ambiguous).
    public static func parse(_ text: String) -> (algorithm: HashAlgorithm, hash: String)? {
        // A run of hex digits that isn't part of a longer run; the length check happens afterwards so a
        // 70-digit string is rejected instead of matching a 64-digit slice of it.
        guard let re = try? NSRegularExpression(pattern: "(?<![0-9A-Fa-f])[0-9A-Fa-f]{32,}(?![0-9A-Fa-f])") else { return nil }
        let ns = text as NSString
        let runs = Set(re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range).lowercased() })
        let valid = runs.filter { HashAlgorithm.forHexLength($0.count) != nil }
        guard runs.count == 1, let h = valid.first, let alg = HashAlgorithm.forHexLength(h.count) else { return nil }
        return (alg, h)
    }

    /// Pulls a single SHA-256 out of pasted text (nil for other hash lengths).
    public static func parseExpected(_ text: String) -> String? {
        guard let p = parse(text), p.algorithm == .sha256 else { return nil }
        return p.hash
    }
}
