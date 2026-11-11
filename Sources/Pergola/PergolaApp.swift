import SwiftUI
import AppKit

@main
struct PergolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @AppStorage(Prefs.showMenuBarIcon) private var showMenuBarIcon = true

    init() {
        // `Pergola --write-icon <path>` renders the app icon (used by build.sh), then exits.
        let args = CommandLine.arguments
        // `Pergola --mcp`, `--activity`, `--claude-hook`: talk to the running app, then exit.
        PergolaCLI.runIfNeeded(args)
        if let i = args.firstIndex(of: "--write-icon"), i + 1 < args.count {
            do { try PergolaIcon.writeIcns(to: URL(fileURLWithPath: args[i + 1])); exit(0) } catch { exit(1) }
        }
    }

    var body: some Scene {
        MenuBarExtra(isInserted: $showMenuBarIcon) {
            Button("Settings…") { AppDelegate.openSettings() }
                .keyboardShortcut(",")
            Divider()
            Button("Quit Pergola") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        } label: {
            Image(nsImage: PergolaIcon.menuBar)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var notch: NotchWindowController?
    private var lockScreen: LockScreenController?

    /// SwiftUI wraps the app delegate, so `NSApp.delegate` isn't this object; keep our own reference.
    private(set) static weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        Prefs.registerDefaults()
        NSApp.setActivationPolicy(.accessory)
        notch = NotchWindowController(model: model)
        model.start()
        lockScreen = LockScreenController(model: model)
        lockScreen?.start()
        LoginItem.shared.apply()
        Shortcuts.shared.start(model: model, notch: notch)
        FrameMeter.runIfAsked(notch: notch, view: notch?.contentView)
        if ProcessInfo.processInfo.environment["PERGOLA_SETTINGS_PAGE"] != nil {
            DispatchQueue.main.async { AppDelegate.openSettings() }
        }
    }

    /// Opening Pergola again (e.g. from Finder) shows Settings, so it's reachable without the menu bar icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        AppDelegate.openSettings()
        return false
    }

    private static var settingsWindow: NSWindow?

    /// Pergola manages its own Settings window so it opens reliably from the menu, from Finder
    /// and from the notch (SwiftUI's Settings scene can't be opened programmatically anymore).
    static func openSettings() {
        guard let delegate = AppDelegate.shared else { return }
        if settingsWindow == nil {
            // Open as tall as fits comfortably on this screen (up to 760 pt), never taller than it.
            let visible = (NSScreen.main ?? NSScreen.screens[0]).visibleFrame
            let size = NSSize(width: 760, height: min(760, visible.height - 60))
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.titleVisibility = .hidden
            w.titlebarAppearsTransparent = true
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            let host = NSHostingController(rootView: SettingsView().environment(delegate.model))
            host.sizingOptions = [.minSize] // SwiftUI sets the minimum; the window keeps the size it's given
            w.contentViewController = host
            w.setContentSize(size)
            w.contentMinSize = NSSize(width: 700, height: 540)
            w.setFrameAutosaveName("PergolaSettings")
            if !w.setFrameUsingName("PergolaSettings") { w.center() }
            settingsWindow = w
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Never leave a capture running behind us.
        model.waveform.shutdown()
    }
}
