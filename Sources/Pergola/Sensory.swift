import AppKit
import CoreAudio
import ApplicationServices
import AudioToolbox

/// "Sensory": volume and brightness keys show Pergola's overlay instead of the system one.
///
/// Pergola listens for the media keys with an event tap (needs Accessibility), sets the level
/// itself, and swallows the key so macOS doesn't draw its own HUD on top.
@Observable @MainActor
final class Sensory {
    enum Kind: Equatable { case volume, brightness }

    private(set) var accessibilityGranted = AXIsProcessTrusted()
    private(set) var tapRunning = false
    @ObservationIgnored var onChange: ((Kind, Float, Bool) -> Void)? // kind, level 0...1, muted
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var retryTimer: Timer?

    func start() {
        retryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }
        reconcile()
    }

    /// Ask macOS for Accessibility access (shows the system prompt once).
    func requestAccess() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityGranted = AXIsProcessTrustedWithOptions(opts)
    }

    private var wanted: Bool {
        Prefs.d.bool(forKey: Prefs.sensoryVolume) || Prefs.d.bool(forKey: Prefs.sensoryBrightness)
    }

    private func reconcile() {
        accessibilityGranted = AXIsProcessTrusted()
        if wanted && accessibilityGranted && tap == nil { installTap() }
        if (!wanted || !accessibilityGranted), tap != nil { removeTap() }
        if let tap, !CGEvent.tapIsEnabled(tap: tap) { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func installTap() {
        let mask = CGEventMask(1) << 14 // NX_SYSDEFINED
        let callback: CGEventTapCallBack = { _, type, event, info in
            guard let info else { return Unmanaged.passUnretained(event) }
            let me = Unmanaged<Sensory>.fromOpaque(info).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                DispatchQueue.main.async { if let t = me.tap { CGEvent.tapEnable(tap: t, enable: true) } }
                return Unmanaged.passUnretained(event)
            }
            return MainActor.assumeIsolated { me.handle(event) } ? nil : Unmanaged.passUnretained(event)
        }
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                        eventsOfInterest: mask, callback: callback,
                                        userInfo: Unmanaged.passUnretained(self).toOpaque()) else { return }
        tap = t
        source = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
        tapRunning = true
    }

    private func removeTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil; tapRunning = false
    }

    /// Returns true when Pergola handled the key (so it's swallowed).
    private func handle(_ cg: CGEvent) -> Bool {
        guard let e = NSEvent(cgEvent: cg), e.subtype.rawValue == 8 else { return false }
        let key = Int32((e.data1 & 0xFFFF0000) >> 16)
        let down = ((e.data1 & 0xFF00) >> 8) == 0xA
        // Option+Shift gives quarter steps, like macOS.
        let fine = e.modifierFlags.contains(.option) && e.modifierFlags.contains(.shift)
        let step: Float = fine ? 1.0 / 64 : 1.0 / 16

        switch key {
        case 0, 1, 7: // sound up, down, mute
            // Leave the key to macOS if Pergola's volume overlay is off, or the device has no settable volume.
            guard Prefs.d.bool(forKey: Prefs.sensoryVolume), SystemVolume.isControllable else { return false }
            guard down else { return true }
            if key == 7 {
                SystemVolume.muted.toggle()
            } else {
                if SystemVolume.muted { SystemVolume.muted = false }
                SystemVolume.level = max(0, min(1, SystemVolume.level + (key == 0 ? step : -step)))
            }
            onChange?(.volume, SystemVolume.level, SystemVolume.muted)
            return true
        case 2, 3: // brightness up, down
            guard Prefs.d.bool(forKey: Prefs.sensoryBrightness), let current = Brightness.level else { return false }
            guard down else { return true }
            Brightness.level = max(0, min(1, current + (key == 2 ? step : -step)))
            onChange?(.brightness, Brightness.level ?? current, false)
            return true
        default:
            return false
        }
    }
}

/// Output volume of the default device through Core Audio.
enum SystemVolume {
    private static var device: AudioObjectID {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// False for outputs whose volume macOS can't set (some HDMI / USB devices).
    static var isControllable: Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                              mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(device, &addr) && AudioObjectIsPropertySettable(device, &addr, &settable) == noErr && settable.boolValue
    }

    static var level: Float {
        get {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var v: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v)
            return v
        }
        set {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var v = Float32(newValue)
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &v)
        }
    }

    static var muted: Bool {
        get {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v)
            return v != 0
        }
        set {
            var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                                  mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
            var v: UInt32 = newValue ? 1 : 0
            AudioObjectSetPropertyData(device, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &v)
        }
    }
}

/// Built-in display brightness through macOS's DisplayServices (private, loaded at runtime).
enum Brightness {
    private typealias Get = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias Set = @convention(c) (CGDirectDisplayID, Float) -> Int32

    private static let handle = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
    private static let getFn: Get? = handle.flatMap { dlsym($0, "DisplayServicesGetBrightness") }.map { unsafeBitCast($0, to: Get.self) }
    private static let setFn: Set? = handle.flatMap { dlsym($0, "DisplayServicesSetBrightness") }.map { unsafeBitCast($0, to: Set.self) }

    private static var display: CGDirectDisplayID {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        CGGetOnlineDisplayList(16, &ids, &count)
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 } ?? CGMainDisplayID()
    }

    static var level: Float? {
        get {
            var v: Float = 0
            guard let getFn, getFn(display, &v) == 0 else { return nil }
            return v
        }
        set {
            guard let newValue, let setFn else { return }
            _ = setFn(display, newValue)
        }
    }
}

import SwiftUI

/// Icon (or name, per Settings) for a volume/brightness overlay.
struct SensoryLabel: View {
    var kind: Sensory.Kind
    var level: Float
    var muted: Bool
    @AppStorage(Prefs.sensoryLabel) private var label = "icon"

    static func symbol(_ kind: Sensory.Kind, _ level: Float, _ muted: Bool) -> String {
        switch kind {
        case .brightness: return level < 0.35 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if muted || level == 0 { return "speaker.slash.fill" }
            return level < 0.34 ? "speaker.wave.1.fill" : (level < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill")
        }
    }

    var body: some View {
        if label == "name" {
            Text(kind == .volume ? "Volume" : "Display")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
        } else {
            Image(systemName: Self.symbol(kind, level, muted))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 26)
        }
    }
}

/// A slim capsule meter that glides to the new level.
struct SensoryBar: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.sensoryColorMatch) private var colorMatch = true
    var level: Float

    var body: some View {
        let tint: Color = colorMatch && model.player.isPlaying ? model.player.accent : .white
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Capsule().fill(tint).frame(width: max(0, geo.size.width * CGFloat(level)))
            }
        }
        .animation(.spring(duration: 0.28, bounce: 0), value: level)
    }
}

/// "Apple Style": a Liquid Glass capsule under the notch, like the macOS 26 volume HUD.
struct AppleStyleHUD: View {
    var kind: Sensory.Kind
    var level: Float
    var muted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: SensoryLabel.symbol(kind, level, muted))
                .font(.system(size: 16, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 24)
            SensoryBar(level: muted ? 0 : level).frame(height: 7)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .frame(width: 230, height: 46)
        .glassEffect(.regular.tint(.black.opacity(0.5)), in: Capsule())
    }
}
