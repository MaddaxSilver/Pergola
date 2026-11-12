import SwiftUI
import CoreAudio

/// Mutes the Mac's own microphone, so it works for every call app at once. Uses the input device's
/// mute switch where it has one; otherwise turns its input volume to zero and back.
@Observable @MainActor
final class MicMute {
    private(set) var muted = false
    @ObservationIgnored private var savedVolume: Float32?
    /// Pergola muted it (so it's Pergola's to undo when the call ends).
    @ObservationIgnored private var mutedHere = false

    private static func defaultInput() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr, id != 0 else { return nil }
        return id
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
    }

    /// Reads the current state (another app may have muted or unmuted it).
    func refresh() {
        guard let device = Self.defaultInput() else { return }
        var a = Self.address(kAudioDevicePropertyMute)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &a), AudioObjectGetPropertyData(device, &a, 0, nil, &size, &value) == noErr {
            muted = value != 0
            return
        }
        var v = Self.address(kAudioDevicePropertyVolumeScalar)
        var volume: Float32 = 1
        var vsize = UInt32(MemoryLayout<Float32>.size)
        if AudioObjectGetPropertyData(device, &v, 0, nil, &vsize, &volume) == noErr { muted = volume < 0.001 }
    }

    func toggle() {
        guard let device = Self.defaultInput() else { return }
        let target = !muted
        defer { mutedHere = muted }
        var a = Self.address(kAudioDevicePropertyMute)
        var settable: DarwinBoolean = false
        if AudioObjectHasProperty(device, &a), AudioObjectIsPropertySettable(device, &a, &settable) == noErr, settable.boolValue {
            var value: UInt32 = target ? 1 : 0
            if AudioObjectSetPropertyData(device, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr {
                muted = target
                return
            }
        }
        // No mute switch: zero the input volume, and put it back afterwards.
        var v = Self.address(kAudioDevicePropertyVolumeScalar)
        var size = UInt32(MemoryLayout<Float32>.size)
        if target {
            var current: Float32 = 1
            if AudioObjectGetPropertyData(device, &v, 0, nil, &size, &current) == noErr, current > 0.001 { savedVolume = current }
            var zero: Float32 = 0
            if AudioObjectSetPropertyData(device, &v, 0, nil, size, &zero) == noErr { muted = true }
        } else {
            var restore: Float32 = savedVolume ?? 0.75
            if AudioObjectSetPropertyData(device, &v, 0, nil, size, &restore) == noErr { muted = false }
        }
    }

    /// The call ended: never leave the microphone muted behind, if Pergola is what muted it.
    func unmuteIfNeeded() {
        guard mutedHere else { return }
        refresh()
        if muted { toggle() }
        mutedHere = false
    }
}

/// The open notch during a call, like tapping the Dynamic Island: who, how long, and mute.
struct CallPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let call = model.activities.items.first(where: { $0.id == LiveWatcher.callID }) {
            HStack(spacing: 14) {
                ActivityGlyph(activity: call, size: 22)
                    .frame(width: 38, height: 38)
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                    ActivityClock(activity: call, size: 26)
                }
                Spacer(minLength: 8)
                CallButton(symbol: model.mic.muted ? "mic.slash.fill" : "mic.fill",
                           label: model.mic.muted ? "Unmute" : "Mute",
                           fill: model.mic.muted ? .white : .white.opacity(0.14),
                           ink: model.mic.muted ? .black : .white) {
                    model.mic.toggle()
                }
                if let app = call.appToOpen {
                    CallButton(symbol: "arrow.up.forward.app.fill", label: "Show",
                               fill: Color(red: 0.19, green: 0.82, blue: 0.35), ink: .white) {
                        NSWorkspace.shared.openApplication(at: app, configuration: .init())
                    }
                }
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onAppear { model.mic.refresh() }
        } else {
            Text("No Call")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct CallButton: View {
    var symbol: String
    var label: String
    var fill: Color
    var ink: Color
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(ink)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .background(Circle().fill(fill))
                .scaleEffect(hovering ? 1.06 : 1)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.spring(duration: 0.25, bounce: 0.3), value: hovering)
        .animation(.spring(duration: 0.3), value: symbol)
        .help(label)
        .accessibilityLabel(label)
    }
}
