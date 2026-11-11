import AppKit
import ServiceManagement

/// Opens Pergola when you log in, through macOS's own Login Items (System Settings › General ›
/// Login Items). On by default. It's only registered from a copy in an Applications folder: a login
/// item pointing at a build folder breaks as soon as that folder moves or is deleted.
@Observable @MainActor
final class LoginItem {
    static let shared = LoginItem()

    private(set) var status: SMAppService.Status = SMAppService.mainApp.status

    var wanted: Bool { Prefs.d.bool(forKey: Prefs.launchAtLogin) }

    /// Running from /Applications or ~/Applications.
    var isInstalled: Bool {
        let path = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let user = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").standardizedFileURL.path
        return path == "/Applications" || path == user
    }

    func setEnabled(_ on: Bool) {
        Prefs.d.set(on, forKey: Prefs.launchAtLogin)
        apply()
    }

    /// Brings macOS's login item in line with the setting. Called at launch and when the switch changes.
    func apply() {
        defer { status = SMAppService.mainApp.status }
        guard isInstalled else { return }
        let current = SMAppService.mainApp.status
        do {
            if wanted, current != .enabled, current != .requiresApproval {
                try SMAppService.mainApp.register()
            } else if !wanted, current == .enabled || current == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.notch.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refresh() { status = SMAppService.mainApp.status }

    func openLoginItemsSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// Copies this app into /Applications (replacing an older copy), opens the copy and quits this one.
    func moveToApplications() {
        let source = Bundle.main.bundleURL
        let destination = URL(fileURLWithPath: "/Applications/Pergola.app")
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
            try fm.copyItem(at: source, to: destination)
        } catch {
            NSSound.beep()
            Log.notch.error("move to Applications: \(error.localizedDescription, privacy: .public)")
            return
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: config) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
