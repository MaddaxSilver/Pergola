import SwiftUI
import AppKit

final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the borderless panel that sits over the notch, and decides when it expands.
/// Hover is tracked by polling the mouse position, so the panel can ignore clicks
/// (and let them through to the menu bar) whenever it is collapsed.
@MainActor
final class NotchWindowController {
    private let model: AppModel
    private let panel: NotchPanel
    private var timer: Timer?
    private var clickMonitor: Any?
    private var hoverStart: Date?
    private var leaveStart: Date?
    private var lastFullscreenCheck = Date.distantPast
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var idleDragCount = 0
    private var draggingFiles = false
    private var openMenus = 0
    private var pressBeganInside = false
    private var wasButtonDown = false
    private var wasMouseDown = false
    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    private enum Axis { case horizontal, vertical }
    private var axis: Axis?
    private var velocity: CGFloat = 0
    private var lastScrollTime: TimeInterval = 0

    private var ui: NotchUI { model.ui }
    var contentView: NSView? { panel.contentView }

    init(model: AppModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero,
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        let host = NotchHostingView(rootView: AnyView(NotchRootView().environment(model)))
        host.model = model
        host.sizingOptions = []
        panel.contentView = host

        layout()
        panel.orderFrontRegardless()
        // Pin the panel in its own space so it stays put while you swipe between desktops.
        SkyLight.move(panel, toLevel: SkyLight.aboveDesktopsLevel)
        Log.notch.info("panel frame \(NSStringFromRect(self.panel.frame), privacy: .public) notch \(NSStringFromSize(self.ui.notchSize), privacy: .public)")

        // 120 Hz hover polling: the notch reacts within a frame of the pointer arriving.
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
        idleDragCount = dragPasteboard.changeCount
        // Menus opened from the notch (output picker, tray right-click) keep it open while they show.
        NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.ui.expanded == true { self?.openMenus += 1 } }
        }
        NotificationCenter.default.addObserver(forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { if let self, self.openMenus > 0 { self.openMenus -= 1 } }
        }
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
            return event
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.globalClick() }
        }

        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.layout() }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            wnc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.checkFullscreen(force: true) }
            }
        }
    }

    // MARK: Geometry

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var canvasSize: CGSize {
        let e = ui.maxExpandedSize
        // Extra room below for the file tray's water, which pours out of the open notch's edge.
        return CGSize(width: e.width + 2 * NotchMetrics.flare + 40, height: e.height + 30 + LiquidTray.roomBelow)
    }

    private func layout() {
        let s = screen
        if s.safeAreaInsets.top > 0, let l = s.auxiliaryTopLeftArea, let r = s.auxiliaryTopRightArea {
            ui.notchSize = CGSize(width: s.frame.width - l.width - r.width, height: s.safeAreaInsets.top)
            ui.hasNotch = true
        } else {
            ui.notchSize = CGSize(width: 190, height: max(24, NSStatusBar.system.thickness))
            ui.hasNotch = false
        }
        let c = canvasSize
        panel.setFrame(NSRect(x: s.frame.midX - c.width / 2, y: s.frame.maxY - c.height,
                              width: c.width, height: c.height), display: true)
        ui.panelFrame = panel.frame
    }

    /// The area (screen coordinates) that counts as "on the notch" while collapsed.
    private var collapsedHotRect: NSRect {
        let s = screen.frame
        var w = ui.notchSize.width
        if model.showsWings { w += 2 * model.closedWingWidth }
        // Generous margins so you don't have to hit the notch exactly.
        // The visible pill plus a small margin; the top edge counts (the pointer usually rests there).
        return NSRect(x: s.midX - w / 2 - 6, y: s.maxY - ui.notchSize.height - 6, width: w + 12, height: ui.notchSize.height + 6)
    }

    private var expandedHotRect: NSRect {
        let s = screen.frame
        let e = ui.expandedSize
        return NSRect(x: s.midX - e.width / 2 - 12, y: s.maxY - e.height - 16, width: e.width + 24, height: e.height + 16)
    }

    // MARK: Hover / click

    private let debugPinned = ProcessInfo.processInfo.environment["PERGOLA_PIN_EXPANDED"] != nil

    private func tick() {
        if debugPinned {
            if let t = ProcessInfo.processInfo.environment["PERGOLA_TAB"].flatMap(NotchTab.init(rawValue:)) { ui.tab = t }
            if let big = ProcessInfo.processInfo.environment["PERGOLA_BIGART"], !ui.bigArt {
                ui.bigArt = true
                ui.bigArtLyrics = big == "lyrics"
            }
            setExpanded(true); return
        }
        let noCapture = Prefs.d.bool(forKey: Prefs.hideFromCapture)
        if (panel.sharingType == .none) != noCapture { panel.sharingType = noCapture ? .none : .readOnly }
        checkFullscreen(force: false)
        trackFileDrag()
        guard !ui.hidden else { if ui.expanded { setExpanded(false) }; return }
        if ui.previewingGlass { if !ui.bigArt { ui.tab = .player }; setExpanded(true); leaveStart = nil; return }

        updateHover()
    }

    /// Hover state machine.
    ///  • Opens after the pointer rests on the notch briefly (so brushing past to a menu bar item doesn't).
    ///  • Stays open while the pointer is over the open notch, while one of its menus is showing, or while
    ///    a press/drag that started inside it is still held (scrubbing past the edge never closes it).
    ///  • Uses a slightly larger "stay" area than the "enter" area, so it can't flicker on the edge.
    ///  • Only reacts to the pointer on the notch's own screen.
    private func updateHover() {
        let mouse = NSEvent.mouseLocation
        let onScreen = screen.frame.insetBy(dx: -1, dy: -1).contains(mouse)
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1
        if !buttonDown { pressBeganInside = false }

        if ui.expanded {
            if buttonDown && !wasButtonDown && expandedHotRect.contains(mouse) { pressBeganInside = true }
            wasButtonDown = buttonDown
            // Once the pointer arrives on a keyboard-opened notch, the usual hover rules take over.
            if keyboardPinned, onScreen, expandedHotRect.contains(mouse) { keyboardPinned = false }
            let keepOpen = (onScreen && expandedHotRect.contains(mouse)) || openMenus > 0 || pressBeganInside || keyboardPinned
                // Dragging files, it stays open over a wide area around it (and below it, where it reaches out).
                || (draggingFiles && expandedHotRect.insetBy(dx: -260, dy: -260).contains(mouse))
            if keepOpen {
                leaveStart = nil
            } else {
                if leaveStart == nil { leaveStart = Date() }
                if Date().timeIntervalSince(leaveStart!) > 0.18 { setExpanded(false) }
            }
            return
        }
        wasButtonDown = buttonDown

        let inside = onScreen && collapsedHotRect.contains(mouse)
        let nearby = onScreen && collapsedHotRect.insetBy(dx: -8, dy: -6).contains(mouse)
        // Lift on approach; drop only once the pointer is clearly away (hysteresis, no flicker).
        if inside, !ui.hovering { withAnimation(Motion.hover) { ui.hovering = true } }
        if !nearby, ui.hovering { withAnimation(Motion.hover) { ui.hovering = false } }

        guard Prefs.d.bool(forKey: Prefs.expandOnHover), inside, !buttonDown else { hoverStart = nil; return }
        if hoverStart == nil { hoverStart = Date() }
        if Date().timeIntervalSince(hoverStart!) >= Prefs.d.double(forKey: Prefs.hoverDelay) {
            setExpanded(true)
        }
    }

    /// Dragging files over the notch opens the Files tray so they can be dropped in.
    private func trackFileDrag() {
        let mouseDown = NSEvent.pressedMouseButtons & 1 == 1
        if !mouseDown {
            // Dropped over the open tray: take the files straight from the drag pasteboard. This works
            // even if macOS doesn't route the drop to the notch window (it lives in its own space).
            if wasMouseDown, draggingFiles, ui.expanded, ui.tab == .tray,
               expandedHotRect.contains(NSEvent.mouseLocation),
               let urls = dragPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
               !urls.isEmpty {
                withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
                    model.tray.add(urls)
                    ui.dropTargeted = false
                }
                model.liquid.gulp()
            }
            // Only touch the drag pasteboard when the button is released, not 120 times a second.
            if wasMouseDown { idleDragCount = dragPasteboard.changeCount; model.liquid.endReach() }
            wasMouseDown = false
            draggingFiles = false
            return
        }
        wasMouseDown = true
        if !draggingFiles {
            guard Prefs.d.bool(forKey: Prefs.trayEnabled), Prefs.d.bool(forKey: Prefs.trayOpenOnDrag),
                  dragPasteboard.changeCount != idleDragCount,
                  dragPasteboard.types?.contains(.fileURL) == true else { return }
            draggingFiles = true
        }
        // Files dragged anywhere near the notch open the tray (a generous area, so you needn't aim).
        if !ui.expanded, collapsedHotRect.insetBy(dx: -120, dy: -90).contains(NSEvent.mouseLocation) {
            ui.bigArt = false
            ui.tab = .tray
            setExpanded(true)
        }
        // Below the open tray, its edge reaches out for the files.
        if ui.expanded, ui.tab == .tray { model.liquid.reach(toward: NSEvent.mouseLocation) }
        let over = ui.expanded && ui.tab == .tray && expandedHotRect.contains(NSEvent.mouseLocation)
        if over != ui.dropTargeted { withAnimation(.easeOut(duration: 0.15)) { ui.dropTargeted = over } }
    }

    /// Two-finger horizontal swipe pages between Files, Media and Weather.
    /// The strip tracks the fingers 1:1, rubber-bands past the ends, and on release settles with
    /// the release velocity, so it feels like a native iOS page view.
    private func handleScroll(_ e: NSEvent) {
        guard ui.expanded, !ui.bigArt, e.window === panel, Prefs.d.bool(forKey: Prefs.swipeToSkip),
              e.momentumPhase.isEmpty, e.hasPreciseScrollingDeltas else { return }
        let pages = ui.pages
        let index = pages.firstIndex(of: ui.tab) ?? 0
        let width = ui.expandedSize.width

        switch e.phase {
        case .began, .mayBegin:
            swipeX = 0; swipeY = 0; axis = nil; velocity = 0; lastScrollTime = e.timestamp
            return
        case .changed:
            swipeX += e.scrollingDeltaX
            swipeY += e.scrollingDeltaY
            if axis == nil, hypot(swipeX, swipeY) > 5 { axis = abs(swipeX) > abs(swipeY) ? .horizontal : .vertical }
            guard axis == .horizontal else { return }
            let dt = e.timestamp - lastScrollTime
            if dt > 0 { velocity = velocity * 0.6 + (e.scrollingDeltaX / CGFloat(dt)) * 0.4 }
            lastScrollTime = e.timestamp
            let pastStart = index == 0 && swipeX > 0
            let pastEnd = index == pages.count - 1 && swipeX < 0
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { ui.dragOffset = (pastStart || pastEnd) ? Self.rubberBand(swipeX, width) : swipeX }
        case .ended, .cancelled:
            guard axis == .horizontal else { return }
            // Where the strip would coast to, like UIScrollView's projected offset.
            let projected = ui.dragOffset + velocity * 0.18
            var target = index
            if projected < -width * 0.3, index < pages.count - 1 { target = index + 1 }
            if projected > width * 0.3, index > 0 { target = index - 1 }
            // Re-express the current position relative to the target page, then spring to it.
            let remaining = ui.dragOffset + CGFloat(target - index) * width
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                ui.tab = pages[target]
                ui.dragOffset = remaining
            }
            withAnimation(Motion.pageSettle(velocity: velocity, distance: remaining)) { ui.dragOffset = 0 }
            if target != index, Prefs.d.bool(forKey: Prefs.haptics) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            axis = nil
        default:
            break
        }
    }

    /// iOS rubber-band: resistance grows the further you pull past the edge.
    private static func rubberBand(_ x: CGFloat, _ dimension: CGFloat) -> CGFloat {
        let c: CGFloat = 0.55
        let d = abs(x)
        return (1 - 1 / (d * c / dimension + 1)) * dimension * (x < 0 ? -1 : 1)
    }

    // MARK: Keyboard

    /// The notch was opened by a shortcut: it stays open without the pointer on it.
    private(set) var keyboardPinned = false {
        didSet { if keyboardPinned != oldValue { onKeyboardPin?(keyboardPinned) } }
    }
    var onKeyboardPin: ((Bool) -> Void)?

    func keyboardToggle() {
        guard !ui.hidden, !ui.locked else { return }
        if ui.expanded { setExpanded(false) } else { keyboardPinned = true; setExpanded(true) }
    }

    func keyboardClose() {
        if ui.expanded { setExpanded(false) }
    }

    /// Opens the enlarged album-art view (opening the notch first if needed), or leaves it.
    func keyboardBigArt() {
        guard !ui.hidden, !ui.locked, model.player.hasTrack else { return }
        if !ui.expanded {
            ui.tab = .player
            ui.bigArt = true
            keyboardPinned = true
            setExpanded(true)
        } else {
            withAnimation(ui.bigArt ? Motion.collapse : Motion.expand) {
                if !ui.bigArt { ui.tab = .player }
                ui.bigArt.toggle()
            }
        }
    }

    /// Moves a page left or right; opens the notch if it's closed.
    func keyboardPage(_ step: Int) {
        guard !ui.hidden, !ui.locked else { return }
        guard ui.expanded else { keyboardPinned = true; setExpanded(true); return }
        let pages = ui.pages
        guard !ui.bigArt, let i = pages.firstIndex(of: ui.tab), pages.indices.contains(i + step) else { return }
        withAnimation(Motion.content) { ui.tab = pages[i + step] }
    }

    private func globalClick() {
        if ui.expanded, keyboardPinned, !expandedHotRect.contains(NSEvent.mouseLocation) { setExpanded(false); return }
        guard !ui.hidden, !ui.expanded, collapsedHotRect.contains(NSEvent.mouseLocation) else { return }
        setExpanded(true)
    }

    private func setExpanded(_ expanded: Bool) {
        guard ui.expanded != expanded else { return }
        Log.notch.info("setExpanded(\(expanded, privacy: .public))")
        hoverStart = nil
        leaveStart = nil
        if expanded {
            ui.peek = nil
            if Prefs.d.bool(forKey: Prefs.haptics) {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
            model.player.syncPosition()
        }
        if !expanded { keyboardPinned = false }
        withAnimation(expanded ? Motion.expand : Motion.collapse) {
            ui.expanded = expanded
            ui.hovering = false
            if !expanded { ui.dragOffset = 0; ui.bigArt = false; ui.dropTargeted = false }
        }
        panel.ignoresMouseEvents = !expanded
    }

    // MARK: Fullscreen

    private func checkFullscreen(force: Bool) {
        guard force || Date().timeIntervalSince(lastFullscreenCheck) > 1.0 else { return }
        lastFullscreenCheck = Date()
        guard Prefs.d.bool(forKey: Prefs.hideInFullscreen) else { applyFullscreen(false); return }
        guard let front = NSWorkspace.shared.frontmostApplication,
              front.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              let primary = NSScreen.screens.first else { applyFullscreen(false); return }
        let sf = screen.frame
        let target = CGRect(x: sf.minX, y: primary.frame.height - sf.maxY, width: sf.width, height: sf.height)
        let pid = front.processIdentifier
        // Listing every window takes several milliseconds: do it off the main thread so it can't drop
        // a frame of an animation that happens to be running.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hide = Self.isFullscreen(pid: pid, target: target)
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.applyFullscreen(hide) } }
        }
    }

    private func applyFullscreen(_ hide: Bool) {
        if hide != ui.hidden {
            withAnimation(.easeInOut(duration: 0.2)) { ui.hidden = hide }
            panel.alphaValue = hide ? 0 : 1
        }
    }

    nonisolated private static func isFullscreen(pid: pid_t, target: CGRect) -> Bool {
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for w in windows {
            guard (w[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String],
                  let rect = CGRect(dictionaryRepresentation: b as! CFDictionary) else { continue }
            if rect.equalTo(target) { return true }
        }
        return false
    }
}

/// Hosts the notch's SwiftUI view and accepts file drops at the AppKit level. SwiftUI's own drop
/// handling isn't reliable in a borderless, non-activating panel, so the tray gets files from here.
final class NotchHostingView: NSHostingView<AnyView> {
    weak var model: AppModel?

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL])
    }

    @MainActor required dynamic init?(coder: NSCoder) { fatalError("not used") }

    private func fileURLs(_ info: NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let model, Prefs.d.bool(forKey: Prefs.trayEnabled), !fileURLs(sender).isEmpty else { return [] }
        withAnimation(Motion.content) {
            model.ui.bigArt = false
            model.ui.tab = .tray
            model.ui.dropTargeted = true
        }
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        model?.ui.dropTargeted == true ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        withAnimation(.easeOut(duration: 0.15)) { model?.ui.dropTargeted = false }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard let model, !urls.isEmpty else { return false }
        withAnimation(.spring(duration: 0.35, bounce: 0.25)) {
            model.tray.add(urls)
            model.ui.dropTargeted = false
        }
        model.liquid.gulp()
        if Prefs.d.bool(forKey: Prefs.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        return true
    }
}
