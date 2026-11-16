// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import UniformTypeIdentifiers
import JupiterFlashCore

struct ContentView: View {
    @EnvironmentObject var m: FlashViewModel
    @State private var confirmErase = false
    @State private var showLog = false
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section { modePicker }
                if m.needsImage { Section("Boot selection") { isoSection } }
                Section("Device") { deviceSection }
                if m.mode == .clone { Section("Save image as") { cloneSection } }
                if m.mode != .clone { Section(m.mode == .test ? "Test options" : "Drive properties") { propertiesSection } }
                if m.mode == .windows, m.isoInfo?.isNT5 != true { Section("Windows customization") { customizationSection } }
                Section("Status") { statusSection }
            }
            .formStyle(.grouped)
            .disabled(m.isRunning)
            .opacity(m.isRunning ? 0.75 : 1)

            bottomBar
        }
        .alert(m.mode == .clone ? "Copy \(m.selectedDisk?.name ?? "drive")?" : "Erase \(m.selectedDisk?.name ?? "drive")?", isPresented: $confirmErase) {
            if m.mode == .clone {
                Button("Clone") { m.start() }
            } else {
                Button(m.mode == .test ? "Erase and Test" : "Erase and Flash", role: .destructive) { m.start() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let d = m.selectedDisk {
                Text(m.mode == .clone
                     ? "The whole drive “\(d.name)” (\(d.id), \(ByteFormat.string(d.size))) will be read into an image file. Nothing on the drive is changed."
                     : "ALL DATA on “\(d.name)” (\(d.id), \(ByteFormat.string(d.size))) will be destroyed. This cannot be undone.")
            }
        }
    }

    // MARK: Sections

    private var modePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Mode", selection: $m.mode) {
                ForEach(FlashMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(modeDescription)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modeDescription: String {
        switch m.mode {
        case .windows: return "Copies a Windows installer onto a FAT32 drive (splits files over 4 GB)."
        case .dd: return "Writes an image byte-for-byte, for hybrid ISOs (Linux, etc.) and disk images. Asks for your administrator password."
        case .test: return "Checks a drive for bad blocks and fake capacity by writing and reading back test data. Destroys everything on the drive. Asks for your administrator password."
        case .clone: return "Saves a complete copy of a drive to an image file (the reverse of DD mode). Nothing on the drive changes. Asks for your administrator password."
        }
    }

    private var isoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: m.imageURL == nil ? "opticaldisc" : "opticaldisc.fill")
                    .foregroundStyle(.secondary)
                Text(m.imageURL?.lastPathComponent
                     ?? (m.mode == .windows ? "Drop a Windows ISO here, or click SELECT" : "Drop an ISO or IMG here, or click SELECT"))
                    .foregroundStyle(m.imageURL == nil ? .secondary : .primary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                if !m.recents.isEmpty {
                    Menu("Recent") {
                        ForEach(m.recents, id: \.self) { url in Button(url.lastPathComponent) { m.setImage(url) } }
                        Divider()
                        Button("Clear menu") { m.clearRecents() }
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                }
                Button("SELECT") { m.chooseImage() }
            }
            if m.isInspecting {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Reading ISO…").foregroundStyle(.secondary) }
                    .font(.callout)
            } else if m.mode == .windows, let info = m.isoInfo, info.isWindowsInstaller {
                Label(info.summary, systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green).font(.callout)
                if info.needsSplit {
                    Text("install.wim is over 4 GB, so it will be split to fit on FAT32.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if info.isNT5 {
                    Text("\(info.windowsName ?? "This Windows") has no built-in AHCI or USB 3.0 drivers: set the PC's SATA mode to IDE/Compatible and use a USB 2.0 port. The drive needs about twice the size of the CD (setup files are stored twice).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if info.isVistaOr7 {
                    Text("\(info.windowsName ?? "This Windows") has no built-in USB 3.0 drivers – if the installer can't see the keyboard or the drive, use a USB 2.0 port. Legacy BIOS boot is the most reliable option."
                         + (info.needsUEFIFiles ? " UEFI boot files will be added from install.wim." : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if info.isWindows8 {
                    Text("\(info.windowsName ?? "Windows 8") boots from this drive in UEFI or legacy BIOS mode. Windows 8 has its own USB 3.0 drivers, so any port works.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if info.isLTSCOrIoT {
                    Text(info.isIoT
                         ? "IoT Enterprise (LTSC) editions have relaxed hardware requirements, so the Windows 11 requirement bypass is usually not needed. If Setup still complains, turn it on below."
                         : "LTSC media: a long-term-servicing edition without the Store and most bundled apps.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if m.mode == .dd, let raw = m.rawInfo {
                Label(raw.summary, systemImage: raw.looksBootableRaw ? "checkmark.seal.fill" : "info.circle.fill")
                    .foregroundStyle(raw.looksBootableRaw ? .green : .secondary).font(.callout)
            }
            if let e = m.imageError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange).font(.callout)
            }
            if m.imageURL != nil { checksumView }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(dropTargeted ? Color.accentColor : .clear))
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first(where: { ["iso", "img"].contains($0.pathExtension.lowercased()) }) else { return false }
            m.openFile(u); return true
        } isTargeted: { dropTargeted = $0 }
    }

    private var checksumView: some View {
        DisclosureGroup("Check the download (MD5 / SHA-1 / SHA-256)") {
            VStack(alignment: .leading, spacing: 6) {
                TextField("Paste the expected hash from the download page (optional)", text: $m.expectedHash)
                    .font(.system(.caption, design: .monospaced))
                HStack {
                    Picker("Algorithm", selection: $m.hashAlgorithm) {
                        ForEach(HashAlgorithm.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 210)
                    Button(m.hashState == .idle ? "Calculate" : "Recalculate") { m.computeHash() }
                        .disabled({ if case .computing = m.hashState { return true } else { return false } }())
                    switch m.hashState {
                    case .idle: EmptyView()
                    case .computing(let f): ProgressView(value: f).frame(maxWidth: 160)
                    case .failed(let e): Text(e).font(.caption).foregroundStyle(.red)
                    case .done(let alg, _):
                        if let ok = m.hashMatches {
                            Label(ok ? "Matches" : "DOES NOT MATCH – don't use this file",
                                  systemImage: ok ? "checkmark.seal.fill" : "xmark.octagon.fill")
                                .foregroundStyle(ok ? .green : .red).font(.callout)
                        } else if let want = m.expectedParsed {
                            Text("The pasted hash is \(want.algorithm.displayName) but this one is \(alg.displayName) – press Recalculate.")
                                .font(.caption).foregroundStyle(.orange)
                        } else if !m.expectedHash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("That doesn't contain exactly one MD5, SHA-1 or SHA-256 hash.").font(.caption).foregroundStyle(.orange)
                        }
                    }
                }
                if case .done(let alg, let h) = m.hashState {
                    Text("\(alg.displayName): \(h)").font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                    if alg.isWeak, m.hashMatches == true {
                        Text("\(alg.displayName) only proves the file isn't corrupted – it can't rule out tampering. Use the SHA-256 when the publisher offers one.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private var cloneSection: some View {
        HStack {
            Image(systemName: m.cloneOutput == nil ? "doc" : "doc.fill").foregroundStyle(.secondary)
            Text(m.cloneOutput?.path ?? "Choose where to save the image")
                .foregroundStyle(m.cloneOutput == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("CHOOSE") { m.chooseCloneOutput() }
        }
    }

    private var deviceSection: some View {
        Group {
            HStack {
                Picker("Device", selection: $m.selectedDiskID) {
                    if m.disks.isEmpty { Text("No USB drive found").tag(String?.none) }
                    ForEach(m.disks) { d in Text(d.displayName).tag(Optional(d.id)) }
                }
                Button { Task { await m.refreshDisks() } } label: { Image(systemName: "arrow.clockwise") }
                    .help("Refresh drive list")
            }
            Toggle("List external hard drives and SSDs", isOn: $m.includeFixedDrives)
            if m.includeFixedDrives {
                Text("Be careful: this also shows backup and data drives.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var propertiesSection: some View {
        Group {
            if m.mode == .test {
                Toggle("Quick test (samples across the whole drive, takes a minute)", isOn: $m.quickTest)
                Text(m.quickTest
                     ? "Good at spotting fake-capacity drives. Untick for a full pass over every block, which takes as long as writing the whole drive twice."
                     : "Full test: writes and reads back every block. Can take hours on large drives.")
                    .font(.caption).foregroundStyle(.secondary)
                if let r = m.resultText {
                    Label(r, systemImage: m.phase == .finished ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .font(.callout).foregroundStyle(m.phase == .finished ? .green : .red)
                }
            } else if m.mode == .windows {
                TextField("Volume label", text: $m.label)
                    .onSubmit { m.label = Flasher.sanitizeLabel(m.label) }
                Picker("Partition scheme", selection: $m.scheme) {
                    ForEach(PartitionScheme.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(m.isoInfo?.isNT5 == true)
                if m.scheme == .gpt {
                    Label("GPT adds an extra empty 200 MB EFI partition to the stick, which can confuse Windows Setup (for example, boot files written to the wrong drive). MBR still boots on UEFI PCs and is recommended.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                }
                LabeledContent("File system", value: "FAT32 (UEFI bootable)")
                if m.isoInfo?.isNT5 == true {
                    Label("\(m.isoInfo?.windowsName ?? "This Windows") boots in legacy BIOS mode only. Jupiter Flasher uses its own boot loader (MBR scheme) and will ask for your administrator password.",
                          systemImage: "info.circle.fill")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Disable ACPI (fixes “BIOS is not fully ACPI compliant” on newer PCs)", isOn: $m.disableACPI)
                    if m.disableACPI {
                        Text("Installs the generic \"Standard PC\" HAL, the same as pressing F7 during setup. Windows will use one CPU core and can't power the PC off by itself.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text(m.driverFolder.map { "Storage driver: \($0.lastPathComponent)" } ?? "Storage (AHCI/RAID) driver: none")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        if m.driverFolder != nil { Button("Remove") { m.setDriverFolder(nil) } }
                        Button("Choose folder…") { m.chooseDriverFolder() }
                    }
                    if let e = m.driverError {
                        Label(e, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    } else if let pack = m.driverPack {
                        Text("Will be loaded automatically by Setup (no F6 needed): \(pack.descriptions.joined(separator: ", "))")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Optional. Pick the folder of an XP text-mode (F6) driver, e.g. Intel AHCI/RAID, so Setup sees drives when the PC is in AHCI mode.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                Toggle("Also boot on legacy BIOS PCs (CSM)", isOn: $m.biosBoot)
                    .disabled(m.isoInfo?.supportsBIOSBoot != true)
                if m.biosBoot {
                    Text("Uses the MBR scheme and writes Windows boot code to the drive's boot sectors. You'll be asked for your administrator password.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if let info = m.isoInfo, info.isWindowsInstaller, !info.supportsBIOSBoot {
                    Text("This ISO has no legacy boot files (for example ARM64 media), so it can only boot in UEFI mode.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                }
            } else {
                Text("The drive's partitions are replaced by whatever the image contains. Expect the drive to look empty or unreadable in macOS afterwards.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if m.mode != .test {
                Toggle("Verify after writing (slower, recommended)", isOn: $m.verifyAfterWrite)
                Toggle("Eject when finished", isOn: $m.ejectWhenDone)
            }
        }
    }

    private var customizationSection: some View {
        let region = RegionSettings.current
        let info = m.isoInfo            // nil until an ISO is read: then show everything
        let showHW = info?.hasHardwareChecks ?? true
        let showAccount = info?.hasOnlineAccountScreens ?? true
        let showBitLocker = info?.hasDeviceEncryption ?? true
        let effective = info.map { m.customization.applicable(to: $0).options } ?? m.customization
        return Group {
            if showHW { Toggle("Remove Windows 11 hardware requirements (TPM, Secure Boot, RAM, CPU)", isOn: $m.customization.bypassHardwareChecks) }
            if showAccount {
                Toggle("Skip Microsoft account and network setup (local account)", isOn: $m.customization.skipOnlineAccount)
                if m.customization.skipOnlineAccount {
                    TextField("Local user name (optional)", text: $m.customization.localAccountName)
                    if let problem = m.accountNameProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                    } else {
                        Text("The account is created without a password – set one after installing.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Toggle("Skip privacy questions", isOn: $m.customization.skipPrivacyQuestions)
            if showBitLocker { Toggle("Don't automatically encrypt the drive with BitLocker", isOn: $m.customization.disableBitLocker) }
            Toggle("Use this Mac's region and time zone", isOn: $m.customization.useMacRegion)
            if m.customization.useMacRegion {
                Text("Will set: language/region \(region.locale ?? "not mapped, skipped") · time zone \(region.timeZone ?? "not mapped, skipped")")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let info, !(showHW && showAccount && showBitLocker) {
                Text("Options that don't exist in \(info.windowsName ?? "this Windows") are hidden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !effective.isEmpty {
                Text("Saved as autounattend.xml on the drive, which Windows Setup reads automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: m.progress)
            HStack {
                Text(m.statusText).lineLimit(2)
                    .foregroundStyle(statusColor)
                Spacer()
                Text("\(Int(m.progress * 100))%").monospacedDigit().foregroundStyle(.secondary)
            }
            if case .failed(let msg) = m.phase {
                Text(msg).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            DisclosureGroup("Log", isExpanded: $showLog) {
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(m.logLines.joined(separator: "\n"))
                            .font(.system(.caption, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(height: 110)
                    .onChange(of: m.logLines.count) { _ in proxy.scrollTo("end") }
                }
            }
        }
    }

    private var statusColor: Color {
        switch m.phase {
        case .finished: return .green
        case .failed: return .red
        default: return .primary
        }
    }

    private var bottomBar: some View {
        HStack {
            Text(m.mode == .windows
                 ? (m.biosBoot ? "Boots on UEFI and legacy BIOS PCs." : "UEFI boot. Turn on legacy BIOS for older PCs.")
                 : "You'll be asked for your administrator password.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            if m.isRunning {
                Button("CANCEL", role: .cancel) { m.cancel() }
            } else {
                Button(m.startTitle) { confirmErase = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!m.canStart)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 12)
    }
}
