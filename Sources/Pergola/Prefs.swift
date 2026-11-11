import Foundation

/// Every user setting, in one place. Views read these with @AppStorage(Prefs.x).
enum Prefs {
    // Notch
    static let expandOnHover = "expandOnHover"
    static let hoverDelay = "hoverDelay"
    static let hideInFullscreen = "hideInFullscreen"
    static let haptics = "haptics"
    static let liquidGlass = "liquidGlass"
    static let glassDarkness = "glassDarkness"
    // Music
    static let playerSource = "playerSource"          // auto | music | spotify
    static let liveWaveform = "liveWaveform"
    static let collapseOnPause = "collapseOnPause"
    static let leftButton = "leftButton"              // shuffle | repeat
    static let colorMatch = "colorMatch"
    // Weather
    static let weatherEnabled = "weatherEnabled"
    static let weatherCity = "weatherCity"
    static let fahrenheit = "fahrenheit"
    // Battery & overlays
    static let chargingOverlay = "chargingOverlay"
    static let accessoryOverlay = "accessoryOverlay"
    static let swipeToSkip = "swipeToSkip"
    static let hideFromCapture = "hideFromCapture"
    static let mediaPlayer = "mediaPlayer"
    // Sensory (volume / brightness HUD)
    static let sensoryVolume = "sensoryVolume"
    static let sensoryBrightness = "sensoryBrightness"
    static let sensoryStyle = "sensoryStyle"          // notch | apple
    static let sensoryLabel = "sensoryLabel"          // icon | name
    static let sensoryColorMatch = "sensoryColorMatch"
    static let sensorySeconds = "sensorySeconds"
    // Accessories / Focus
    static let outputOverlay = "outputOverlay"
    static let focusOverlay = "focusOverlay"
    static let focusShowsBattery = "focusShowsBattery"
    static let focusShowsAccessories = "focusShowsAccessories"
    static let focusShowsSensory = "focusShowsSensory"
    // Lyrics & lock screen
    static let lyricsOffsetMs = "lyricsOffsetMs"
    static let lockScreen = "lockScreen"
    static let lockGlassStyle = "lockGlassStyle"      // clear | frosted
    static let lockFullArt = "lockFullArt"
    static let lockLyrics = "lockLyrics"
    static let lockGlassArt = "lockGlassArt"
    static let lockGlassCard = "lockGlassCard"
    static let lockKeepAwake = "lockKeepAwake"
    static let lockKeepAwakeMinutes = "lockKeepAwakeMinutes"
    static let lockSound = "lockSound"
    static let unlockSound = "unlockSound"
    static let lockSoundVolume = "lockSoundVolume"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let launchAtLogin = "launchAtLogin"
    static let trayEnabled = "trayEnabled"
    static let trayOpenOnDrag = "trayOpenOnDrag"
    static let bigArtLyrics = "bigArtLyrics"
    static let calendarEnabled = "calendarEnabled"
    static let calendarHidden = "calendarHidden"     // [calendar identifier]
    static let calendarDays = "calendarDays"
    static let trackOverlay = "trackOverlay"
    static let overlaySeconds = "overlaySeconds"

    static let shortcutsEnabled = "shortcutsEnabled"
    static let shortcuts = "shortcuts"               // [action: {code, mods, key}]
    static let activitiesEnabled = "activitiesEnabled"
    static let ringsPage = "ringsPage"
    static let callTimer = "callTimer"
    static let clockTimers = "clockTimers"
    static let activityOverlay = "activityOverlay"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            activitiesEnabled: true,
            ringsPage: true,
            callTimer: true,
            clockTimers: true,
            shortcutsEnabled: true,
            activityOverlay: true,
            expandOnHover: true,
            hoverDelay: 0.08,
            hideInFullscreen: true,
            haptics: true,
            liquidGlass: true,
            glassDarkness: 0.85,
            playerSource: "auto",
            liveWaveform: true,
            collapseOnPause: false,
            leftButton: "shuffle",
            colorMatch: true,
            weatherEnabled: true,
            weatherCity: "",
            fahrenheit: Locale.current.measurementSystem == .us,
            chargingOverlay: true,
            accessoryOverlay: true,
            swipeToSkip: true,
            hideFromCapture: false,
            mediaPlayer: true,
            sensoryVolume: true,
            sensoryBrightness: true,
            sensoryStyle: "notch",
            sensoryLabel: "icon",
            sensoryColorMatch: true,
            sensorySeconds: 2.0,
            outputOverlay: true,
            focusOverlay: true,
            focusShowsBattery: true,
            focusShowsAccessories: true,
            focusShowsSensory: true,
            lyricsOffsetMs: 0.0,
            lockScreen: true,
            lockGlassStyle: "clear",
            lockFullArt: true,
            lockLyrics: true,
            lockGlassArt: true,
            lockGlassCard: true,
            lockKeepAwake: false,
            lockKeepAwakeMinutes: 5.0,
            lockSound: false,
            unlockSound: false,
            lockSoundVolume: 0.6,
            showMenuBarIcon: true,
            launchAtLogin: true,
            trayEnabled: true,
            trayOpenOnDrag: true,
            bigArtLyrics: true,
            calendarEnabled: true,
            calendarHidden: [String](),
            calendarDays: 3,
            trackOverlay: true,
            overlaySeconds: 3.0,
        ])
    }

    static var d: UserDefaults { .standard }
}
