import AppKit
import SwiftUI

/// Entry point: a menu-bar-only app with a Settings window.
@main
struct DisplayLayoutKeeperApp: App {
    @StateObject private var manager = LayoutManager()

    var body: some Scene {
        MenuBarExtra("DisplayLayoutKeeper", systemImage: "display.2") {
            MenuContentView()
                .environmentObject(manager)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
                .environmentObject(manager)
        }
    }
}

/// Shared links used by several views.
enum Links {
    static func openDonation() {
        NSWorkspace.shared.open(URL(string: "https://ko-fi.com/leodavidai")!)
    }
}
