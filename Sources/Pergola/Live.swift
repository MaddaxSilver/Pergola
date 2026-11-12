import AppKit
import CoreAudio
import SQLite3

/// Things Pergola notices by itself and shows like the Dynamic Island does: a call and how long
/// you've been on it, and timers running in the Clock app.
@MainActor
final class LiveWatcher {
    private let activities: Activities
    private var lastCalls = Date.distantPast
    private var lastTimers = Date.distantPast

    init(activities: Activities) { self.activities = activities }

    /// Called often; each check paces itself.
    func tick() {
        let now = Date()
        if now.timeIntervalSince(lastCalls) >= 2 {
            lastCalls = now
            checkCall()
        }
        if now.timeIntervalSince(lastTimers) >= 1 {
            lastTimers = now
            checkClockTimers()
        }
    }

    // MARK: Calls

    /// Apps whose use of the microphone means a call. Matched by prefix, so helper processes count.
    /// macOS has no public "is there a call" API, but Core Audio does say which app is listening.
    nonisolated private static let callApps: [(prefix: String, name: String, bundleID: String)] = [
        ("com.apple.avconferenced", "FaceTime", "com.apple.FaceTime"),
        ("com.apple.FaceTime", "FaceTime", "com.apple.FaceTime"),
        ("com.apple.TelephonyUtilities", "FaceTime", "com.apple.FaceTime"),
        ("us.zoom.xos", "Zoom", "us.zoom.xos"),
        ("com.microsoft.teams", "Teams", "com.microsoft.teams2"),
        ("com.cisco.webexmeetingsapp", "Webex", "com.cisco.webexmeetingsapp"),
        ("Cisco-Systems.Spark", "Webex", "Cisco-Systems.Spark"),
        ("com.hnc.Discord", "Discord", "com.hnc.Discord"),
        ("com.tinyspeck.slackmacgap", "Slack", "com.tinyspeck.slackmacgap"),
        ("net.whatsapp.WhatsApp", "WhatsApp", "net.whatsapp.WhatsApp"),
        ("org.whispersystems.signal-desktop", "Signal", "org.whispersystems.signal-desktop"),
        ("com.skype.skype", "Skype", "com.skype.skype"),
        ("ru.keepcoder.Telegram", "Telegram", "ru.keepcoder.Telegram"),
        ("com.facebook.archon", "Messenger", "com.facebook.archon"),
    ]
    /// Browsers: their use of the microphone is only a call if a tab is on a call site (it may just
    /// as well be dictation), so the open tabs are checked, by AppleScript, only while they listen.
    nonisolated private static let browsers: [(prefix: String, app: String, bundleID: String)] = [
        ("com.google.Chrome", "Google Chrome", "com.google.Chrome"),
        ("company.thebrowser.Browser", "Arc", "company.thebrowser.Browser"),
        ("com.microsoft.edgemac", "Microsoft Edge", "com.microsoft.edgemac"),
        ("com.brave.Browser", "Brave Browser", "com.brave.Browser"),
        ("com.vivaldi.Vivaldi", "Vivaldi", "com.vivaldi.Vivaldi"),
        ("com.apple.Safari", "Safari", "com.apple.Safari"),
        ("com.apple.WebKit", "Safari", "com.apple.Safari"),
    ]
    /// Call sites, matched against the host and path of each open tab.
    nonisolated private static let callSites: [(match: String, name: String)] = [
        ("meet.google.com/", "Meet"),
        ("zoom.us/wc", "Zoom"), ("app.zoom.us/wc", "Zoom"),
        ("teams.microsoft.com", "Teams"), ("teams.live.com", "Teams"),
        ("discord.com/channels", "Discord"),
        ("app.slack.com/huddle", "Slack"),
        ("facetime.apple.com", "FaceTime"),
        ("whereby.com/", "Whereby"),
        ("webex.com/", "Webex"),
        ("meet.jit.si/", "Jitsi"),
        ("web.whatsapp.com", "WhatsApp"),
        ("messenger.com/", "Messenger"),
    ]
    static let callID = "pergola-call"
    private var callApp: String?
    private var misses = 0

    private func checkCall() {
        guard Prefs.d.bool(forKey: Prefs.callTimer), Prefs.d.bool(forKey: Prefs.activitiesEnabled) else {
            if callApp != nil { endCall() }
            return
        }
        // Core Audio can take a moment to answer; ask off the main thread so no frame ever waits on it.
        guard !asking else { return }
        asking = true
        let current = callApp
        let lastSite = lastSiteCheck
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let listening = Self.bundleIDsUsingMicrophone()
            var found = Self.callApps.first { app in listening.contains { $0.hasPrefix(app.prefix) } }
                .map { (name: $0.name, bundleID: $0.bundleID) }
            var checkedSites = false
            if found == nil, let browser = Self.browsers.first(where: { b in listening.contains { $0.hasPrefix(b.prefix) } }) {
                // Asking the browser costs a little, so once a call is known it's re-checked less often.
                let due = Date().timeIntervalSince(lastSite) >= (current == nil ? 2 : 10)
                if !due, let current {
                    found = (name: current, bundleID: browser.bundleID)
                } else if let site = Self.callSite(in: browser.app) {
                    checkedSites = true
                    found = (name: site, bundleID: browser.bundleID)
                } else {
                    checkedSites = true
                }
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.asking = false
                    if checkedSites { self.lastSiteCheck = Date() }
                    self.heard(found)
                }
            }
        }
    }

    private var asking = false
    private var lastSiteCheck = Date.distantPast

    /// The call site open in one of the browser's tabs, if any. Runs `osascript` so a slow or
    /// unanswered browser can never hold anything up; gives up after two seconds.
    nonisolated private static func callSite(in app: String) -> String? {
        let script = app == "Safari"
            ? "tell application \"Safari\" to get URL of every tab of every window"
            : "tell application \"\(app)\" to get URL of every tab of every window"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "if application \"\(app)\" is running then", "-e", script, "-e", "end if"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?.lowercased() ?? ""
        return callSites.first { text.contains($0.match) }?.name
    }

    private func heard(_ found: (name: String, bundleID: String)?) {
        if let found {
            misses = 0
            guard callApp != found.name else { return }
            callApp = found.name
            activities.upsert(["id": Self.callID, "app": found.name, "title": found.name, "detail": "On a call",
                               "symbol": "phone.fill", "tint": "#30D158", "bundle_id": found.bundleID,
                               "elapsed": true, "transient": true, "state": "running"])
        } else if callApp != nil {
            // Two quiet checks in a row, so a momentary mute or device switch doesn't end the clock.
            misses += 1
            if misses >= 2 { endCall() }
        }
    }

    private func endCall() {
        callApp = nil
        misses = 0
        activities.remove(id: Self.callID)
    }

    /// Bundle IDs of every process currently taking audio input.
    nonisolated static func bundleIDsUsingMicrophone() -> [String] {
        var list = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &list, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &list, 0, nil, &size, &ids) == noErr else { return [] }
        var result: [String] = []
        for id in ids {
            var running = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var on: UInt32 = 0
            var onSize = UInt32(MemoryLayout<UInt32>.size)
            guard AudioObjectGetPropertyData(id, &running, 0, nil, &onSize, &on) == noErr, on != 0 else { continue }
            var bundle = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                    mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var name: Unmanaged<CFString>?
            var nameSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &bundle, 0, nil, &nameSize, &name) == noErr, let name else { continue }
            result.append(name.takeRetainedValue() as String)
        }
        return result
    }

    // MARK: Clock timers

    nonisolated private static let clockStore = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Group Containers/group.com.apple.mobiletimerd/local.sqlite").path
    private var clockStamp: Date?
    private var clockIDs: Set<String> = []
    private var lastFullRead = Date.distantPast

    /// The Clock app keeps its timers in a small database. Read it when it changes (and now and then
    /// regardless), and mirror the running ones.
    private func checkClockTimers() {
        guard Prefs.d.bool(forKey: Prefs.clockTimers), Prefs.d.bool(forKey: Prefs.activitiesEnabled) else {
            for id in clockIDs { activities.remove(id: id) }
            clockIDs = []
            return
        }
        let fm = FileManager.default
        let stamp = [Self.clockStore, Self.clockStore + "-wal"]
            .compactMap { (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date }.max()
        guard stamp != clockStamp || Date().timeIntervalSince(lastFullRead) > 15 else { return }
        clockStamp = stamp
        lastFullRead = Date()

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let timers = Self.readClockTimers()
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.mirror(timers) } }
        }
    }

    private func mirror(_ timers: [ClockTimer]) {
        var running: Set<String> = []
        for t in timers where t.fires > Date() {
            let id = "clock-\(t.key)"
            running.insert(id)
            // Only re-post when it is new or its end moved (paused and resumed, or time added).
            if let old = activities.items.first(where: { $0.id == id }), let end = old.endsAt, abs(end.timeIntervalSince(t.fires)) < 1.5, !old.finished { continue }
            activities.upsert(["id": id, "app": "Clock", "title": t.title, "symbol": "timer", "tint": "#FF9F0A",
                               "opens": "com.apple.clock", "ends_at": t.fires.timeIntervalSince1970, "total": t.duration,
                               "chime": false, "transient": true, "state": "running"])
        }
        // Stopped, paused or deleted in Clock: gone from the notch (ones that ran out show their tick first).
        for id in clockIDs.subtracting(running) where activities.items.first(where: { $0.id == id })?.finished != true {
            activities.remove(id: id)
        }
        clockIDs = running
    }

    private struct ClockTimer: Sendable { var key: String; var title: String; var duration: Double; var fires: Date }

    nonisolated private static func readClockTimers() -> [ClockTimer] {
        var db: OpaquePointer?
        guard sqlite3_open_v2(clockStore, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT Z_PK, ZTITLE, ZDURATION, ZFIRETIME FROM ZMTCDTIMER", -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var timers: [ClockTimer] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let key = String(sqlite3_column_int64(statement, 0))
            var title = sqlite3_column_text(statement, 1).map { String(cString: $0) } ?? ""
            if title.isEmpty || title == "CURRENT_TIMER" { title = "Timer" }
            let duration = sqlite3_column_double(statement, 2)
            guard let bytes = sqlite3_column_blob(statement, 3) else { continue }
            let blob = Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, 3)))
            guard let fires = fireDate(in: blob) else { continue }
            timers.append(ClockTimer(key: key, title: title, duration: duration, fires: fires))
        }
        return timers
    }

    /// A running timer archives the moment it will fire; a stopped or paused one only an interval.
    /// Pull the date out of the keyed archive without needing Clock's private classes.
    nonisolated private static func fireDate(in archive: Data) -> Date? {
        guard let plist = try? PropertyListSerialization.propertyList(from: archive, format: nil) as? [String: Any],
              let objects = plist["$objects"] as? [Any] else { return nil }
        for case let object as [String: Any] in objects {
            if let t = object["NS.time"] as? Double { return Date(timeIntervalSinceReferenceDate: t) }
        }
        return nil
    }
}

/// "90", "45s", "5m", "1h30m", "1:30" (minutes:seconds) → seconds.
enum DurationText {
    static func seconds(_ text: String) -> Double? {
        let t = text.lowercased().trimmingCharacters(in: .whitespaces)
        if let plain = Double(t) { return plain > 0 ? plain : nil }
        if t.contains(":") {
            let parts = t.split(separator: ":").compactMap { Double($0) }
            guard parts.count == t.split(separator: ":").count, (2...3).contains(parts.count) else { return nil }
            let total = parts.reduce(0) { $0 * 60 + $1 }
            return total > 0 ? total : nil
        }
        var total = 0.0, number = ""
        for c in t {
            if c.isNumber || c == "." { number.append(c); continue }
            guard let n = Double(number), let unit = ["h": 3600.0, "m": 60.0, "s": 1.0][c] else { return nil }
            total += n * unit; number = ""
        }
        return number.isEmpty && total > 0 ? total : nil
    }

    /// 300 → "5 min", 5400 → "1 hr 30 min".
    static func spoken(_ s: Double) -> String {
        let n = Int(s.rounded())
        let (h, m, sec) = (n / 3600, (n % 3600) / 60, n % 60)
        return [h > 0 ? "\(h) hr" : nil, m > 0 ? "\(m) min" : nil, sec > 0 && h == 0 ? "\(sec) sec" : nil]
            .compactMap { $0 }.joined(separator: " ")
    }
}
