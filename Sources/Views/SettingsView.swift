import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings window: timing, auto-restore, launch at login, permissions and excluded apps.
struct SettingsView: View {
    @EnvironmentObject private var manager: LayoutManager
    @AppStorage(SettingsKey.autoSaveInterval) private var autoSaveInterval = 60.0
    @AppStorage(SettingsKey.restoreDelay) private var restoreDelay = 3.0
    @AppStorage(SettingsKey.autoRestore) private var autoRestore = true
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?
    @State private var selectedApp: String?

    var body: some View {
        Form {
            Section("Behaviour") {
                Stepper(value: $autoSaveInterval, in: 10...600, step: 10) {
                    LabeledContent("Auto-save every", value: "\(Int(autoSaveInterval)) s")
                }
                Stepper(value: $restoreDelay, in: 0...30, step: 1) {
                    LabeledContent("Restore delay after display change", value: "\(Int(restoreDelay)) s")
                }
                Toggle("Automatically restore when displays change", isOn: $autoRestore)
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        loginError = LoginItem.set(newValue)
                        launchAtLogin = LoginItem.isEnabled
                    }
                if let loginError {
                    Text("Could not change login item: \(loginError)").foregroundStyle(.red).font(.caption)
                }
            }

            Section("Permissions") {
                if manager.isTrusted {
                    Label("Accessibility access granted", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
                } else {
                    Label("Accessibility access is required to read and move windows. Restore is disabled until it is granted.",
                          systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Button("Open Accessibility Settings…") { manager.requestAccessibility() }
                }
                Text("Window titles are read through Accessibility, so no Screen Recording permission is needed. Minimized windows and windows on other Spaces can't be reached and are skipped.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Excluded Apps") {
                List(manager.excludedApps, id: \.self, selection: $selectedApp) { bundleID in
                    Text(appName(for: bundleID))
                }
                .frame(minHeight: 100)
                HStack {
                    Button { addApp() } label: { Image(systemName: "plus") }
                    Button {
                        if let selectedApp { manager.excludedApps.removeAll { $0 == selectedApp } }
                        selectedApp = nil
                    } label: { Image(systemName: "minus") }
                    .disabled(selectedApp == nil)
                    Spacer()
                    Text("Excluded apps are never saved or moved.").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    Text("DisplayLayoutKeeper is free and open source.")
                    Spacer()
                    Button("Support / Donate ❤️") { Links.openDonation() }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 600)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Exclude"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        var list = manager.excludedApps
        for url in panel.urls {
            if let id = Bundle(url: url)?.bundleIdentifier, !list.contains(id) { list.append(id) }
        }
        manager.excludedApps = list
    }

    private func appName(for bundleID: String) -> String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        return "\(FileManager.default.displayName(atPath: url.path)) (\(bundleID))"
    }
}
