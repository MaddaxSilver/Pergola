import SwiftUI
import CoreAudio

struct OutputDevice: Identifiable, Hashable {
    let id: AudioObjectID
    let name: String
    let transport: UInt32
    /// Core Audio's model ID; for Bluetooth it's "<productID> <vendorID>" in hex.
    var modelUID: String? = nil

    private var match: DeviceCatalog.Match {
        let ids = DeviceCatalog.ids(fromModelUID: modelUID)
        return DeviceCatalog.identify(name: name, vendorID: ids?.vendor, productID: ids?.product, transport: transport)
    }

    var symbol: String { match.symbol }
    /// The recognised model (e.g. "AirPods Pro 2"), when the device was identified by its hardware ID.
    var model: String? { match.model }
}

/// Lists audio outputs and switches the system's default output.
enum OutputDevices {
    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static var current: AudioObjectID {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return id
    }

    /// How long after the player sends a sample it's actually heard on the current output, in seconds
    /// (device + stream latency + safety offset). About 0.15–0.3 s on AirPods, a few ms on speakers.
    /// Lyrics are held back by this much so a line appears when it's sung, not before.
    /// Cached for a couple of seconds, since it's read many times a second.
    @MainActor static var currentLatency: Double {
        let now = Date()
        if now.timeIntervalSince(latencyCache.at) < 2 { return latencyCache.value }
        let device = current
        func frames(_ selector: AudioObjectPropertySelector) -> UInt32 {
            var addr = address(selector, kAudioObjectPropertyScopeOutput)
            var v: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            return AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &v) == noErr ? v : 0
        }
        var total = frames(kAudioDevicePropertyLatency) + frames(kAudioDevicePropertySafetyOffset)
        // The first output stream's own latency.
        var sAddr = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var sSize: UInt32 = 0
        if AudioObjectGetPropertyDataSize(device, &sAddr, 0, nil, &sSize) == noErr, sSize > 0 {
            var streams = [AudioStreamID](repeating: 0, count: Int(sSize) / MemoryLayout<AudioStreamID>.size)
            if AudioObjectGetPropertyData(device, &sAddr, 0, nil, &sSize, &streams) == noErr, let first = streams.first {
                var lAddr = address(kAudioStreamPropertyLatency)
                var l: UInt32 = 0
                var lSize = UInt32(MemoryLayout<UInt32>.size)
                if AudioObjectGetPropertyData(first, &lAddr, 0, nil, &lSize, &l) == noErr { total += l }
            }
        }
        var rAddr = address(kAudioDevicePropertyNominalSampleRate)
        var rate: Float64 = 0
        var rSize = UInt32(MemoryLayout<Float64>.size)
        AudioObjectGetPropertyData(device, &rAddr, 0, nil, &rSize, &rate)
        var value = rate > 0 ? min(0.6, Double(total) / rate) : 0
        // Bluetooth devices report far less than they really add (AirPods say ~10 ms; it's ~150–250 ms
        // from Mac to ear), so assume at least 0.18 s for them.
        var tAddr = address(kAudioDevicePropertyTransportType)
        var transport: UInt32 = 0
        var tSize = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &tAddr, 0, nil, &tSize, &transport)
        if transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE {
            value = max(value, 0.18)
        }
        latencyCache = (now, value)
        return value
    }
    @MainActor private static var latencyCache: (at: Date, value: Double) = (.distantPast, 0)

    static func all() -> [OutputDevice] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            // Only devices with output streams, and skip private/aggregate helpers like our own tap device.
            var streams = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
            var sSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &sSize) == noErr, sSize > 0 else { return nil }
            var tAddr = address(kAudioDevicePropertyTransportType)
            var transport: UInt32 = 0
            var tSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &tAddr, 0, nil, &tSize, &transport)
            if transport == kAudioDeviceTransportTypeAggregate || transport == kAudioDeviceTransportTypeVirtual { return nil }
            var nAddr = address(kAudioObjectPropertyName)
            var name: Unmanaged<CFString>?
            var nSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            guard AudioObjectGetPropertyData(id, &nAddr, 0, nil, &nSize, &name) == noErr, let name else { return nil }
            var mAddr = address(kAudioDevicePropertyModelUID)
            var model: Unmanaged<CFString>?
            var mSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let modelUID = AudioObjectGetPropertyData(id, &mAddr, 0, nil, &mSize, &model) == noErr
                ? model?.takeRetainedValue() as String? : nil
            return OutputDevice(id: id, name: name.takeRetainedValue() as String, transport: transport, modelUID: modelUID)
        }
    }

    static func select(_ id: AudioObjectID) {
        var id = id
        let size = UInt32(MemoryLayout<AudioObjectID>.size)
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = address(selector)
            AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, size, &id)
        }
    }
}

/// The right-hand control: shows where audio is playing and lets you switch it.
struct OutputDeviceButton: View {
    @State private var devices: [OutputDevice] = []
    @State private var currentID = OutputDevices.current
    @State private var hovering = false

    private var current: OutputDevice? { devices.first { $0.id == currentID } }

    var body: some View {
        Menu {
            ForEach(devices) { d in
                Button {
                    OutputDevices.select(d.id)
                    currentID = d.id
                } label: {
                    Label(d.model.map { d.name == $0 ? d.name : "\(d.name) — \($0)" } ?? d.name,
                          systemImage: d.id == currentID ? "checkmark" : d.symbol)
                }
            }
        } label: {
            Image(systemName: current?.symbol ?? "laptopcomputer")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(hovering ? 1 : 0.88))
                .frame(width: 34, height: 30)
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hovering = $0 }
        .help(current?.name ?? "Output")
        .onAppear(perform: reload)
    }

    private func reload() {
        devices = OutputDevices.all()
        currentID = OutputDevices.current
    }
}
