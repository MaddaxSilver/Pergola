import SwiftUI

/// Time-synced lyrics from LRCLIB (lrclib.net: free, no account, community-maintained).
@Observable @MainActor
final class Lyrics {
    struct Line: Identifiable, Equatable {
        let id: Int
        let time: Double
        let text: String
    }

    private(set) var lines: [Line] = []
    private(set) var plain: String?
    private(set) var loading = false
    /// Changes with every new song, so views can cross-fade from one song's lyrics to the next.
    private(set) var songID = 0
    /// Only true once a lookup has taken a while, so a quick one doesn't flash "Finding lyrics…".
    private(set) var searching = false
    @ObservationIgnored private var trackKey = ""
    @ObservationIgnored private var cache: [String: ([Line], String?)] = [:]

    var hasSynced: Bool { !lines.isEmpty }

    /// Index of the line being sung at `position` seconds: allowing for the time sound takes to reach
    /// your ears on the current output (AirPods lag ~0.2 s), plus the user's own sync offset.
    func index(at position: Double) -> Int? {
        guard !lines.isEmpty else { return nil }
        let t = position - OutputDevices.currentLatency + Prefs.d.double(forKey: Prefs.lyricsOffsetMs) / 1000
        var lo = 0, hi = lines.count - 1, found: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    @ObservationIgnored private var failedAt: [String: Date] = [:]

    func load(title: String, artist: String, album: String, duration: Double) {
        // Music briefly reports a title with no artist while switching tracks: wait for both.
        guard !title.isEmpty, !artist.isEmpty else { return }
        let key = "\(artist)|\(title)"
        if key == trackKey {
            // Retry a lookup that failed (offline, timeout) after 30 s instead of giving up for good.
            guard !loading, lines.isEmpty, plain == nil,
                  let failed = failedAt[key], Date().timeIntervalSince(failed) > 30 else { return }
        }
        if key != trackKey { songID += 1 }
        trackKey = key
        searching = false
        if let cached = cache[key] { lines = cached.0; plain = cached.1; loading = false; return }
        lines = []; plain = nil
        loading = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.trackKey == key, self.loading else { return }
            self.searching = true
        }
        Task {
            let result = await Self.fetch(title: title, artist: artist, album: album, duration: duration)
            guard key == trackKey else { return }
            lines = result.lines
            plain = result.plain
            loading = false
            searching = false
            if result.definitive { cache[key] = (result.lines, result.plain); failedAt[key] = nil }
            else { failedAt[key] = Date() }
        }
    }

    /// `definitive` is false when the lookup couldn't reach LRCLIB, so it gets retried later.
    private static func fetch(title: String, artist: String, album: String, duration: Double) async
        -> (lines: [Line], plain: String?, definitive: Bool) {
        struct R: Decodable { let syncedLyrics: String?; let plainLyrics: String?; let duration: Double?; let instrumental: Bool? }
        var reached = false
        func get(_ path: String, _ items: [URLQueryItem]) async -> Data? {
            var c = URLComponents(string: "https://lrclib.net/api/\(path)")!
            c.queryItems = items
            var req = URLRequest(url: c.url!)
            req.setValue("Pergola (macOS notch app)", forHTTPHeaderField: "User-Agent")
            req.timeoutInterval = 10
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return nil }
            reached = true
            return (resp as? HTTPURLResponse)?.statusCode == 200 ? data : nil
        }
        func has(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        // 1. Exact match (title, artist, album, length).
        var items: [URLQueryItem] = [.init(name: "track_name", value: title), .init(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(.init(name: "album_name", value: album)) }
        if duration > 0 { items.append(.init(name: "duration", value: String(Int(duration.rounded())))) }
        var plainFallback: String?
        if let d = await get("get", items), let r = try? JSONDecoder().decode(R.self, from: d) {
            if has(r.syncedLyrics) { return (parse(r.syncedLyrics), r.plainLyrics, true) }
            if has(r.plainLyrics) { plainFallback = r.plainLyrics }
        }
        // 2. Search, so a different release of the same song (single, remix album…) can supply synced
        //    lyrics. Prefer synced results whose length is closest to this track's.
        for query in [[URLQueryItem(name: "track_name", value: title), .init(name: "artist_name", value: artist)],
                      [URLQueryItem(name: "q", value: "\(title) \(artist)")]] {
            guard let d = await get("search", query), let rs = try? JSONDecoder().decode([R].self, from: d), !rs.isEmpty else { continue }
            let synced = rs.filter { has($0.syncedLyrics) }
            // A release more than a few seconds longer or shorter (radio edit, extended intro) has its
            // lines at different times, so it would run early or late: only accept close matches.
            let close = synced.filter { duration <= 0 || abs(($0.duration ?? duration) - duration) <= 5 }
            if let best = close.min(by: { abs(($0.duration ?? 0) - duration) < abs(($1.duration ?? 0) - duration) }) {
                return (parse(best.syncedLyrics), best.plainLyrics, true)
            }
            if plainFallback == nil { plainFallback = rs.first(where: { has($0.plainLyrics) })?.plainLyrics }
        }
        return ([], plainFallback, reached)
    }

    /// Parses LRC: "[mm:ss.xx] text", including lines with several timestamps.
    static func parse(_ lrc: String?) -> [Line] {
        guard let lrc else { return [] }
        var out: [(Double, String)] = []
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:[.:]\d+)?)\]"#)
        for raw in lrc.components(separatedBy: .newlines) {
            let line = String(raw)
            let ns = line as NSString
            let matches = stamp.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard let last = matches.last else { continue }
            let text = ns.substring(from: last.range.location + last.range.length).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let sec = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: ":", with: ".")
                let t = (Double(ns.substring(with: m.range(at: 1))) ?? 0) * 60 + (Double(sec) ?? 0)
                out.append((t, text))
            }
        }
        return out.sorted { $0.0 < $1.0 }.enumerated().map { Line(id: $0.offset, time: $0.element.0, text: $0.element.1) }
    }
}

/// Scrolling synced lyrics: the current line bright, neighbours dimmed and softly blurred, gliding
/// with a spring, like Apple Music. Every line is laid out at its natural height, so long lines wrap
/// in full instead of being cut off. Songs with only unsynced lyrics show them as a scrollable page.
struct SyncedLyricsView: View {
    var lyrics: Lyrics
    var player: NowPlaying
    var fontSize: CGFloat = 22
    var visibleLines = 5
    var centered = false

    private var height: CGFloat { fontSize * 1.9 * CGFloat(visibleLines) }

    var body: some View {
        ZStack {
            Group {
                if lyrics.hasSynced {
                    TimelineView(.animation(minimumInterval: 1.0 / 20, paused: !player.isPlaying)) { ctx in
                        // Only `current` changes between ticks; LyricLines is Equatable, so the list itself
                        // is only re-rendered when the sung line actually moves.
                        LyricLines(lines: lyrics.lines, current: lyrics.index(at: player.currentPosition(at: ctx.date)),
                                   fontSize: fontSize, centered: centered, height: height)
                            .equatable()
                    }
                } else if let plain = lyrics.plain, !plain.isEmpty {
                    ScrollView(.vertical, showsIndicators: false) {
                        Text(plain)
                            .font(.system(size: fontSize * 0.8, weight: .semibold))
                            .lineSpacing(fontSize * 0.35)
                            .foregroundStyle(.white.opacity(0.75))
                            .multilineTextAlignment(centered ? .center : .leading)
                            .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                            .padding(.vertical, height * 0.2)
                    }
                } else {
                    Text(lyrics.loading ? (lyrics.searching ? "Finding lyrics…" : " ") : "No lyrics for this song")
                        .font(.system(size: fontSize * 0.6, weight: .medium))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: centered ? .center : .leading)
                }
            }
            // One song's lyrics fade out as the next song's fade in, instead of a hard cut.
            .id(lyrics.songID)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                                    removal: .opacity.combined(with: .offset(y: -10))))
        }
        .animation(.easeInOut(duration: 0.4), value: lyrics.songID)
        .animation(.easeOut(duration: 0.35), value: lyrics.hasSynced)
        .animation(.easeOut(duration: 0.35), value: lyrics.searching)
        .frame(height: height)
        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.16),
                                     .init(color: .black, location: 0.84), .init(color: .clear, location: 1)],
                             startPoint: .top, endPoint: .bottom))
    }
}

/// The synced lines as one column that glides so the sung line sits in the middle. Each line's
/// position is measured once; moving to the next line is a single spring on the column's offset (a
/// plain transform the GPU animates smoothly), not a scroll-view scroll. Lines fade with distance
/// instead of blurring, since re-blurring big text on every frame of the glide made it stutter.
private struct LyricLines: View, Equatable {
    let lines: [Lyrics.Line]
    let current: Int?
    let fontSize: CGFloat
    let centered: Bool
    let height: CGFloat
    @State private var mids: [Int: CGFloat] = [:]
    @State private var ready = false

    static func == (a: Self, b: Self) -> Bool {
        a.current == b.current && a.fontSize == b.fontSize && a.centered == b.centered && a.height == b.height && a.lines == b.lines
    }

    var body: some View {
        let target = mids[current ?? 0] ?? 0
        VStack(alignment: centered ? .center : .leading, spacing: fontSize * 0.62) {
            ForEach(lines) { line in
                let isCurrent = line.id == current
                let distance = Double(abs(line.id - (current ?? -1)))
                Text(line.text.isEmpty ? "♪" : line.text)
                    .font(.system(size: fontSize, weight: .bold))
                    .multilineTextAlignment(centered ? .center : .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .named("lyricColumn")).midY } action: { mids[line.id] = $0 }
                    .foregroundStyle(.white.opacity(isCurrent ? 1 : max(0.16, 0.46 - distance * 0.07)))
                    // Lines well outside the window aren't drawn at all (a whole song is 60+ lines).
                    .opacity(distance > 7 ? 0 : 1)
                    .scaleEffect(isCurrent ? 1 : 0.96, anchor: centered ? .center : .leading)
                    .animation(.spring(duration: 0.6, bounce: 0.08), value: isCurrent)
            }
        }
        .coordinateSpace(.named("lyricColumn"))
        .offset(y: height / 2 - target)
        .animation(ready ? .spring(duration: 0.75, bounce: 0.08) : nil, value: target)
        .frame(height: height, alignment: .top)
        .clipped()
        // Hidden until the lines are measured, so a new song never shows at the wrong spot first.
        .opacity(ready ? 1 : 0)
        .onChange(of: mids.isEmpty, initial: true) { _, empty in
            guard !empty, !ready else { return }
            DispatchQueue.main.async { withAnimation(.easeOut(duration: 0.3)) { ready = true } }
        }
    }
}
