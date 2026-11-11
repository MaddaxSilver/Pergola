import SwiftUI
import EventKit

/// Upcoming events from every calendar on this Mac: iCloud, Google, Exchange and anything else
/// added under System Settings › Internet Accounts.
@Observable @MainActor
final class Agenda {
    struct Event: Identifiable, Equatable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let allDay: Bool
        let color: Color
        let calendar: String
        let location: String?
        let joinURL: URL?
    }

    private(set) var events: [Event] = []
    private(set) var calendars: [(id: String, title: String, color: Color, source: String)] = []
    private(set) var status: EKAuthorizationStatus = EKEventStore.authorizationStatus(for: .event)

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var started = false

    static let stripDays = 7

    var hasAccess: Bool { status == .fullAccess }

    /// Events that touch the given day (multi-day events show on each day they cover).
    func events(on day: Date) -> [Event] {
        let start = Calendar.current.startOfDay(for: day)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return events.filter { $0.start < end && $0.end > start }
    }

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
        reload()
    }

    func requestAccess() {
        Task {
            _ = try? await store.requestFullAccessToEvents()
            status = EKEventStore.authorizationStatus(for: .event)
            reload()
        }
    }

    func reload() {
        status = EKEventStore.authorizationStatus(for: .event)
        guard hasAccess else { events = []; calendars = []; return }

        let all = store.calendars(for: .event)
        calendars = all.map { ($0.calendarIdentifier, $0.title, Color(nsColor: $0.color ?? .systemBlue), $0.source?.title ?? "") }
            .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
        let hidden = Set(Prefs.d.stringArray(forKey: Prefs.calendarHidden) ?? [])
        let shown = all.filter { !hidden.contains($0.calendarIdentifier) }
        guard !shown.isEmpty else { events = []; return }

        // The page's week strip always needs seven days, whatever the look-ahead is set to.
        let days = max(Agenda.stripDays, Prefs.d.integer(forKey: Prefs.calendarDays))
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: days, to: start)!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: shown)
        events = store.events(matching: predicate)
            .filter { $0.endDate > Date() } // hide what's already over
            // One sort: by day, all-day events first within a day, then by start time.
            .sorted {
                let d0 = Calendar.current.startOfDay(for: $0.startDate), d1 = Calendar.current.startOfDay(for: $1.startDate)
                return (d0, $0.isAllDay ? 0 : 1, $0.startDate) < (d1, $1.isAllDay ? 0 : 1, $1.startDate)
            }
            .map { e in
                Event(id: e.calendarItemIdentifier + "\(e.startDate.timeIntervalSince1970)", title: e.title ?? "Untitled",
                      start: e.startDate, end: e.endDate, allDay: e.isAllDay,
                      color: Color(nsColor: e.calendar.color ?? .systemBlue), calendar: e.calendar.title,
                      location: e.location?.isEmpty == false ? e.location : nil,
                      joinURL: Self.meetingLink(in: [e.url?.absoluteString, e.location, e.notes]))
            }
    }

    /// Finds a Zoom / Meet / Teams / Webex / FaceTime link in the event's URL, location or notes.
    static func meetingLink(in fields: [String?]) -> URL? {
        let hosts = ["zoom.us", "meet.google.com", "teams.microsoft.com", "teams.live.com", "webex.com", "facetime.apple.com"]
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        for text in fields.compactMap({ $0 }) {
            let ns = text as NSString
            for m in detector?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
                if let url = m.url, let host = url.host?.lowercased(), hosts.contains(where: { host.hasSuffix($0) }) { return url }
            }
        }
        return nil
    }
}

/// The Calendar page: a week strip you can tap through, and that day's events underneath.
struct CalendarPage: View {
    @Environment(AppModel.self) private var model
    @State private var selected = Calendar.current.startOfDay(for: .now)

    private var agenda: Agenda { model.agenda }
    private var today: Date { Calendar.current.startOfDay(for: .now) }
    /// The day shown: the one picked, or today once the picked day has passed.
    private var day: Date { max(selected, today) }

    var body: some View {
        Group {
            if !agenda.hasAccess {
                VStack(spacing: 8) {
                    Image(systemName: "calendar").font(.system(size: 22)).foregroundStyle(.white.opacity(0.5))
                    Text("See your upcoming events here").font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.65))
                    Button("Allow Calendar Access") { agenda.requestAccess() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 12).frame(height: 26)
                        .background(Capsule().fill(.white.opacity(0.14)))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 3) {
                    weekStrip
                    dayEvents
                        .id(day)
                        .transition(.opacity)
                }
                .animation(.easeOut(duration: 0.18), value: day)
            }
        }
        .onAppear {
            agenda.start()
            selected = today // every visit starts on today
        }
    }

    private var weekStrip: some View {
        HStack(spacing: 0) {
            ForEach(0..<Agenda.stripDays, id: \.self) { offset in
                let d = Calendar.current.date(byAdding: .day, value: offset, to: today)!
                DayCell(date: d, isToday: offset == 0, isSelected: d == day,
                        dots: Array(agenda.events(on: d).map(\.color).prefix(3))) {
                    selected = d
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: 54)
    }

    @ViewBuilder private var dayEvents: some View {
        let events = agenda.events(on: day)
        if events.isEmpty {
            Text(day == today ? "Nothing left today" : "Nothing on \(day.formatted(.dateTime.weekday(.wide)))")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 2) {
                    ForEach(events) { EventRow(event: $0, day: day) }
                }
                .padding(.bottom, events.count > 2 ? 12 : 0)
            }
            .scrollIndicators(.never)
            .mask(LinearGradient(stops: [.init(color: .black, location: events.count > 2 ? 0.78 : 1), .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
        }
    }
}

/// One day in the week strip: weekday letter, the date in a circle, and a dot per event (up to three).
private struct DayCell: View {
    var date: Date
    var isToday: Bool
    var isSelected: Bool
    var dots: [Color]
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.weekday(.narrow)))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isToday ? Color.red : .white.opacity(0.45))
                Text(date.formatted(.dateTime.day()))
                    .font(.system(size: 19, weight: isSelected ? .heavy : .semibold).monospacedDigit())
                    .foregroundStyle(isSelected ? (isToday ? .white : .black) : (isToday ? .red : .white.opacity(0.9)))
                    .frame(width: 36, height: 32)
                    .background(
                        Circle()
                            .fill(isSelected ? (isToday ? Color.red : .white) : .white.opacity(hovering ? 0.12 : 0))
                            .frame(width: 32, height: 32))
                HStack(spacing: 2) {
                    ForEach(Array(dots.enumerated()), id: \.offset) { _, c in
                        Circle().fill(c).frame(width: 4, height: 4)
                    }
                }
                .frame(height: 4)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

/// One event on a single line: colour bar, time, title, then "Now", a countdown or a Join button.
private struct EventRow: View {
    var event: Agenda.Event
    var day: Date
    @State private var hovering = false

    private var happeningNow: Bool { !event.allDay && event.start <= .now && event.end > .now }
    /// Minutes until it starts, when that's within the next hour.
    private var startsIn: Int? {
        let m = Int((event.start.timeIntervalSinceNow / 60).rounded(.up))
        return !event.allDay && m > 0 && m <= 60 ? m : nil
    }

    var body: some View {
        HStack(spacing: 8) {
            Capsule().fill(event.color).frame(width: 3, height: 17)
            Text(timeText)
                .font(.system(size: 11.5, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 56, alignment: .leading)
            Text(event.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 4)
            if happeningNow {
                Text("Now")
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(event.color)
            } else if let startsIn {
                Text("in \(startsIn)m")
                    .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
            if let url = event.joinURL, happeningNow || startsIn != nil || hovering {
                Button { NSWorkspace.shared.open(url) } label: {
                    Text("Join")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 9).frame(height: 20)
                        .background(Capsule().fill(Color.green.opacity(0.85)))
                }
                .buttonStyle(PressStyle())
            }
        }
        .padding(.horizontal, 6)
        .frame(height: 23)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.white.opacity(hovering ? 0.07 : 0)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Calendar.app")) }
        .help([event.title, event.location, event.calendar].compactMap { $0 }.joined(separator: " · "))
    }

    private var timeText: String {
        // All-day events, and ones that began before this day, have no start time to show.
        if event.allDay || event.start < day { return "All day" }
        return event.start.formatted(date: .omitted, time: .shortened)
    }
}
