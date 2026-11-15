// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation

public struct ShellError: LocalizedError {
    public let command: String
    public let status: Int32
    public let output: String
    public var errorDescription: String? {
        let tail = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(command) failed (exit \(status))" + (tail.isEmpty ? "" : ":\n\(tail)")
    }
}

/// Thread-safe collector that also splits output into lines (on \n and \r,
/// so progress bars that rewrite the same line are reported too).
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var all = Data()
    private var pending = ""
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) { self.onLine = onLine }

    func append(_ data: Data) {
        var lines: [String] = []
        lock.lock()
        all.append(data)
        if onLine != nil, let s = String(data: data, encoding: .utf8) {
            pending += s
            while let i = pending.firstIndex(where: { $0.isNewline }) {
                let line = String(pending[..<i])
                pending.removeSubrange(...i)
                if !line.isEmpty { lines.append(line) }
            }
        }
        lock.unlock()
        for l in lines { onLine?(l) }
    }

    func finish() {
        lock.lock()
        let rest = pending
        pending = ""
        lock.unlock()
        if !rest.isEmpty { onLine?(rest) }
    }

    var data: Data { lock.lock(); defer { lock.unlock() }; return all }
}

public enum Shell {
    /// Runs a tool, returning combined stdout+stderr. Cancelling the Task terminates the process.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> String {
        let data = try await runData(executable, arguments, onLine: onLine, mergeStderr: true)
        return String(decoding: data, as: UTF8.self)
    }

    /// Runs a tool and returns raw stdout (used for plist output).
    public static func runData(
        _ executable: String,
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil,
        mergeStderr: Bool = false
    ) async throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = mergeStderr ? outPipe : errPipe
        process.standardInput = FileHandle.nullDevice

        let out = OutputCollector(onLine: onLine)
        let err = OutputCollector(onLine: nil)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if !d.isEmpty { out.append(d) }
        }
        if !mergeStderr {
            errPipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if !d.isEmpty { err.append(d) }
            }
        }
        let name = (executable as NSString).lastPathComponent + " " + arguments.prefix(2).joined(separator: " ")

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let restOut = outPipe.fileHandleForReading.readDataToEndOfFile()
                    if !restOut.isEmpty { out.append(restOut) }
                    if !mergeStderr {
                        let restErr = errPipe.fileHandleForReading.readDataToEndOfFile()
                        if !restErr.isEmpty { err.append(restErr) }
                    }
                    out.finish()
                    if p.terminationStatus == 0 {
                        cont.resume(returning: out.data)
                    } else {
                        let text = String(decoding: mergeStderr ? out.data : err.data + out.data, as: UTF8.self)
                        cont.resume(throwing: ShellError(command: name, status: p.terminationStatus, output: text))
                    }
                }
                do { try process.run() } catch { cont.resume(throwing: error) }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
    }
}
