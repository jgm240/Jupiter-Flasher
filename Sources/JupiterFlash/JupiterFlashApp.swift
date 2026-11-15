// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI
import AppKit

@main
struct JupiterFlashApp: App {
    @StateObject private var model = FlashViewModel()

    init() {
        // Lets the app come to the front even when launched as a bare executable (swift run).
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        // A single window; ISOs dropped on the Dock icon or opened with the app land in it.
        Window("Jupiter Flasher", id: "main") {
            ContentView()
                .environmentObject(model)
                .frame(minWidth: 540, idealWidth: 580, minHeight: 660)
                .onOpenURL { model.openFile($0) }
        }
        .windowResizability(.contentSize)
    }
}
