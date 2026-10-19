import SwiftUI

/// The menu bar dropdown: current setup, last snapshot, manual actions and known configurations.
struct MenuContentView: View {
    @EnvironmentObject private var manager: LayoutManager

    var body: some View {
        if !manager.isTrusted {
            Button("⚠️ Accessibility access needed — Grant…") { manager.requestAccessibility() }
            Divider()
        }

        Text("Setup: \(manager.configuration.name)")
        if let snapshot = manager.currentSnapshot {
            Text("Last snapshot: \(snapshot.savedAt.formatted(date: .omitted, time: .shortened)) · \(snapshot.windows.count) windows")
        } else {
            Text("No saved layout yet")
        }
        if let message = manager.lastMessage {
            Text(message)
        }

        Divider()

        Button("Save Now") { manager.saveNow() }
            .keyboardShortcut("s")
            .disabled(!manager.isTrusted)
        Button("Restore Now") { manager.restoreNow() }
            .keyboardShortcut("r")
            .disabled(!manager.canRestore)

        Menu("Known Configurations") {
            if manager.snapshots.isEmpty {
                Text("None yet")
            }
            ForEach(manager.snapshots) { snapshot in
                Menu(label(for: snapshot)) {
                    Text("\(snapshot.windows.count) windows · saved \(snapshot.savedAt.formatted(date: .abbreviated, time: .shortened))")
                    Button("Delete", role: .destructive) { manager.delete(snapshot) }
                }
            }
        }

        Divider()

        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Support / Donate ❤️") { Links.openDonation() }
        Button("Quit DisplayLayoutKeeper") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func label(for snapshot: LayoutSnapshot) -> String {
        let current = snapshot.signature == manager.configuration.signature ? " (current)" : ""
        return "\(snapshot.name) — \(snapshot.detail)\(current)"
    }
}
