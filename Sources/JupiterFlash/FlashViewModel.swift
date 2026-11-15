// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit
import Combine
import JupiterFlashCore

enum FlashMode: String, CaseIterable, Identifiable, Codable {
    case windows = "Windows ISO"
    case dd = "DD image"
    case test = "Test drive"
    case clone = "Clone drive"
    var id: String { rawValue }
}

/// Settings remembered between launches (never the drive choice or the "list fixed drives" switch).
private struct Preferences: Codable {
    var mode: FlashMode = .windows
    var scheme = "MBR"
    var biosBoot = false
    var customization = WindowsCustomization()
    var ejectWhenDone = true
    var verifyAfterWrite = true
    var quickTest = true
}

@MainActor
final class FlashViewModel: ObservableObject {
    enum Phase: Equatable { case idle, running, finished, failed(String), cancelled }
    enum HashState: Equatable { case idle, computing(Double), done(String), failed(String) }

    // Inputs
    @Published var mode: FlashMode = .windows {
        didSet { if oldValue != mode, let u = imageURL, !isRunning, mode == .windows || mode == .dd { setImage(u) } }
    }
    @Published var imageURL: URL?
    @Published var isoInfo: ISOInfo?          // Windows mode
    @Published var rawInfo: RawImageInfo?     // DD mode
    @Published var imageError: String?
    @Published var isInspecting = false
    @Published var disks: [Disk] = []
    @Published var selectedDiskID: String?
    @Published var includeFixedDrives = false { didSet { Task { await refreshDisks() } } }
    @Published var label = "WINDOWS"
    @Published var scheme: PartitionScheme = .mbr { didSet { if scheme == .gpt { biosBoot = false } } }
    @Published var biosBoot = false { didSet { if biosBoot { scheme = .mbr } } }
    @Published var customization = WindowsCustomization()
    @Published var ejectWhenDone = true
    @Published var disableACPI = false
    @Published var driverFolder: URL?
    @Published var driverPack: NT5DriverPack?
    @Published var driverError: String?
    @Published var verifyAfterWrite = true
    @Published var quickTest = true
    @Published var cloneOutput: URL?

    // Checksum
    @Published var expectedHash = ""
    @Published var hashState: HashState = .idle
    private var hashTask: Task<Void, Never>?

    // History
    @Published var recents: [URL] = []

    // State
    @Published var phase: Phase = .idle
    @Published var progress = 0.0
    @Published var statusText = "Ready"
    @Published var logLines: [String] = []
    @Published var resultText: String?        // outcome of a drive test

    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var saver: AnyCancellable?
    private var loadingPrefs = true

    var selectedDisk: Disk? { disks.first { $0.id == selectedDiskID } }
    var isRunning: Bool { phase == .running }
    var wimlibMissing: Bool { mode == .windows && (isoInfo?.needsSplit ?? false) && Wimlib.executable == nil }
    var needsImage: Bool { mode == .windows || mode == .dd }

    /// Problem with the local user name, if the account option is on.
    var accountNameProblem: String? {
        customization.skipOnlineAccount ? WindowsCustomization.accountNameProblem(customization.localAccountName) : nil
    }

    /// The helper that performs privileged work; it sits next to the app's executable.
    var helperURL: URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("jupiterflash-cli")
    }

    var startTitle: String {
        switch mode { case .test: return "TEST"; case .clone: return "CLONE"; default: return "START" }
    }

    var canStart: Bool {
        guard !isRunning, !isInspecting, selectedDisk != nil else { return false }
        switch mode {
        case .windows:
            guard (isoInfo?.isWindowsInstaller ?? false) && !wimlibMissing else { return false }
            if biosBoot && !(isoInfo?.isNT5 ?? false) && !(isoInfo?.supportsBIOSBoot ?? false) { return false }
            if (isoInfo?.isNT5 ?? false) && driverFolder != nil && driverPack == nil { return false }
            return accountNameProblem == nil
        case .dd: return (rawInfo?.size ?? 0) > 0
        case .test: return true
        case .clone: return cloneOutput != nil
        }
    }

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isRunning else { return }
                    await self.refreshDisks()
                }
            })
        }
        loadPreferences()
        loadingPrefs = false
        // Save settings shortly after any change.
        saver = objectWillChange.debounce(for: .seconds(0.6), scheduler: DispatchQueue.main).sink { [weak self] _ in
            MainActor.assumeIsolated { self?.savePreferences() }
        }
        Notifier.requestAuthorization()
        Task { await refreshDisks() }
    }

    // MARK: Preferences & recents

    private func loadPreferences() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: "preferences"), let p = try? JSONDecoder().decode(Preferences.self, from: data) {
            mode = p.mode
            scheme = PartitionScheme(rawValue: p.scheme) ?? .mbr
            biosBoot = p.biosBoot
            customization = p.customization
            ejectWhenDone = p.ejectWhenDone
            verifyAfterWrite = p.verifyAfterWrite
            quickTest = p.quickTest
        }
        recents = (d.stringArray(forKey: "recentImages") ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func savePreferences() {
        guard !loadingPrefs else { return }
        let p = Preferences(mode: mode, scheme: scheme.rawValue, biosBoot: biosBoot, customization: customization,
                            ejectWhenDone: ejectWhenDone, verifyAfterWrite: verifyAfterWrite, quickTest: quickTest)
        if let data = try? JSONEncoder().encode(p) { UserDefaults.standard.set(data, forKey: "preferences") }
    }

    private func remember(_ url: URL) {
        recents.removeAll { $0 == url }
        recents.insert(url, at: 0)
        recents = Array(recents.prefix(8))
        UserDefaults.standard.set(recents.map(\.path), forKey: "recentImages")
    }

    func clearRecents() {
        recents = []
        UserDefaults.standard.removeObject(forKey: "recentImages")
    }

    // MARK: Disks

    func refreshDisks() async {
        do {
            let found = try await DiskService.listDisks(includeFixed: includeFixedDrives)
            disks = found
            if !found.contains(where: { $0.id == selectedDiskID }) { selectedDiskID = found.first?.id }
        } catch {
            appendLog("Couldn't list drives: \(error.localizedDescription)")
        }
    }

    // MARK: Image

    func chooseImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["iso", "img"].compactMap { .init(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        panel.message = mode == .windows ? "Choose a Windows installation ISO" : "Choose a disk image to write"
        if panel.runModal() == .OK, let url = panel.url { setImage(url) }
    }

    /// Called for files dropped on the window or Dock icon, or opened with the app.
    func openFile(_ url: URL) {
        guard !isRunning, ["iso", "img"].contains(url.pathExtension.lowercased()) else { return }
        if !needsImage { mode = .windows }
        setImage(url)
    }

    func setImage(_ url: URL) {
        guard !isRunning else { return }
        imageURL = url
        isoInfo = nil
        rawInfo = nil
        imageError = nil
        phase = .idle
        progress = 0
        hashTask?.cancel()
        hashState = .idle
        remember(url)

        if mode == .dd {
            do {
                let info = try RawImage.inspect(url)
                rawInfo = info
                if info.size == 0 { imageError = "This file is empty." }
                else if !info.looksBootableRaw {
                    imageError = info.isISO9660
                        ? "This ISO isn't a hybrid image, so writing it raw won't give a bootable drive. Windows ISOs aren't hybrid either – use Windows ISO mode for those."
                        : "No boot sector found in this image. The drive may not be bootable."
                }
            } catch { imageError = error.localizedDescription }
            statusText = "Ready"
            return
        }

        isInspecting = true
        statusText = "Reading ISO…"
        Task {
            do {
                let info = try await ISOInspector.inspect(iso: url)
                isoInfo = info
                if !info.isWindowsInstaller {
                    let hybrid = (try? RawImage.inspect(url))?.looksBootableRaw ?? false
                    imageError = hybrid
                        ? "This isn't a Windows installation ISO. It looks like a hybrid image (e.g. Linux) – switch to DD image mode."
                        : "This doesn't look like a Windows installation ISO."
                } else if info.needsSplit && Wimlib.executable == nil {
                    imageError = "This ISO needs wimlib to split its install.wim. Run “brew install wimlib” in Terminal, then re-select the ISO."
                } else {
                    label = Flasher.sanitizeLabel(info.label)
                    if info.isNT5 { scheme = .mbr }
                }
            } catch {
                imageError = error.localizedDescription
            }
            isInspecting = false
            statusText = "Ready"
        }
    }

    // MARK: Checksum

    /// The hash the user pasted, if it contains exactly one SHA-256.
    var expectedParsed: String? { Checksum.parseExpected(expectedHash) }

    /// true = matches, false = differs, nil = nothing to compare yet
    var hashMatches: Bool? {
        guard case .done(let h) = hashState, let want = expectedParsed else { return nil }
        return h == want
    }

    func computeHash() {
        guard let url = imageURL else { return }
        hashTask?.cancel()
        hashState = .computing(0)
        hashTask = Task {
            let result: Result<String, Error> = await Task.detached(priority: .utility) {
                do {
                    return .success(try Checksum.sha256(of: url, progress: { f in
                        Task { @MainActor [weak self] in
                            if case .computing = self?.hashState { self?.hashState = .computing(f) }
                        }
                    }, isCancelled: { Task.isCancelled }))
                } catch { return .failure(error) }
            }.value
            switch result {
            case .success(let h): hashState = .done(h)
            case .failure(let e): hashState = e is CancellationError ? .idle : .failed(e.localizedDescription)
            }
        }
    }

    // MARK: XP drivers / clone target

    func chooseDriverFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose the folder of a Windows XP text-mode (F6) storage driver – it contains txtsetup.oem"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        setDriverFolder(url)
    }

    func setDriverFolder(_ url: URL?) {
        driverFolder = url
        driverPack = nil
        driverError = nil
        guard let url else { return }
        do { driverPack = try NT5DriverPack.load(url) } catch { driverError = error.localizedDescription }
    }

    func chooseCloneOutput() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.init(filenameExtension: "img")].compactMap { $0 }
        panel.nameFieldStringValue = ((selectedDisk?.name ?? "drive").replacingOccurrences(of: "/", with: "-")) + ".img"
        panel.message = "Where should the drive image be saved?"
        if panel.runModal() == .OK { cloneOutput = panel.url }
    }

    // MARK: Run

    func start() {
        guard let disk = selectedDisk, canStart else { return }
        logLines.removeAll()
        resultText = nil
        phase = .running
        progress = 0
        statusText = "Starting…"
        let mode = self.mode
        let eject = ejectWhenDone, verify = verifyAfterWrite
        let helper = helperURL
        let image = imageURL
        let nt5 = isoInfo?.isNT5 ?? false
        let winOpts = image.map {
            FlashOptions(iso: $0, disk: disk, label: label, scheme: scheme, ejectWhenDone: eject, verify: verify,
                         biosBoot: biosBoot, customization: (customization.isEmpty || nt5) ? nil : customization, helper: helper,
                         disableACPI: disableACPI && nt5, nt5Drivers: nt5 ? driverFolder : nil)
        }
        let quick = quickTest, cloneTo = cloneOutput

        task = Task {
            do {
                let onProgress: ProgressHandler = { [weak self] f, msg in Task { @MainActor in self?.update(f, msg) } }
                let onLog: LogHandler = { [weak self] line in Task { @MainActor in self?.appendLog(line) } }
                switch mode {
                case .windows:
                    guard let winOpts else { return }
                    try await Flasher.flash(winOpts, progress: onProgress, log: onLog)
                    finish("Done", eject ? "Done — you can remove the drive." : "Done")
                case .dd:
                    guard let helper, let image else { throw FlashError.message("Couldn't locate the write helper inside the app.") }
                    try await RawFlasher.flash(
                        RawFlashOptions(image: image, disk: disk, verify: verify, ejectWhenDone: eject, helper: helper),
                        progress: onProgress, log: onLog)
                    finish("Done", eject ? "Done — you can remove the drive." : "Done")
                case .test:
                    guard let helper else { throw FlashError.message("Couldn't locate the helper inside the app.") }
                    try await DiskService.verifySafeTarget(disk)
                    onLog("Requesting administrator permission to test \(disk.device)")
                    let out = try await AdminJob.run(helper: helper,
                                                     arguments: ["badblocks", disk.id, "--yes"] + (quick ? ["--quick"] : [])) { phase, done, total in
                        let f = Double(done) / Double(max(total, 1))
                        onProgress(phase == "write" ? 0.02 + 0.48 * f : 0.5 + 0.48 * f,
                                   (phase == "write" ? "Writing test data… " : "Reading it back… ") + "\(ByteFormat.string(done)) of \(ByteFormat.string(total))")
                    }
                    let r = Self.parseTestResult(out)
                    resultText = r.text
                    onLog(r.text)
                    finish(r.ok ? "Drive test passed" : "Drive test FAILED", r.ok ? "Drive test passed" : "Problems found – see below", failed: !r.ok)
                    if !r.ok { phase = .failed(r.text) }
                case .clone:
                    guard let helper, let cloneTo else { throw FlashError.message("Choose where to save the image first.") }
                    try await DiskService.verifySafeTarget(disk)
                    let free = (try? cloneTo.deletingLastPathComponent().resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                        .volumeAvailableCapacityForImportantUsage ?? Int64.max
                    if free < disk.size { throw FlashError.message("Not enough free space for the image (\(ByteFormat.string(disk.size)) needed).") }
                    onLog("Requesting administrator permission to read \(disk.device)")
                    _ = try await AdminJob.run(helper: helper,
                                               arguments: ["clone", disk.id, cloneTo.path, "--uid", String(getuid()), "--yes"]) { _, done, total in
                        onProgress(0.02 + 0.96 * Double(done) / Double(max(total, 1)),
                                   "Copying drive… \(ByteFormat.string(done)) of \(ByteFormat.string(total))")
                    }
                    onLog("Saved \(cloneTo.path)")
                    finish("Done", "Saved \(cloneTo.lastPathComponent)")
                }
            } catch is CancellationError {
                phase = .cancelled
                statusText = "Cancelled — the drive may be incomplete."
            } catch {
                phase = .failed(error.localizedDescription)
                statusText = "Failed"
                appendLog("ERROR: \(error.localizedDescription)")
                Notifier.post(title: "Jupiter Flasher: failed", body: error.localizedDescription)
            }
            task = nil
            await refreshDisks()
        }
    }

    private func finish(_ title: String, _ status: String, failed: Bool = false) {
        phase = .finished
        statusText = status
        progress = 1
        NSSound(named: failed ? "Basso" : "Glass")?.play()
        Notifier.post(title: failed ? "Jupiter Flasher: problem" : "Jupiter Flasher: \(title)", body: status)
    }

    /// Parses "RESULT bad=0 total=64 first=- write=40 read=41 quick=0".
    static func parseTestResult(_ out: String) -> (ok: Bool, text: String) {
        guard let line = out.split(separator: "\n").last(where: { $0.hasPrefix("RESULT ") }) else {
            return (false, "The test didn't report a result.")
        }
        var kv: [String: String] = [:]
        for part in line.dropFirst(7).split(separator: " ") {
            let p = part.split(separator: "=", maxSplits: 1)
            if p.count == 2 { kv[String(p[0])] = String(p[1]) }
        }
        let bad = Int(kv["bad"] ?? "") ?? -1, total = Int(kv["total"] ?? "") ?? 0
        let result = DriveTestResult(totalBlocks: total, badBlocks: max(bad, 0), firstBadOffset: kv["first"].flatMap { Int64($0) },
                                     writeMBps: Double(kv["write"] ?? "") ?? 0, readMBps: Double(kv["read"] ?? "") ?? 0,
                                     quick: kv["quick"] == "1")
        return (bad == 0, bad < 0 ? "The test result was unreadable." : result.summary)
    }

    func cancel() {
        statusText = "Cancelling…"
        task?.cancel()
    }

    private func update(_ f: Double, _ msg: String) {
        guard isRunning else { return }
        progress = max(progress, f)
        statusText = msg
    }

    private func appendLog(_ line: String) {
        logLines.append(line)
        if logLines.count > 2000 { logLines.removeFirst(500) }
    }
}
