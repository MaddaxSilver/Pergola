import AppKit
import CoreAudio

/// Watches which Focus mode is on. macOS has no public API for the mode's name, so Pergola reads
/// the Focus database in ~/Library/DoNotDisturb, which needs Full Disk Access.
@Observable @MainActor
final class FocusWatcher {
    struct Mode: Equatable {
        let id: String
        let name: String
        let symbol: String
    }

    private(set) var active: Mode?
    private(set) var hasAccess = false
    @ObservationIgnored var onChange: ((Mode?, Mode?) -> Void)? // new, previous
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastStamp: Date?
    @ObservationIgnored private var started = false

    private let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/DoNotDisturb/DB")

    func start() {
        poll()
        started = true
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func openFullDiskAccessSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }

    private func poll() {
        let file = dir.appendingPathComponent("Assertions.json")
        // Cheap check first: only re-read the database when it has actually changed.
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        if hasAccess, stamp == lastStamp { return }
        guard let data = try? Data(contentsOf: file) else { hasAccess = false; return }
        hasAccess = true
        lastStamp = stamp

        var modeID: String?
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let first = (json["data"] as? [[String: Any]])?.first,
           let records = first["storeAssertionRecords"] as? [[String: Any]] {
            modeID = records.compactMap { ($0["assertionDetails"] as? [String: Any])?["assertionDetailsModeIdentifier"] as? String }.last
        }
        let mode = modeID.map(describe)
        if mode != active {
            let previous = active
            active = mode
            if started { onChange?(mode, previous) }
        }
    }

    private func describe(_ id: String) -> Mode {
        if let data = try? Data(contentsOf: dir.appendingPathComponent("ModeConfigurations.json")),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let configs = (json["data"] as? [[String: Any]])?.first?["modeConfigurations"] as? [String: Any],
           let mode = (configs[id] as? [String: Any])?["mode"] as? [String: Any] {
            return Mode(id: id, name: mode["name"] as? String ?? "Focus", symbol: mode["symbolImageName"] as? String ?? "moon.fill")
        }
        return Mode(id: id, name: id.contains("default") ? "Do Not Disturb" : "Focus", symbol: "moon.fill")
    }
}

/// Fires when the system's audio output changes (e.g. AirPods connect, or you pick a speaker).
@MainActor
final class OutputWatcher {
    var onChange: ((OutputDevice) -> Void)?
    private var last = OutputDevices.current
    private var started = Date()

    func start() {
        started = Date()
        lastName = OutputDevices.all().first(where: { $0.id == last })?.name
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.changed() }
        }
    }

    /// When each device (by name: Bluetooth devices get a new ID each time they re-link) stopped
    /// being the output. One that comes back within 2 minutes (AirPods re-linking, a brief Bluetooth
    /// drop) isn't announced again.
    private var leftAt: [String: Date] = [:]
    private var lastName: String?

    private func changed() {
        let id = OutputDevices.current
        guard id != last else { return }
        last = id
        let device = OutputDevices.all().first(where: { $0.id == id })
        if let lastName { leftAt[lastName] = Date() }
        lastName = device?.name
        guard Date().timeIntervalSince(started) > 2, let device else { return }
        if let gone = leftAt[device.name], Date().timeIntervalSince(gone) < 120 { return }
        onChange?(device)
    }
}
