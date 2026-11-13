import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Pages

enum SettingsPage: String, CaseIterable, Identifiable {
    case general, media, tray, calendar, integrations, shortcuts, sensory, battery, focus, weather, lockScreen, accessories, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .media: "Media"
        case .tray: "File Tray"
        case .calendar: "Calendar"
        case .integrations: "Integrations"
        case .shortcuts: "Shortcuts"
        case .battery: "Battery"
        case .sensory: "Sensory"
        case .focus: "Focus"
        case .lockScreen: "Lock Screen"
        case .weather: "Weather"
        case .accessories: "Accessories"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .media: "play.fill"
        case .tray: "folder.fill"
        case .calendar: "calendar"
        case .integrations: "puzzlepiece.extension.fill"
        case .shortcuts: "keyboard.fill"
        case .battery: "bolt.fill"
        case .sensory: "speaker.wave.2.fill"
        case .focus: "moon.fill"
        case .lockScreen: "lock.fill"
        case .weather: "cloud.fill"
        case .accessories: "airpods"
        case .about: "info.circle.fill"
        }
    }

    /// Extra words the sidebar search matches.
    var keywords: String {
        switch self {
        case .general: "fullscreen capture menu bar glass haptic hover blur waveform login swipe"
        case .media: "player source spotify music shuffle repeat heart favorite color art"
        case .tray: "files drop drag"
        case .calendar: "events google icloud meetings agenda"
        case .integrations: "apps api mcp claude activity progress task hooks rings goals"
        case .shortcuts: "keyboard keys hotkey hot key global open close play pause next previous"
        case .battery: "charger charging overlay"
        case .sensory: "volume brightness hud keys display sound"
        case .focus: "do not disturb dnd overlay"
        case .lockScreen: "lyrics sounds glass art awake player"
        case .weather: "location city fahrenheit celsius forecast"
        case .accessories: "airpods bluetooth headphones output"
        case .about: "version update"
        }
    }

    static let main: [SettingsPage] = [.general, .media, .tray, .calendar, .integrations, .shortcuts]
    static let overlays: [SettingsPage] = [.sensory, .battery, .focus, .weather, .lockScreen, .accessories]
}

// MARK: - Window

struct SettingsView: View {
    @State private var page: SettingsPage =
        ProcessInfo.processInfo.environment["PERGOLA_SETTINGS_PAGE"].flatMap(SettingsPage.init(rawValue:)) ?? .general
    @State private var search = ""

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 196)
            Rectangle().fill(.white.opacity(0.06)).frame(width: 1)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Image(systemName: page.symbol)
                            .font(.system(size: 22, weight: .semibold))
                        Text(page.title)
                            .font(.system(size: 26, weight: .bold))
                    }
                    .padding(.top, 34)
                    .padding(.bottom, 22)

                    pageContent
                        .id(page)
                        .transition(AnyTransition(.blurReplace).combined(with: .offset(y: 6)))
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        // Resizable: the window opens at a comfortable size for the screen and can grow or shrink.
        .frame(minWidth: 700, idealWidth: 760, maxWidth: .infinity, minHeight: 540, idealHeight: 760, maxHeight: .infinity)
        .background(Color(white: 0.07))
        .background(WindowStyler())
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.25), value: page)
        .onAppear { NSApp.activate() }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.white.opacity(0.45))
                TextField("Search", text: $search).textFieldStyle(.plain)
            }
            .font(.system(size: 13.5))
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(.white.opacity(0.07)))
            .padding(.top, 52)
            .padding(.bottom, 14)

            // The page list scrolls if the window is short, so About (pinned below) is always reachable.
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered(SettingsPage.main)) { SidebarRow(page: $0, selection: $page) }

                    if !filtered(SettingsPage.overlays).isEmpty {
                        Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 10).padding(.horizontal, 6)
                        Text("Overlays")
                            .font(.system(size: 11.5, weight: .medium))
                            .foregroundStyle(.white.opacity(0.4))
                            .padding(.leading, 10)
                            .padding(.bottom, 6)
                        ForEach(filtered(SettingsPage.overlays)) { SidebarRow(page: $0, selection: $page) }
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)

            Rectangle().fill(.white.opacity(0.07)).frame(height: 1).padding(.vertical, 8).padding(.horizontal, 6)
            SidebarRow(page: .about, selection: $page)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .background(Color(white: 0.045))
    }

    private func filtered(_ pages: [SettingsPage]) -> [SettingsPage] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return pages }
        return pages.filter { $0.title.lowercased().contains(q) || $0.keywords.contains(q) }
    }

    @ViewBuilder private var pageContent: some View {
        switch page {
        case .general: GeneralPage()
        case .media: MediaPage()
        case .tray: TrayPage()
        case .calendar: CalendarSettingsPage()
        case .integrations: IntegrationsPage()
        case .shortcuts: ShortcutsPage()
        case .battery: BatteryPage()
        case .weather: WeatherPage()
        case .sensory: SensoryPage()
        case .focus: FocusPage()
        case .lockScreen: LockScreenPage()
        case .accessories: AccessoriesPage()
        case .about: AboutPage()
        }
    }
}

private struct SidebarRow: View {
    let page: SettingsPage
    @Binding var selection: SettingsPage
    @State private var hovering = false

    var body: some View {
        let selected = selection == page
        Button { selection = page } label: {
            HStack(spacing: 10) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 30, height: 30)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(white: 0.16)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.white.opacity(0.08)))
                Text(page.title)
                    .font(.system(size: 15, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(.white.opacity(selected ? 0.12 : (hovering ? 0.05 : 0))))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.smooth(duration: 0.2), value: selected)
    }
}

/// Gives the Settings window its look: no title bar, content up to the traffic lights.
private struct WindowStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async {
            guard let w = v.window else { return }
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.styleMask.insert(.fullSizeContentView)
            w.toolbar = nil
            w.isMovableByWindowBackground = true
            w.backgroundColor = NSColor(white: 0.07, alpha: 1)
        }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

// MARK: - Building blocks

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(.white.opacity(0.055)))
            .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).stroke(.white.opacity(0.05)))
            .padding(.bottom, 14)
    }
}

struct ToggleRow: View {
    var title: String
    var symbol: String? = nil
    @Binding var isOn: Bool
    var divider = false

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 18) }
            HStack(spacing: 10) {
                if let symbol { Image(systemName: symbol).font(.system(size: 14)).frame(width: 20) }
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 18)
            .frame(height: 56)
        }
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.45))
            .padding(.leading, 6)
            .padding(.bottom, 8)
    }
}

/// A footnote with a small action button, for the login-item states that need a hand.
private struct LoginNote: View {
    var text: String
    var button: String
    var action: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.55))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action)
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 10).frame(height: 24)
                .background(Capsule().fill(.white.opacity(0.12)))
        }
        .padding(.horizontal, 6)
        .padding(.top, -6)
        .padding(.bottom, 16)
        .onAppear { LoginItem.shared.refresh() }
    }
}

struct Footnote: View {
    var text: String
    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.42))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.top, -6)
            .padding(.bottom, 16)
    }
}

struct DurationCard: View {
    @Binding var seconds: Double
    var range: ClosedRange<Double>

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Overlay Duration").font(.system(size: 15, weight: .medium))
                    Spacer()
                    Text("\(Int(seconds))").font(.system(size: 19, weight: .semibold)).monospacedDigit()
                    Text("sec").font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
                }
                Slider(value: $seconds, in: range, step: 1)
                HStack {
                    Text("\(Int(range.lowerBound))")
                    Spacer()
                    Text("\(Int(range.upperBound))")
                }
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
            }
            .padding(18)
        }
    }
}

/// A row of selectable tiles on a dark "preview" strip.
struct TilePicker<Tile: View>: View {
    var title: String
    var options: [(id: String, label: String)]
    @Binding var selection: String
    @ViewBuilder var tile: (String) -> Tile

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text(title).font(.system(size: 15, weight: .medium))
                HStack(spacing: 0) {
                    ForEach(options, id: \.id) { opt in
                        Button { withAnimation(.spring(response: 0.3)) { selection = opt.id } } label: {
                            VStack(spacing: 8) {
                                Text(opt.label)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(selection == opt.id ? 0.9 : 0.5))
                                tile(opt.id)
                                    .frame(height: 40)
                                    .scaleEffect(selection == opt.id ? 1.06 : 1)
                                Circle().fill(.white).frame(width: 4, height: 4)
                                    .opacity(selection == opt.id ? 1 : 0)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 16)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.32), Color(white: 0.06)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12)))
                .padding(.horizontal, 16)
            }
            .padding(18)
        }
    }
}

// MARK: - General

private struct GeneralPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.hideInFullscreen) private var hideInFullscreen = true
    @AppStorage(Prefs.hideFromCapture) private var hideFromCapture = false
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true
    @AppStorage(Prefs.liquidGlass) private var liquidGlass = true
    @AppStorage(Prefs.glassDarkness) private var glassDarkness = 0.85
    @State private var glassPreviewToken = 0
    @AppStorage(Prefs.haptics) private var haptics = true
    @AppStorage(Prefs.expandOnHover) private var expandOnHover = true
    @AppStorage(Prefs.swipeToSkip) private var swipePages = true
    @AppStorage(Prefs.liveWaveform) private var liveWaveform = true
    private var login: LoginItem { .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                ToggleRow(title: "Hide in Fullscreen", isOn: $hideInFullscreen)
                ToggleRow(title: "Hide from Screen Capture", isOn: $hideFromCapture, divider: true)
                ToggleRow(title: "Menu Bar Icon", isOn: $showMenuBarIcon, divider: true)
                ToggleRow(title: "Open at Login",
                          isOn: Binding(get: { login.wanted }, set: { login.setEnabled($0) }), divider: true)
            }
            if login.wanted && !login.isInstalled {
                LoginNote(text: "Pergola can only open at login from the Applications folder.",
                          button: "Move to Applications") { login.moveToApplications() }
            } else if login.wanted && login.status == .requiresApproval {
                LoginNote(text: "macOS needs you to allow Pergola in Login Items.",
                          button: "Open Login Items") { login.openLoginItemsSettings() }
            }
            if !showMenuBarIcon {
                Footnote(text: "With the icon hidden, open Pergola again from Finder or Spotlight to get back here.")
            }

            SectionLabel(text: "Glass")
            Card { ToggleRow(title: "Liquid Glass View", isOn: $liquidGlass) }
            if liquidGlass {
                Card {
                    HStack(spacing: 12) {
                        Circle().stroke(.white.opacity(0.5), lineWidth: 1).frame(width: 12, height: 12)
                        Slider(value: $glassDarkness, in: 0.15...0.95) { editing in
                            // Open the notch while dragging so the change is visible; linger briefly after.
                            glassPreviewToken += 1
                            if editing { model.ui.previewingGlass = true }
                            else {
                                let token = glassPreviewToken
                                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                                    if token == glassPreviewToken { model.ui.previewingGlass = false }
                                }
                            }
                        }
                        Circle().fill(.white.opacity(0.8)).frame(width: 12, height: 12)
                    }
                    .padding(.horizontal, 18).frame(height: 56)
                }
                HStack {
                    Text("Clear Glass"); Spacer(); Text("Dark")
                }
                .font(.system(size: 12)).foregroundStyle(.white.opacity(0.42))
                .padding(.horizontal, 18).padding(.top, -8).padding(.bottom, 16)
            }

            SectionLabel(text: "Behavior")
            Card {
                ToggleRow(title: "Haptic Touch", isOn: $haptics)
                ToggleRow(title: "Expand on Hover", isOn: $expandOnHover, divider: true)
                ToggleRow(title: "Swipe Between Pages", isOn: $swipePages, divider: true)
                ToggleRow(title: "Live Waveform", isOn: $liveWaveform, divider: true)
            }
            waveformStatus
        }
    }

    @ViewBuilder private var waveformStatus: some View {
        let w = model.waveform
        VStack(alignment: .leading, spacing: 6) {
            Text("The waveform listens only to your music app, only while it's playing, and stops within two seconds of pausing. Turning it off stops listening immediately.")
            if w.active {
                Label("Listening to \(model.player.source?.scriptName ?? "music") now", systemImage: "waveform")
                    .foregroundStyle(.green)
            } else if let err = w.lastError {
                Label("Unavailable: \(err). Allow Pergola under Screen & System Audio Recording in Privacy & Security.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white.opacity(0.42))
        .padding(.horizontal, 6)
        .padding(.top, -6)
    }
}

// MARK: - Media

private struct MediaPage: View {
    @AppStorage(Prefs.mediaPlayer) private var mediaPlayer = true
    @AppStorage(Prefs.playerSource) private var source = "auto"
    @AppStorage(Prefs.leftButton) private var leftButton = "shuffle"
    @AppStorage(Prefs.colorMatch) private var colorMatch = true
    @AppStorage(Prefs.collapseOnPause) private var collapseOnPause = false
    @AppStorage(Prefs.trackOverlay) private var trackOverlay = true
    @AppStorage(Prefs.webMedia) private var webMedia = true
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card { ToggleRow(title: "Media Player", isOn: $mediaPlayer) }

            TilePicker(title: "Source",
                       options: [("auto", "Auto"), ("spotify", "Spotify"), ("music", "Music")],
                       selection: $source) { id in
                switch id {
                case "auto":
                    Image(systemName: "person.2.wave.2.fill").font(.system(size: 22)).foregroundStyle(.white)
                case "spotify": AppIcon(bundleID: "com.spotify.client")
                default: AppIcon(bundleID: "com.apple.Music")
                }
            }
            Footnote(text: "Auto shows whichever of Music and Spotify is playing. Pick one to only ever show that app.")

            Card {
                ToggleRow(title: "Browsers and Other Apps", isOn: $webMedia)
                    .onChange(of: webMedia) { _, on in model.player.web.setEnabled(on) }
            }
            Footnote(text: "Also shows YouTube, SoundCloud and other players in Safari, Chrome, Arc and other browsers, plus apps like Podcasts. They get play, pause, skip and the progress bar; shuffle, repeat and favorite stay with Music and Spotify.")

            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Left Button").font(.system(size: 15, weight: .medium))
                    HStack(spacing: 10) {
                        ForEach([("favorite", "heart.fill"), ("shuffle", "shuffle"), ("repeat", "repeat"), ("none", "nosign")], id: \.0) { id, symbol in
                            Button { withAnimation(.spring(response: 0.3)) { leftButton = id } } label: {
                                Image(systemName: symbol)
                                    .font(.system(size: 17, weight: .semibold))
                                    .frame(maxWidth: .infinity).frame(height: 50)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.white.opacity(leftButton == id ? 0.16 : 0.07)))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(.white.opacity(leftButton == id ? 0.35 : 0.06)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                .padding(18)
            }
            Footnote(text: "Pick what the player's left button does, or None to leave the slot empty. The heart favorites songs in Apple Music. The right button always switches your audio output.")

            SectionLabel(text: "Appearance")
            Card {
                ToggleRow(title: "Match Song Color", isOn: $colorMatch)
                ToggleRow(title: "Hide the Player When Paused", isOn: $collapseOnPause, divider: true)
                ToggleRow(title: "Song Title Preview", isOn: $trackOverlay, divider: true)
            }
            Footnote(text: "Song Title Preview shows the new song's title under the notch for a moment when the track changes.")
        }
    }
}

private struct AppIcon: View {
    var bundleID: String
    var body: some View {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 42, height: 42)
        } else {
            // App not installed: a simple badge in the app's colour instead of a broken icon.
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(bundleID.contains("spotify") ? Color(red: 0.12, green: 0.73, blue: 0.33) : .pink)
                .frame(width: 40, height: 40)
                .overlay(Image(systemName: "music.note").font(.system(size: 19, weight: .bold)).foregroundStyle(.white))
        }
    }
}

// MARK: - File Tray

private struct TrayPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.trayEnabled) private var trayEnabled = true
    @AppStorage(Prefs.trayOpenOnDrag) private var openOnDrag = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                ToggleRow(title: "File Tray", isOn: $trayEnabled)
                ToggleRow(title: "Open When Dragging Files to the Notch", isOn: $openOnDrag, divider: true)
            }
            Footnote(text: "Drag files onto the notch to park them, then drag them out wherever you need them. Pergola only remembers where they are; nothing is copied or moved.")
            Card {
                HStack {
                    Text("\(model.tray.items.count) \(model.tray.items.count == 1 ? "file" : "files") in the tray")
                        .font(.system(size: 15, weight: .medium))
                    Spacer()
                    Button("Clear Tray") { model.tray.clear() }
                        .disabled(model.tray.items.isEmpty)
                }
                .padding(.horizontal, 18).frame(height: 56)
            }
        }
    }
}

// MARK: - Battery

private struct BatteryPage: View {
    @AppStorage(Prefs.chargingOverlay) private var chargingOverlay = true
    @AppStorage(Prefs.overlaySeconds) private var seconds = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card { ToggleRow(title: "Charger Connect", isOn: $chargingOverlay) }
            Footnote(text: "Shows the battery level when you plug in, and how long until it's full once macOS has an estimate.")
            DurationCard(seconds: $seconds, range: 2...8)
        }
    }
}

// MARK: - Weather

private struct WeatherPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.weatherEnabled) private var weatherEnabled = true
    @AppStorage(Prefs.weatherCity) private var city = ""
    @AppStorage(Prefs.fahrenheit) private var fahrenheit = false
    @State private var cityDraft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Live preview of the weather page, on a dark glass card.
            WeatherTab(weather: model.weather)
                .padding(.horizontal, 22)
                .padding(.vertical, 20)
                .frame(height: 170)
                .background(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [Color(white: 0.3), Color(white: 0.04)], startPoint: .top, endPoint: .bottom))
                )
                .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12)))
                .padding(.bottom, 16)

            Card { ToggleRow(title: "Weather", isOn: $weatherEnabled) }
            Footnote(text: "Swipe left across the open notch to flip between the player, the weather page and the file tray.")

            SectionLabel(text: "Location")
            Card {
                HStack(spacing: 10) {
                    Image(systemName: "location.fill").font(.system(size: 14)).frame(width: 20)
                    TextField("City", text: $cityDraft, prompt: Text("Use my location"))
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .medium))
                        .onSubmit { city = cityDraft }
                    if !cityDraft.isEmpty {
                        Button { cityDraft = ""; city = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.white.opacity(0.4))
                    }
                }
                .padding(.horizontal, 18).frame(height: 56)
                ToggleRow(title: "Fahrenheit", isOn: $fahrenheit, divider: true)
            }
            Footnote(text: "Leave the city empty to use your Mac's location. Type a city and press Return to always show that city instead.")
        }
        .onAppear { cityDraft = city }
    }
}

// MARK: - Accessories

private struct AccessoriesPage: View {
    @AppStorage(Prefs.accessoryOverlay) private var accessoryOverlay = true
    @AppStorage(Prefs.outputOverlay) private var outputOverlay = true
    @AppStorage(Prefs.connectionOverlay) private var connectionOverlay = true
    @AppStorage(Prefs.overlaySeconds) private var seconds = 3.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                ToggleRow(title: "Accessory Connect", isOn: $accessoryOverlay)
                ToggleRow(title: "Output Change", isOn: $outputOverlay, divider: true)
                ToggleRow(title: "Connections", isOn: $connectionOverlay, divider: true)
            }
            Footnote(text: "Accessory Connect shows AirPods and other Bluetooth devices with their battery when they connect. Output Change shows where your audio is playing when it switches. Connections shows a VPN, your iPhone's Personal Hotspot or a display (by cable or AirPlay) connecting and disconnecting.")
            DurationCard(seconds: $seconds, range: 2...8)
        }
    }
}

// MARK: - Integrations

private struct IntegrationsPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.activitiesEnabled) private var enabled = true
    @AppStorage(Prefs.activityOverlay) private var overlay = true
    @AppStorage(Prefs.ringsPage) private var ringsPage = true
    @AppStorage(Prefs.callTimer) private var callTimer = true
    @AppStorage(Prefs.clockTimers) private var clockTimers = true
    @State private var hooksInstalled = ClaudeSetup.hooksInstalled
    @State private var note: String?
    @State private var otherNote: String?

    private var address: String { "http://127.0.0.1:\(model.api.port ?? PergolaAPI.defaultPort)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card {
                ToggleRow(title: "App Activities", isOn: $enabled)
                ToggleRow(title: "Announce Under the Notch", isOn: $overlay, divider: true)
                ToggleRow(title: "Goal Rings Page", isOn: $ringsPage, divider: true)
            }
            .onChange(of: enabled) { _, on in model.api.setEnabled(on) }
            .onChange(of: ringsPage) { _, on in
                if !on, model.ui.tab == .rings { model.ui.tab = .player }
            }
            Footnote(text: enabled
                ? (model.api.port == nil ? "Starting…" : "Your apps can show a task and its progress in the notch by posting to \(address) on this Mac. Nothing outside this Mac can reach it. INTEGRATIONS.md in Pergola's folder has the details and a drop-in Swift file.")
                : "Other apps can't show anything in the notch while this is off.")

            if enabled {
                SectionLabel(text: "Calls and Timers")
                Card {
                    ToggleRow(title: "Call Length", isOn: $callTimer)
                    ToggleRow(title: "Clock Timers", isOn: $clockTimers, divider: true)
                    LabeledRow(title: "Try It", divider: true) {
                        HStack(spacing: 6) {
                            pill("Timer") {
                                if let body = PergolaCLI.timerBody(duration: "20s", title: "Test Timer") { model.activities.upsert(body) }
                            }
                            pill("Call") {
                                model.activities.upsert(["id": "pergola-demo-call", "app": "FaceTime", "title": "FaceTime", "detail": "On a call",
                                                         "symbol": "phone.fill", "tint": "#30D158", "bundle_id": "com.apple.FaceTime", "elapsed": true])
                                DispatchQueue.main.asyncAfter(deadline: .now() + 15) { model.activities.remove(id: "pergola-demo-call") }
                            }
                        }
                    }
                }
                Footnote(text: "Call Length shows how long you've been on a FaceTime, Zoom, Teams, Webex, Discord, Slack, WhatsApp or Signal call, by noticing when that app is using the microphone. Clock Timers mirrors timers running in the Clock app; macOS may ask to let Pergola read Clock's data. Start a timer of Pergola's own from Terminal with: Pergola --timer 5m Tea")

                SectionLabel(text: "Claude")
                Card {
                    LabeledRow(title: "Claude Code Progress") {
                        pill(hooksInstalled ? "Connected" : "Connect", dim: hooksInstalled) {
                            note = ClaudeSetup.installHooks()
                            hooksInstalled = ClaudeSetup.hooksInstalled
                        }
                        .disabled(hooksInstalled)
                    }
                    LabeledRow(title: "MCP for Claude Code", divider: true) {
                        pill("Copy Command") { copy("claude mcp add --transport http --scope user pergola \(address)/mcp") }
                    }
                    LabeledRow(title: "MCP for Claude Desktop", divider: true) {
                        pill("Copy Config") { copy(ClaudeSetup.desktopConfig) }
                    }
                }
                Footnote(text: note ?? "Claude Code Progress adds hooks to ~/.claude/settings.json so the notch shows what Claude is doing and how far through its task list it is. MCP lets Claude post its own activities; run the copied command in Terminal, or paste the config into Claude Desktop's claude_desktop_config.json.")

                Card {
                    LabeledRow(title: "Try It") {
                        pill("Send a Test") { ClaudeSetup.demo(model.activities) }
                    }
                }

                SectionLabel(text: "Other AI Tools")
                Card {
                    LabeledRow(title: "MCP for Codex") {
                        pill("Copy Command") { copy("codex mcp add pergola -- '\(ClaudeSetup.binary)' --mcp", other: true) }
                    }
                    LabeledRow(title: "MCP for Gemini CLI", divider: true) {
                        pill("Copy Command") { copy("gemini mcp add --transport http pergola \(address)/mcp", other: true) }
                    }
                    LabeledRow(title: "MCP for Cursor and Others", divider: true) {
                        pill("Copy Config") { copy(ClaudeSetup.desktopConfig, other: true) }
                    }
                    LabeledRow(title: "From a Terminal or Script", divider: true) {
                        pill("Copy Command") {
                            copy("'\(ClaudeSetup.binary)' --activity '{\"id\":\"task-1\",\"app\":\"ChatGPT\",\"title\":\"Drafting\",\"progress\":0.3}'", other: true)
                        }
                    }
                }
                Footnote(text: otherNote ?? "ChatGPT, Codex, Gemini, Cursor, Copilot and other tools each show with their own icon or colour. Run a copied command in Terminal, or paste the config into the tool's MCP settings. Pergola tells them apart by name.")

                Card {
                    LabeledRow(title: "Try It") {
                        HStack(spacing: 6) {
                            ForEach(["ChatGPT", "Gemini", "Cursor"], id: \.self) { app in
                                pill(app) { ClaudeSetup.demo(model.activities, app: app) }
                            }
                        }
                    }
                }
            }
        }
    }

    private func pill(_ title: String, dim: Bool = false, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.white.opacity(dim ? 0.5 : 1))
            .padding(.horizontal, 12).frame(height: 26)
            .background(Capsule().fill(.white.opacity(dim ? 0.06 : 0.12)))
    }

    private func copy(_ text: String, other: Bool = false) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        if other { otherNote = "Copied." } else { note = "Copied." }
    }
}

// MARK: - About

private struct AboutPage: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.topthird.inset.filled")
                .font(.system(size: 44))
                .padding(.top, 40)
            Text("Pergola").font(.system(size: 22, weight: .bold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
            Text("Your notch, your way.")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Sensory

/// A two-option segmented control (Notch | Apple Style).
struct Segmented: View {
    var options: [(id: String, label: String)]
    @Binding var selection: String

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.id) { opt in
                Button { withAnimation(.spring(duration: 0.3, bounce: 0.15)) { selection = opt.id } } label: {
                    Text(opt.label)
                        .font(.system(size: 13.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(selection == opt.id ? 1 : 0.55))
                        .padding(.horizontal, 14).frame(height: 30)
                        .background {
                            if selection == opt.id { Capsule().fill(.white.opacity(0.16)) }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Capsule().fill(.white.opacity(0.06)))
    }
}

struct LabeledRow<Trailing: View>: View {
    var title: String
    var divider = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            if divider { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 18) }
            HStack {
                Text(title).font(.system(size: 15, weight: .medium))
                Spacer()
                trailing
            }
            .padding(.horizontal, 18).frame(height: 56)
        }
    }
}

/// Shows whether a macOS permission is granted, with a button to fix it.
struct PermissionCard: View {
    var title: String
    var detail: String
    var granted: Bool
    var action: () -> Void

    var body: some View {
        Card {
            HStack(spacing: 12) {
                Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(granted ? .green : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(granted ? "\(title) is on" : "\(title) needed").font(.system(size: 14.5, weight: .semibold))
                    Text(detail).font(.system(size: 12)).foregroundStyle(.white.opacity(0.5))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if !granted { Button("Allow…", action: action) }
            }
            .padding(16)
        }
    }
}

private struct SensoryPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.sensoryStyle) private var style = "notch"
    @AppStorage(Prefs.sensoryVolume) private var volume = true
    @AppStorage(Prefs.sensoryBrightness) private var brightness = true
    @AppStorage(Prefs.sensoryColorMatch) private var colorMatch = true
    @AppStorage(Prefs.sensoryLabel) private var label = "icon"
    @AppStorage(Prefs.sensorySeconds) private var seconds = 2.0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PermissionCard(title: "Accessibility",
                           detail: "Lets Pergola take over the volume and brightness keys so its overlay replaces the system one.",
                           granted: model.sensory.accessibilityGranted) { model.sensory.requestAccess() }

            SectionLabel(text: "Style")
            Card {
                LabeledRow(title: "Style") {
                    Segmented(options: [("notch", "Notch"), ("apple", "Apple Style")], selection: $style)
                }
            }

            SectionLabel(text: "Overlays")
            Card {
                ToggleRow(title: "Brightness", symbol: "sun.max", isOn: $brightness)
                ToggleRow(title: "Volume", symbol: "speaker.wave.2", isOn: $volume, divider: true)
            }

            SectionLabel(text: "Appearance")
            Card {
                ToggleRow(title: "Match Song Color", isOn: $colorMatch)
                LabeledRow(title: "Label Style", divider: true) {
                    Segmented(options: [("icon", "Icon"), ("name", "Name")], selection: $label)
                }
            }
            Footnote(text: "Icon shows the display / speaker symbol in the overlay; Name shows \"Display\" or \"Volume\" as text.")
            DurationCard(seconds: $seconds, range: 1...6)
        }
    }
}

// MARK: - Focus

private struct FocusPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.focusOverlay) private var overlay = true
    @AppStorage(Prefs.focusShowsBattery) private var battery = true
    @AppStorage(Prefs.focusShowsAccessories) private var airpods = true
    @AppStorage(Prefs.focusShowsSensory) private var sensory = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PermissionCard(title: "Full Disk Access",
                           detail: "macOS only shares which Focus is on through its Focus database, so Pergola needs Full Disk Access to read the mode's name and icon.",
                           granted: model.focus.hasAccess) { model.focus.openFullDiskAccessSettings() }
            Card { ToggleRow(title: "Focus Overlay", isOn: $overlay) }
            Footnote(text: "Show an overlay in the notch when a Focus mode turns on or off.")

            SectionLabel(text: "While in Focus, also show")
            Card {
                ToggleRow(title: "Battery Overlay", symbol: "bolt.fill", isOn: $battery)
                ToggleRow(title: "AirPods Overlay", symbol: "airpods", isOn: $airpods, divider: true)
                ToggleRow(title: "Sensory Overlay", symbol: "sun.max.fill", isOn: $sensory, divider: true)
            }
            Footnote(text: "Overlays switched off here stay hidden while a Focus mode is active.")

        }
    }
}

// MARK: - Lock Screen

private struct LockScreenPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.lockScreen) private var enabled = true
    @AppStorage(Prefs.lockGlassStyle) private var glassStyle = "clear"
    @AppStorage(Prefs.lockFullArt) private var fullArt = true
    @AppStorage(Prefs.lockLyrics) private var lyrics = true
    @AppStorage(Prefs.lyricsOffsetMs) private var offset = 0.0
    @AppStorage(Prefs.lockGlassArt) private var glassArt = true
    @AppStorage(Prefs.lockGlassCard) private var glassCard = true
    @AppStorage(Prefs.lockKeepAwake) private var keepAwake = false
    @AppStorage(Prefs.lockKeepAwakeMinutes) private var keepAwakeMinutes = 5.0
    @AppStorage(Prefs.lockSound) private var lockSound = false
    @AppStorage(Prefs.unlockSound) private var unlockSound = false
    @AppStorage(Prefs.lockSoundVolume) private var soundVolume = 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            Card { ToggleRow(title: "Lock Screen Player", isOn: $enabled) }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Glass Style").font(.system(size: 15, weight: .medium))
                    HStack(spacing: 10) {
                        ForEach([("clear", "Clear"), ("frosted", "Frosted")], id: \.0) { id, name in
                            Button { withAnimation(.spring(duration: 0.3)) { glassStyle = id } } label: {
                                Text(name)
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity).frame(height: 44)
                                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(.white.opacity(glassStyle == id ? 0.16 : 0.06)))
                                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(.white.opacity(glassStyle == id ? 0.35 : 0.06)))
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(PressStyle())
                        }
                    }
                }
                .padding(18)
            }

            SectionLabel(text: "Behavior")
            Card {
                ToggleRow(title: "Full Art", isOn: $fullArt)
                ToggleRow(title: "Lyrics", isOn: $lyrics, divider: true)
                if lyrics {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Text("Sync").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                            Spacer()
                            Text("\(Int(offset)) ms").font(.system(size: 15, weight: .semibold)).monospacedDigit()
                        }
                        Slider(value: $offset, in: -1500...1500, step: 50)
                        HStack { Text("Later"); Spacer(); Text("Earlier") }
                            .font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
                    }
                    .padding(.horizontal, 18).padding(.vertical, 12)
                }
                ToggleRow(title: "Glass Art", isOn: $glassArt, divider: true)
                ToggleRow(title: "Glass Card", isOn: $glassCard, divider: true)
            }

            SectionLabel(text: "Display")
            Card {
                ToggleRow(title: "Keep Display Awake While Playing", isOn: $keepAwake)
                if keepAwake {
                    LabeledRow(title: "For", divider: true) {
                        Stepper("\(Int(keepAwakeMinutes)) min", value: $keepAwakeMinutes, in: 1...60)
                    }
                }
            }

            SectionLabel(text: "Sounds")
            Card {
                ToggleRow(title: "Lock Sound", isOn: $lockSound)
                ToggleRow(title: "Unlock Sound", isOn: $unlockSound, divider: true)
                if lockSound || unlockSound {
                    HStack(spacing: 12) {
                        Image(systemName: "speaker.fill").foregroundStyle(.white.opacity(0.5))
                        Slider(value: $soundVolume, in: 0...1) { editing in
                            if !editing { LockSounds.play(lock: true) }
                        }
                        Image(systemName: "speaker.wave.3.fill").foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 18).frame(height: 52)
                }
            }
            if !SkyLight.available {
                Footnote(text: "This version of macOS doesn't allow apps on the lock screen, so the player can’t show there.")
            }
        }
    }

    /// Mini preview of the lock screen.
    private var preview: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.32, green: 0.38, blue: 0.5), Color(red: 0.12, green: 0.13, blue: 0.16)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 10) {
                TimelineView(.everyMinute) { ctx in
                    Text(ctx.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                        .font(.system(size: 54, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                }
                HStack(spacing: 10) {
                    ArtworkView(image: model.player.artwork, cornerRadius: 8).frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.player.hasTrack ? model.player.title : "Not Playing").font(.system(size: 12, weight: .semibold))
                        Text(model.player.artist).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer(minLength: 0)
                }
                .padding(10)
                .frame(width: 200)
                .modifier(LockGlass(radius: 16))
            }
        }
        .frame(height: 230)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(.white.opacity(0.12)))
        .padding(.bottom, 16)
    }
}

// MARK: - Calendar

private struct CalendarSettingsPage: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.calendarEnabled) private var enabled = true
    @AppStorage(Prefs.calendarDays) private var days = 3

    private var agenda: Agenda { model.agenda }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PermissionCard(title: "Calendar access",
                           detail: "Pergola reads your events to show them in the notch. Google, iCloud and Exchange all work once they're added in System Settings › Internet Accounts.",
                           granted: agenda.hasAccess) {
                if agenda.status == .notDetermined { agenda.requestAccess() }
                else { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!) }
            }
            Card {
                ToggleRow(title: "Calendar Page", isOn: $enabled)
                LabeledRow(title: "Show the Next", divider: true) {
                    Stepper("\(days) \(days == 1 ? "day" : "days")", value: $days, in: 1...14)
                }
            }
            Footnote(text: "Swipe right twice from the player, past the file tray, to reach your calendar. Video calls get a Join button.")

            if agenda.hasAccess, !agenda.calendars.isEmpty {
                SectionLabel(text: "Calendars")
                Card {
                    ForEach(Array(agenda.calendars.enumerated()), id: \.element.id) { i, cal in
                        CalendarToggle(id: cal.id, title: cal.title, source: cal.source, color: cal.color, divider: i > 0)
                    }
                }
            } else if agenda.hasAccess {
                Footnote(text: "No calendars found. Add your Google account in System Settings › Internet Accounts and turn on Calendars.")
            }
        }
        .onAppear { agenda.start(); agenda.reload() }
    }
}

private struct CalendarToggle: View {
    var id: String
    var title: String
    var source: String
    var color: Color
    var divider: Bool
    @AppStorage(Prefs.calendarHidden) private var hiddenData = Data()

    var body: some View {
        let hidden = Set(Prefs.d.stringArray(forKey: Prefs.calendarHidden) ?? [])
        let on = Binding(get: { !hidden.contains(id) }, set: { show in
            var h = hidden
            if show { h.remove(id) } else { h.insert(id) }
            Prefs.d.set(Array(h), forKey: Prefs.calendarHidden)
        })
        VStack(spacing: 0) {
            if divider { Rectangle().fill(.white.opacity(0.06)).frame(height: 1).padding(.horizontal, 18) }
            HStack(spacing: 10) {
                Circle().fill(color).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 14.5, weight: .medium))
                    if !source.isEmpty { Text(source).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.45)) }
                }
                Spacer()
                Toggle("", isOn: on).toggleStyle(.switch).labelsHidden()
            }
            .padding(.horizontal, 18).frame(height: 54)
        }
    }
}
