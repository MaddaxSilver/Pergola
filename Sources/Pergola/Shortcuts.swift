import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Things a global keyboard shortcut can do.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case toggleNotch, bigArt, previousPage, nextPage, playPause, nextTrack, previousTrack, favorite, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .toggleNotch: "Open or Close the Notch"
        case .bigArt: "Album Art and Lyrics"
        case .previousPage: "Previous Page"
        case .nextPage: "Next Page"
        case .playPause: "Play or Pause"
        case .nextTrack: "Next Song"
        case .previousTrack: "Previous Song"
        case .favorite: "Favorite This Song"
        case .settings: "Open Settings"
        }
    }

    static let notch: [ShortcutAction] = [.toggleNotch, .bigArt, .previousPage, .nextPage]
    static let media: [ShortcutAction] = [.playPause, .nextTrack, .previousTrack, .favorite]

    /// Control-Option combinations: nothing in macOS uses them, and they stay clear of the
    /// arrow keys that window managers take.
    var defaultCombo: KeyCombo? {
        let m = controlKey | optionKey
        return switch self {
        case .toggleNotch: KeyCombo(keyCode: kVK_ANSI_N, mods: m, key: "N")
        case .bigArt: KeyCombo(keyCode: kVK_ANSI_L, mods: m, key: "L")
        case .playPause: KeyCombo(keyCode: kVK_Space, mods: m, key: "Space")
        case .nextTrack: KeyCombo(keyCode: kVK_ANSI_Period, mods: m, key: ".")
        case .previousTrack: KeyCombo(keyCode: kVK_ANSI_Comma, mods: m, key: ",")
        default: nil
        }
    }
}

struct KeyCombo: Equatable {
    var keyCode: Int
    var mods: Int      // Carbon modifier flags
    var key: String    // what the key is called, e.g. "N" or "Space"

    var label: String {
        var s = ""
        if mods & controlKey != 0 { s += "⌃" }
        if mods & optionKey != 0 { s += "⌥" }
        if mods & shiftKey != 0 { s += "⇧" }
        if mods & cmdKey != 0 { s += "⌘" }
        return s + key
    }

    var dict: [String: Any] { ["code": keyCode, "mods": mods, "key": key] }

    init(keyCode: Int, mods: Int, key: String) { self.keyCode = keyCode; self.mods = mods; self.key = key }

    init?(dict: [String: Any]) {
        guard let c = dict["code"] as? Int, let m = dict["mods"] as? Int, let k = dict["key"] as? String else { return nil }
        self.init(keyCode: c, mods: m, key: k)
    }

    private static let named: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_LeftArrow: "←", kVK_RightArrow: "→",
        kVK_UpArrow: "↑", kVK_DownArrow: "↓", kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_ForwardDelete: "⌦", kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19",
    ]

    /// The combination a key press describes, or nil if it can't be a global shortcut
    /// (a plain letter with no Control, Option or Command would swallow ordinary typing).
    init?(event: NSEvent) {
        let code = Int(event.keyCode)
        var m = 0
        if event.modifierFlags.contains(.control) { m |= controlKey }
        if event.modifierFlags.contains(.option) { m |= optionKey }
        if event.modifierFlags.contains(.shift) { m |= shiftKey }
        if event.modifierFlags.contains(.command) { m |= cmdKey }
        let isFunctionKey = Self.named[code]?.hasPrefix("F") == true
        guard m & (controlKey | optionKey | cmdKey) != 0 || isFunctionKey else { return nil }
        let name = Self.named[code] ?? event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Self.named[code] != nil else { return nil }
        self.init(keyCode: code, mods: m, key: name)
    }
}

/// System-wide keyboard shortcuts. Uses the Carbon hot-key API, which needs no Accessibility
/// permission and only ever sees the exact combinations registered here.
@Observable @MainActor
final class Shortcuts {
    static let shared = Shortcuts()

    private(set) var combos: [ShortcutAction: KeyCombo] = [:]
    /// Combinations macOS refused (another app already holds them).
    private(set) var unavailable: Set<ShortcutAction> = []
    /// A shortcut is being recorded in Settings: everything is switched off so the keys reach the recorder.
    var recording = false { didSet { if recording != oldValue { register() } } }

    @ObservationIgnored private var refs: [EventHotKeyRef] = []
    @ObservationIgnored private var escapeRef: EventHotKeyRef?
    @ObservationIgnored private var handlerInstalled = false
    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private weak var notch: NotchWindowController?

    private static let signature: OSType = 0x5052_474C // "PRGL"
    private static let escapeID: UInt32 = 999

    func start(model: AppModel, notch: NotchWindowController?) {
        self.model = model
        self.notch = notch
        // Esc closes a notch that was opened from the keyboard, and is only claimed while it is open.
        notch?.onKeyboardPin = { [weak self] pinned in self?.setEscape(pinned) }
        load()
        register()
    }

    // MARK: Stored combinations

    private func load() {
        let saved = Prefs.d.dictionary(forKey: Prefs.shortcuts) ?? [:]
        combos = [:]
        for a in ShortcutAction.allCases {
            if let d = saved[a.rawValue] as? [String: Any] { combos[a] = KeyCombo(dict: d) }   // {} means "none"
            else { combos[a] = a.defaultCombo }
        }
    }

    private func save() {
        var out: [String: Any] = [:]
        for a in ShortcutAction.allCases { out[a.rawValue] = combos[a]?.dict ?? [String: Any]() }
        Prefs.d.set(out, forKey: Prefs.shortcuts)
    }

    func set(_ combo: KeyCombo?, for action: ShortcutAction) {
        // One combination, one action: taking it here frees it wherever else it was.
        if let combo { for (a, c) in combos where a != action && c.keyCode == combo.keyCode && c.mods == combo.mods { combos[a] = nil } }
        combos[action] = combo
        save()
        register()
    }

    func restoreDefaults() {
        Prefs.d.removeObject(forKey: Prefs.shortcuts)
        load()
        register()
    }

    // MARK: Registration

    func register() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs = []
        unavailable = []
        guard Prefs.d.bool(forKey: Prefs.shortcutsEnabled), !recording else { return }
        installHandler()
        for (i, action) in ShortcutAction.allCases.enumerated() {
            guard let c = combos[action] else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(c.keyCode), UInt32(c.mods),
                                             EventHotKeyID(signature: Self.signature, id: UInt32(i)),
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { refs.append(ref) } else { unavailable.insert(action) }
        }
    }

    private func setEscape(_ on: Bool) {
        if let escapeRef { UnregisterEventHotKey(escapeRef); self.escapeRef = nil }
        guard on else { return }
        installHandler()
        RegisterEventHotKey(UInt32(kVK_Escape), 0, EventHotKeyID(signature: Self.signature, id: Self.escapeID),
                            GetApplicationEventTarget(), 0, &escapeRef)
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let n = id.id
            DispatchQueue.main.async { MainActor.assumeIsolated { Shortcuts.shared.fire(n) } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    private func fire(_ id: UInt32) {
        if id == Self.escapeID { notch?.keyboardClose(); return }
        guard Int(id) < ShortcutAction.allCases.count else { return }
        perform(ShortcutAction.allCases[Int(id)])
    }

    func perform(_ action: ShortcutAction) {
        guard let model else { return }
        switch action {
        case .toggleNotch: notch?.keyboardToggle()
        case .bigArt: notch?.keyboardBigArt()
        case .previousPage: notch?.keyboardPage(-1)
        case .nextPage: notch?.keyboardPage(1)
        case .playPause: if model.player.hasTrack { model.player.playPause() }
        case .nextTrack: if model.player.hasTrack { model.player.next() }
        case .previousTrack: if model.player.hasTrack { model.player.previous() }
        case .favorite: if model.player.hasTrack { model.player.toggleFavorite() }
        case .settings: AppDelegate.openSettings()
        }
    }
}

// MARK: - Settings

struct ShortcutsPage: View {
    @AppStorage(Prefs.shortcutsEnabled) private var enabled = true
    private var shortcuts: Shortcuts { Shortcuts.shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Card { ToggleRow(title: "Keyboard Shortcuts", isOn: $enabled) }
                .onChange(of: enabled) { _, _ in shortcuts.register() }
            Footnote(text: enabled
                ? "These work from any app. Click a shortcut and press the new keys, or press Delete to remove it. A shortcut needs Control, Option or Command."
                : "No keys are claimed while this is off.")

            if enabled {
                SectionLabel(text: "Notch")
                Card { rows(ShortcutAction.notch) }
                Footnote(text: "A notch opened from the keyboard stays open until you press the shortcut again, press Esc, or click somewhere else.")

                SectionLabel(text: "Music")
                Card { rows(ShortcutAction.media) }

                SectionLabel(text: "Pergola")
                Card {
                    rows([.settings])
                    LabeledRow(title: "All Shortcuts", divider: true) {
                        Button("Restore Defaults") { shortcuts.restoreDefaults() }
                            .buttonStyle(.plain)
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, 12).frame(height: 26)
                            .background(Capsule().fill(.white.opacity(0.12)))
                    }
                }
            }
        }
        .onDisappear { shortcuts.recording = false }
    }

    @ViewBuilder private func rows(_ actions: [ShortcutAction]) -> some View {
        ForEach(Array(actions.enumerated()), id: \.element) { i, action in
            LabeledRow(title: action.title, divider: i > 0) {
                HStack(spacing: 8) {
                    if shortcuts.unavailable.contains(action) {
                        Text("In use by another app")
                            .font(.system(size: 12))
                            .foregroundStyle(.orange.opacity(0.9))
                    }
                    ShortcutRecorder(action: action)
                }
            }
        }
    }
}

/// A pill showing an action's shortcut. Click it, press keys, done.
private struct ShortcutRecorder: View {
    let action: ShortcutAction
    @State private var recording = false
    @State private var monitor: Any?
    @State private var hovering = false
    @State private var rejected = false
    private var shortcuts: Shortcuts { Shortcuts.shared }

    var body: some View {
        let combo = shortcuts.combos[action]
        Button { recording ? stop() : begin() } label: {
            Text(recording ? (rejected ? "Add ⌃, ⌥ or ⌘" : "Press keys…") : (combo?.label ?? "None"))
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(recording ? 1 : (combo == nil ? 0.4 : 0.92)))
                .contentTransition(.opacity)
                .padding(.horizontal, 12)
                .frame(minWidth: 72, minHeight: 28)
                .background(Capsule().fill(recording ? Color.accentColor.opacity(0.55) : .white.opacity(hovering ? 0.16 : 0.1)))
                .overlay(Capsule().stroke(.white.opacity(recording ? 0.35 : 0.06)))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.2), value: recording)
        .animation(.smooth(duration: 0.2), value: combo)
        .animation(.smooth(duration: 0.15), value: rejected)
        .onDisappear { stop() }
    }

    private func begin() {
        shortcuts.recording = true   // also ends any other row's recording via its monitor check below
        recording = true
        rejected = false
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { event in
            if event.type == .leftMouseDown { stop(); return event }
            let plain = event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty
            if plain, event.keyCode == UInt16(kVK_Escape) { stop(); return nil }
            if plain, event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                shortcuts.set(nil, for: action); stop(); return nil
            }
            if let combo = KeyCombo(event: event) { shortcuts.set(combo, for: action); stop() }
            else { rejected = true }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording else { return }
        recording = false
        shortcuts.recording = false
    }
}
