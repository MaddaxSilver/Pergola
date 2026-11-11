import SwiftUI
import AppKit

/// Something another app is doing right now, shown in the notch: an export, a scan, a Claude task.
/// Apps post these to Pergola's local API (see INTEGRATIONS.md) or through its MCP server.
struct LiveActivity: Identifiable, Equatable {
    enum State: String { case running, waiting, done, failed }

    var id: String
    var app = ""
    var title = ""
    var detail = ""
    /// 0…1, or nil while the app can't say how far along it is (shown as a spinner).
    var progress: Double?
    var symbol = "bolt.fill"
    var tintHex: String?
    var bundleID: String?
    var state = State.running
    var started = Date()
    var updated = Date()
    /// Seconds without an update before a running activity is assumed dead and removed.
    var ttl: Double = 600
    /// When a finished activity leaves the notch.
    var removeAt: Date?

    /// Several goals drawn as concentric rings (an app's daily targets, say) instead of one progress ring.
    var rings: [GoalRing] = []
    /// Arrives and updates without a caption under the notch.
    var quiet = false
    /// A Claude Code session's transcript file: its writes count as signs of life, and it shows when
    /// the session was interrupted (which no hook reports).
    var transcript: String?
    /// The app to bring forward when the task is clicked (a terminal running Claude Code, say), when
    /// that isn't the app whose icon it wears.
    var opens: String?

    /// A countdown: when it reaches zero the activity finishes by itself.
    var endsAt: Date?
    /// How long the countdown was set for, so the ring can show how much is left.
    var total: Double?
    /// A count-up: a call, a recording, anything where "how long so far" is the point.
    var since: Date?
    /// Play a sound when the countdown ends (Pergola's own timers; Clock rings its own).
    var chime = false
    /// Made by Pergola from something it watches (a call, a Clock timer): never saved, since it is found again.
    var transient = false

    /// Showing a running clock instead of a progress ring.
    var hasClock: Bool { state == .running && (endsAt != nil || since != nil) }

    /// What a click opens: the app named for it, else the one whose icon shows, else the AI tool's own app.
    var appToOpen: URL? {
        let ids = [opens, bundleID] + (AIBrand.match(app).map { $0.bundleIDs + ($0.name == "Claude" ? ["com.anthropic.claudefordesktop"] : []) } ?? [])
        return ids.compactMap { $0 }.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
    }

    var finished: Bool { state == .done || state == .failed }
    /// Standing information rather than a task: it gives way to real tasks beside the closed notch.
    var ambient: Bool { !rings.isEmpty && state == .running }
    var tint: Color { tintHex.flatMap(Color.init(hex:)) ?? .white }

    var json: [String: Any] {
        var d: [String: Any] = ["id": id, "app": app, "title": title, "detail": detail, "state": state.rawValue,
                                "symbol": symbol, "started": started.timeIntervalSince1970, "updated": updated.timeIntervalSince1970]
        if let progress { d["progress"] = progress }
        if let tintHex { d["tint"] = tintHex }
        if let bundleID { d["bundle_id"] = bundleID }
        if !rings.isEmpty { d["rings"] = rings.map(\.json) }
        if quiet { d["quiet"] = true }
        if let endsAt { d["ends_at"] = endsAt.timeIntervalSince1970 }
        if let total { d["total"] = total }
        if let since { d["since"] = since.timeIntervalSince1970 }
        if chime { d["chime"] = true }
        return d
    }
}

/// AI tools Pergola recognises by name, so each gets its own mark in the notch without sending one:
/// its real app icon when the app is installed, otherwise a symbol in its colour.
struct AIBrand {
    var name: String
    /// Lower-case fragments looked for in the activity's `app` (or the MCP client's name).
    var keys: [String]
    var symbol: String
    var tint: String
    var bundleIDs: [String] = []

    static let all: [AIBrand] = [
        AIBrand(name: "Claude", keys: ["claude", "anthropic"], symbol: "sparkle", tint: "#D97757"),
        AIBrand(name: "ChatGPT", keys: ["chatgpt", "openai", "codex", "gpt"], symbol: "circle.hexagongrid.fill", tint: "#19C37D",
                bundleIDs: ["com.openai.chat", "com.openai.codex"]),
        AIBrand(name: "Gemini", keys: ["gemini", "google", "bard"], symbol: "sparkles", tint: "#5B9BFF",
                bundleIDs: ["com.google.GeminiMacOS"]),
        AIBrand(name: "Cursor", keys: ["cursor"], symbol: "cursorarrow.rays", tint: "#E8E8E8",
                bundleIDs: ["com.todesktop.230313mzl4w4u92"]),
        AIBrand(name: "Windsurf", keys: ["windsurf", "codeium"], symbol: "wind", tint: "#2DD4BF",
                bundleIDs: ["com.exafunction.windsurf"]),
        AIBrand(name: "Copilot", keys: ["copilot", "github", "visual studio code", "vscode"], symbol: "chevron.left.forwardslash.chevron.right", tint: "#A78BFA",
                bundleIDs: ["com.microsoft.copilot-mac"]),
        AIBrand(name: "Grok", keys: ["grok", "xai"], symbol: "bolt.horizontal.fill", tint: "#E8E8E8"),
        AIBrand(name: "Perplexity", keys: ["perplexity"], symbol: "asterisk", tint: "#22B8CD",
                bundleIDs: ["ai.perplexity.mac"]),
        AIBrand(name: "Mistral", keys: ["mistral", "le chat"], symbol: "flame.fill", tint: "#FA6B1E"),
        AIBrand(name: "DeepSeek", keys: ["deepseek"], symbol: "water.waves", tint: "#6C8BFF"),
        AIBrand(name: "Ollama", keys: ["ollama", "llama", "lm studio", "lmstudio", "local model"], symbol: "desktopcomputer", tint: "#E8E8E8",
                bundleIDs: ["com.electron.ollama", "ai.elementlabs.lmstudio"]),
    ]

    static func match(_ app: String) -> AIBrand? {
        let name = app.lowercased()
        guard !name.isEmpty else { return nil }
        return all.first { $0.keys.contains { name.contains($0) } }
    }

    /// The brand's own app, when it's on this Mac. (Claude keeps its spark rather than an app icon.)
    var installedBundleID: String? {
        bundleIDs.first { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    }
}

/// One ring of a set: how far something is toward its goal.
struct GoalRing: Identifiable, Equatable {
    var label = ""
    /// What to print beside it, e.g. "$4.20 / $10".
    var value = ""
    /// 1 is the goal. Past 1 the ring stays full; below 0 it runs backwards in red.
    var progress: Double = 0
    var tintHex: String?

    var id: String { label }
    var tint: Color { tintHex.flatMap(Color.init(hex:)) ?? .white }
    var met: Bool { progress >= 1 }

    init?(_ d: [String: Any]) {
        guard let p = (d["progress"] as? NSNumber)?.doubleValue, p.isFinite else { return nil }
        progress = min(9, max(-9, p))
        label = (d["label"] as? String).map { String($0.prefix(40)) } ?? ""
        value = (d["value"] as? String).map { String($0.prefix(40)) } ?? ""
        tintHex = (d["tint"] as? String).map { String($0.prefix(9)) }
    }

    var json: [String: Any] {
        var d: [String: Any] = ["label": label, "value": value, "progress": progress]
        if let tintHex { d["tint"] = tintHex }
        return d
    }
}

extension Color {
    /// "#FF8800" or "FF8800".
    init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(red: Double((v >> 16) & 0xFF) / 255, green: Double((v >> 8) & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
    }
}

@Observable @MainActor
final class Activities {
    private(set) var items: [LiveActivity] = []
    /// Called when an activity starts, finishes, or starts waiting on you: worth a caption under the notch.
    @ObservationIgnored var onAnnounce: ((LiveActivity) -> Void)?
    @ObservationIgnored var onCountChange: ((Int) -> Void)?

    /// The one shown beside the closed notch: whatever just finished, else the most recently updated.
    /// Goal rings never show there; they only have their own page in the open notch.
    var current: LiveActivity? {
        items.filter(\.finished).max { $0.updated < $1.updated }
            // Then a call, then the timer that ends soonest, then whatever was touched last.
            ?? items.filter { $0.state == .running && $0.since != nil }.max { $0.updated < $1.updated }
            ?? items.filter { $0.state == .running && $0.endsAt != nil }.min { $0.endsAt! < $1.endsAt! }
            ?? items.filter { !$0.ambient }.max { $0.updated < $1.updated }
    }

    /// Creates or updates an activity. Fields left out keep their previous value, so an app can send
    /// just `{"id": …, "progress": 0.4}` as it goes.
    @discardableResult
    func upsert(_ d: [String: Any]) -> LiveActivity? {
        guard let id = (d["id"] as? String).flatMap({ $0.isEmpty ? nil : String($0.prefix(120)) }) else { return nil }
        let existing = items.firstIndex { $0.id == id }
        var a = existing.map { items[$0] } ?? LiveActivity(id: id)
        let before = a
        func text(_ key: String, _ limit: Int) -> String? { (d[key] as? String).map { String($0.prefix(limit)) } }
        if let v = text("app", 60) { a.app = v }
        if let v = text("title", 120) { a.title = v }
        if let v = text("detail", 200) { a.detail = v }
        if let v = text("symbol", 60), NSImage(systemSymbolName: v, accessibilityDescription: nil) != nil { a.symbol = v }
        if let v = text("tint", 9) { a.tintHex = v }
        if let v = text("bundle_id", 200) { a.bundleID = v }
        if let v = (d["ttl"] as? NSNumber)?.doubleValue { a.ttl = min(86_400, max(5, v)) }
        if let v = (d["state"] as? String).flatMap(LiveActivity.State.init(rawValue:)) { a.state = v }
        if let v = d["rings"] as? [[String: Any]] { a.rings = Array(v.compactMap(GoalRing.init).prefix(4)) }
        if let v = d["quiet"] as? Bool { a.quiet = v }
        if let v = text("opens", 200) { a.opens = v }
        // Clocks: "timer" counts down from now, "ends_at" to a moment; "elapsed"/"since" count up.
        if let v = (d["timer"] as? NSNumber)?.doubleValue, v > 0 {
            a.endsAt = Date().addingTimeInterval(min(v, 86_400 * 7)); a.total = v; a.since = nil
            if d["chime"] == nil, existing == nil { a.chime = true }
        }
        if let v = (d["ends_at"] as? NSNumber)?.doubleValue { a.endsAt = Date(timeIntervalSince1970: v); a.since = nil }
        if let v = (d["total"] as? NSNumber)?.doubleValue, v > 0 { a.total = v }
        if let v = (d["since"] as? NSNumber)?.doubleValue { a.since = Date(timeIntervalSince1970: v); a.endsAt = nil }
        if d["elapsed"] as? Bool == true, a.since == nil { a.since = Date(); a.endsAt = nil }
        if let v = d["chime"] as? Bool { a.chime = v }
        if let v = d["transient"] as? Bool { a.transient = v }
        // A clock keeps itself alive: it needs no updates to stay in the notch.
        if let end = a.endsAt, d["ttl"] == nil { a.ttl = max(a.ttl, end.timeIntervalSinceNow + 120) }
        if a.since != nil, d["ttl"] == nil { a.ttl = max(a.ttl, 86_400) }
        if let v = d["transcript"] as? String, v.hasSuffix(".jsonl"),
           v.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.path + "/.claude/") { a.transcript = v }
        if d["progress"] is NSNull { a.progress = nil }
        if let v = (d["progress"] as? NSNumber)?.doubleValue { a.progress = min(1, max(0, v > 1 ? v / 100 : v)) }
        if let step = (d["step"] as? NSNumber)?.doubleValue, let total = (d["total_steps"] as? NSNumber)?.doubleValue, total > 0 {
            a.progress = min(1, max(0, step / total))
        }
        // A known AI tool that sent no look of its own gets its mark.
        if existing == nil || d["app"] != nil, let brand = AIBrand.match(a.app) {
            if d["symbol"] == nil, existing == nil || before.app != a.app { a.symbol = brand.symbol }
            if d["tint"] == nil, a.tintHex == nil || before.app != a.app { a.tintHex = brand.tint }
            if d["bundle_id"] == nil, a.bundleID == nil || before.app != a.app { a.bundleID = brand.installedBundleID }
        }
        if a.title.isEmpty { a.title = a.app.isEmpty ? "Working" : a.app }
        a.updated = Date()
        heartbeat[id] = nil
        if a.finished {
            if a.state == .done, a.progress != nil { a.progress = 1 }
            a.removeAt = Date().addingTimeInterval(5)
        } else {
            a.removeAt = nil
        }
        withAnimation(.spring(duration: 0.45, bounce: 0.12)) {
            if let existing { items[existing] = a } else { items.append(a) }
        }
        onCountChange?(items.count)
        if !restoring {
            save()
            if !a.quiet, existing == nil || (before.state != a.state && a.state != .running) { onAnnounce?(a) }
        }
        return a
    }

    @discardableResult
    func remove(id: String) -> Bool {
        guard items.contains(where: { $0.id == id }) else { return false }
        withAnimation(.spring(duration: 0.45, bounce: 0.1)) { items.removeAll { $0.id == id } }
        heartbeat[id] = nil
        onCountChange?(items.count)
        save()
        return true
    }

    func removeAll() {
        guard !items.isEmpty else { return }
        withAnimation(.spring(duration: 0.45, bounce: 0.1)) { items.removeAll() }
        onCountChange?(0)
        save()
    }

    /// Drops finished activities after their moment, and running ones whose app went quiet.
    func prune() {
        guard !items.isEmpty else { return }
        let now = Date()
        if now.timeIntervalSince(lastTranscriptCheck) >= 2 {
            lastTranscriptCheck = now
            checkTranscripts()
        }
        // Countdowns that have run out finish themselves, with a tick (and a chime for Pergola's own).
        for a in items where a.state == .running {
            guard let end = a.endsAt, now >= end else { continue }
            if a.chime { NSSound(named: "Glass")?.play() }
            upsert(["id": a.id, "state": "done", "detail": "Time’s up"])
        }
        let stale = items.filter {
            ($0.removeAt.map { now >= $0 } ?? false) || now.timeIntervalSince(max($0.updated, heartbeat[$0.id] ?? .distantPast)) > $0.ttl
        }
        for a in stale { remove(id: a.id) }
    }

    // MARK: Claude sessions

    /// Last time each session's transcript was written to, when that's newer than its last hook.
    @ObservationIgnored private var heartbeat: [String: Date] = [:]
    @ObservationIgnored private var lastTranscriptCheck = Date.distantPast

    /// Claude Code reports nothing when you press Esc, so an interrupted session would sit in the notch
    /// as "running" until it timed out. Its transcript does record it, so look there.
    private func checkTranscripts() {
        for a in items where !a.finished {
            guard let path = a.transcript,
                  let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date,
                  modified > a.updated, modified != heartbeat[a.id] else { continue }
            heartbeat[a.id] = modified
            if Self.wasInterrupted(path) { remove(id: a.id) }
        }
    }

    /// True when the last thing said in the transcript is Claude Code's "[Request interrupted by user…]" note.
    static func wasInterrupted(_ path: String) -> Bool {
        guard let file = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        try? file.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        guard let tail = try? file.readToEnd() else { return false }
        for line in tail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = entry["type"] as? String, type == "user" || type == "assistant" else { continue }
            guard type == "user", let content = (entry["message"] as? [String: Any])?["content"] else { return false }
            let texts = (content as? String).map { [$0] }
                ?? (content as? [[String: Any]])?.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String } ?? []
            return texts.contains { $0.hasPrefix("[Request interrupted by user") }
        }
        return false
    }

    // MARK: Surviving a relaunch

    @ObservationIgnored private var restoring = false
    private static var storeURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pergola/activities.json")
    }

    /// Tasks still running are written down, so quitting and reopening Pergola doesn't lose them.
    private func save() {
        let live = items.filter { !$0.finished && !$0.transient }.map { a -> [String: Any] in
            var d = a.json
            d["ttl"] = a.ttl
            if let t = a.transcript { d["transcript"] = t }
            if let o = a.opens { d["opens"] = o }
            return d
        }
        guard let data = try? JSONSerialization.data(withJSONObject: live) else { return }
        try? FileManager.default.createDirectory(at: Self.storeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.storeURL, options: .atomic)
    }

    /// Brings back the tasks that were running when Pergola last quit, unless they've since gone quiet.
    func restore() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let saved = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return }
        restoring = true
        defer { restoring = false }
        for d in saved {
            guard let updated = (d["updated"] as? NSNumber)?.doubleValue, let id = d["id"] as? String else { continue }
            let ttl = (d["ttl"] as? NSNumber)?.doubleValue ?? 600
            guard Date().timeIntervalSince1970 - updated < ttl, upsert(d) != nil,
                  let i = items.firstIndex(where: { $0.id == id }) else { continue }
            items[i].updated = Date(timeIntervalSince1970: updated)
            if let started = (d["started"] as? NSNumber)?.doubleValue { items[i].started = Date(timeIntervalSince1970: started) }
        }
    }
}

// MARK: - Views

/// The activity's app icon when it gave a bundle ID, otherwise its SF Symbol.
struct ActivityGlyph: View {
    var activity: LiveActivity
    var size: CGFloat

    var body: some View {
        if let id = activity.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable().interpolation(.high)
                // App icons carry their own margin, so they need more room than a symbol to look the same size.
                .frame(width: size * 1.65, height: size * 1.65)
        } else {
            Image(systemName: activity.symbol)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: size * 1.15, weight: .semibold))
                .foregroundStyle(activity.tint)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

/// Progress as a ring: fills as the work advances, spins while the amount is unknown, and turns into
/// a tick or a cross at the end.
/// The running time of a countdown ("4:59") or a call ("12:07"), ticking by itself.
struct ActivityClock: View {
    var activity: LiveActivity
    var size: CGFloat

    var body: some View {
        Group {
            if let end = activity.endsAt {
                Text(timerInterval: Date.now...max(end, Date.now.addingTimeInterval(1)), countsDown: true)
            } else if let since = activity.since {
                Text(since, style: .timer)
            }
        }
        .font(.system(size: size, weight: .semibold).monospacedDigit())
        .foregroundStyle(activity.tint)
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }
}

struct ActivityRing: View {
    var activity: LiveActivity
    var size: CGFloat = 16
    var lineWidth: CGFloat = 2.6

    var body: some View {
        if activity.ambient {
            GoalRings(rings: activity.rings, size: size + 4)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            single
        }
    }

    private var single: some View {
        ZStack {
            Circle().stroke(.white.opacity(0.18), lineWidth: lineWidth)
            switch activity.state {
            case .done:
                Circle().stroke(Color.green, lineWidth: lineWidth)
                Image(systemName: "checkmark").font(.system(size: size * 0.48, weight: .heavy)).foregroundStyle(.green)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .failed:
                Circle().stroke(Color.red, lineWidth: lineWidth)
                Image(systemName: "xmark").font(.system(size: size * 0.46, weight: .heavy)).foregroundStyle(.red)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
            case .waiting:
                Circle().stroke(Color.orange.opacity(0.9), lineWidth: lineWidth)
                Circle().fill(.orange).frame(width: size * 0.3, height: size * 0.3)
                    .phaseAnimator([0.45, 1.0]) { dot, o in dot.opacity(o) } animation: { _ in .easeInOut(duration: 0.8) }
            case .running where !activity.rings.isEmpty:
                EmptyView()
            case .running where activity.endsAt != nil && (activity.total ?? 0) > 0:
                // A countdown drains its ring; one redraw a second is plenty.
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    let left = max(0, activity.endsAt!.timeIntervalSince(ctx.date)) / activity.total!
                    Circle().trim(from: 0, to: min(1, max(0.02, left)))
                        .stroke(activity.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: left)
                }
            case .running where activity.since != nil:
                // A call has no "how far": a soft pulsing dot says it is live.
                Circle().fill(activity.tint).frame(width: size * 0.36, height: size * 0.36)
                    .phaseAnimator([0.5, 1.0]) { dot, o in dot.opacity(o) } animation: { _ in .easeInOut(duration: 0.9) }
            case .running:
                if let p = activity.progress {
                    Circle().trim(from: 0, to: max(0.03, p))
                        .stroke(activity.tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.spring(duration: 0.6, bounce: 0), value: p)
                } else {
                    Spinner(tint: activity.tint, lineWidth: lineWidth)
                }
            }
        }
        .frame(width: size, height: size)
        .animation(.spring(duration: 0.4, bounce: 0.25), value: activity.state)
    }
}

/// Concentric goal rings, outermost first: each fills clockwise from twelve o'clock toward its goal,
/// or runs backwards in red when it's below where it started.
struct GoalRings: View {
    var rings: [GoalRing]
    var size: CGFloat

    var body: some View {
        let n = CGFloat(max(rings.count, 1))
        let gap = max(0.8, size * 0.03)
        let lw = min(size * 0.17, (size / 2 - gap * (n - 1)) / n * 0.9)
        ZStack {
            ForEach(Array(rings.enumerated()), id: \.element.id) { i, r in
                let d = max(lw, size - CGFloat(i) * 2 * (lw + gap) - lw)
                ZStack {
                    Circle().stroke(r.tint.opacity(0.26), lineWidth: lw)
                    Circle().trim(from: 0, to: min(1, abs(r.progress)))
                        .stroke(r.progress < 0 ? Color(red: 1, green: 0.35, blue: 0.33) : r.tint,
                                style: StrokeStyle(lineWidth: lw, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .scaleEffect(x: r.progress < 0 ? -1 : 1, y: 1)
                        .opacity(abs(r.progress) > 0.004 ? 1 : 0)
                        .animation(.spring(duration: 0.8, bounce: 0), value: r.progress)
                }
                .frame(width: d, height: d)
            }
        }
        .frame(width: size, height: size)
    }
}

private struct Spinner: View {
    var tint: Color
    var lineWidth: CGFloat
    @State private var turning = false

    var body: some View {
        Circle().trim(from: 0, to: 0.3)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(turning ? 360 : 0))
            .animation(.linear(duration: 0.9).repeatForever(autoreverses: false), value: turning)
            .onAppear { turning = true }
    }
}

/// The Activity page of the open notch: one row per running task.
struct ActivitiesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Goal rings have their own page.
        let items = model.activities.items.filter { !$0.ambient }.sorted { $0.started < $1.started }
        VStack(spacing: 7) {
            if items.isEmpty {
                Text("Nothing Running")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let shown = Array(items.suffix(NotchUI.maxTaskRows))
                ForEach(shown) { a in
                    ActivityRow(activity: a)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                }
                if items.count > shown.count {
                    Text("+\(items.count - shown.count) more")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// An app's goal rings with their numbers: the rings on the left, one line per ring beside them.
/// The newest few tasks as compact rows, shown above the file tray so both share one page.
struct ActivityStack: View {
    @Environment(AppModel.self) private var model
    var limit: Int

    var body: some View {
        let items = model.activities.items.filter { !$0.ambient }.sorted { $0.started < $1.started }.suffix(limit)
        VStack(spacing: 7) {
            ForEach(Array(items)) { a in
                ActivityRow(activity: a)
                    .transition(.opacity.combined(with: .scale(scale: 0.94)))
            }
        }
    }
}

/// The Rings page: one app's goal rings drawn large, with each goal's name and figures beside them.
struct RingsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let activity = model.activities.items.last(where: \.ambient) {
            HStack(spacing: 18) {
                GoalRings(rings: activity.rings, size: 88)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Text(activity.title)
                            .font(.system(size: 13, weight: .semibold))
                        Spacer(minLength: 6)
                        Text(activity.detail)
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.5))
                            .contentTransition(.numericText())
                    }
                    .lineLimit(1)
                    ForEach(activity.rings.prefix(3)) { r in
                        HStack(spacing: 7) {
                            Circle().fill(r.tint).frame(width: 7, height: 7)
                            Text(r.label)
                                .font(.system(size: 12.5, weight: .semibold))
                                .lineLimit(1)
                            Spacer(minLength: 6)
                            Text(r.value)
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .foregroundStyle(r.progress < 0 ? Color(red: 1, green: 0.45, blue: 0.42) : .white.opacity(r.met ? 0.95 : 0.6))
                                .lineLimit(1)
                                .contentTransition(.numericText())
                            if r.met {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 9, weight: .heavy))
                                    .foregroundStyle(r.tint)
                            }
                        }
                    }
                }
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeOut(duration: 0.3), value: activity.rings)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(activity.title + ": " + activity.rings.map { "\($0.label) \($0.value)" }.joined(separator: ", "))
        }
    }
}

private struct ActivityRow: View {
    var activity: LiveActivity
    @State private var hovering = false
    private var target: URL? { activity.appToOpen }

    private var status: String {
        switch activity.state {
        case .done: "Done"
        case .failed: "Failed"
        case .waiting: "Waiting"
        case .running: activity.progress.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ActivityGlyph(activity: activity, size: 15)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(activity.title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .lineLimit(1)
                if !activity.detail.isEmpty {
                    Text(activity.detail)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            Spacer(minLength: 6)
            if activity.hasClock {
                ActivityClock(activity: activity, size: 12)
            } else {
                Text(status)
                    .font(.system(size: 11, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .contentTransition(.numericText())
            }
            ActivityRing(activity: activity, size: 18)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering && target != nil ? 0.08 : 0)))
        .padding(.horizontal, -5).padding(.vertical, -2)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            // Click a task to jump to the app doing it.
            guard let target else { return }
            NSWorkspace.shared.openApplication(at: target, configuration: NSWorkspace.OpenConfiguration())
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .animation(.easeOut(duration: 0.25), value: activity.detail)
        .animation(.easeOut(duration: 0.25), value: status)
    }
}
