import SwiftUI
import IOBluetooth

struct Accessory: Equatable, Identifiable {
    let id: String
    let name: String
    let symbol: String
    var left: Int?
    var right: Int?
    var caseLevel: Int?
    var single: Int?

    /// The battery figures worth showing, as (label, percent).
    var levels: [(String, Int)] {
        var out: [(String, Int)] = []
        if let left { out.append(("L", left)) }
        if let right { out.append(("R", right)) }
        if let caseLevel { out.append(("Case", caseLevel)) }
        if out.isEmpty, let single { out.append(("", single)) }
        return out
    }

    /// The lowest earbud, or the single battery; used in the collapsed wing.
    var headline: Int? { [left, right].compactMap { $0 }.min() ?? single }
}

/// Watches Bluetooth connections so Pergola can show a "connected" overlay with battery levels.
@Observable @MainActor
final class Accessories: NSObject {
    private(set) var connected: [Accessory] = []
    @ObservationIgnored var onConnect: ((Accessory) -> Void)?
    @ObservationIgnored private var startedAt = Date()
    @ObservationIgnored private var connectNote: IOBluetoothUserNotification?
    @ObservationIgnored private var lastDisconnect: [String: Date] = [:]
    @ObservationIgnored private var lastShown: [String: Date] = [:]
    @ObservationIgnored private var quietUntil = Date()

    func start() {
        startedAt = Date()
        // Learn every paired device's hardware model, so renamed AirPods still get the right icon.
        DeviceCatalog.refreshBluetooth { DispatchQueue.main.async { MainActor.assumeIsolated { self.refreshBatteries() } } }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
        // Everything re-links right after the Mac wakes; that isn't news.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietUntil = Date().addingTimeInterval(20) }
        }
    }

    /// AirPods drop and re-link with the Mac all the time (switching to the phone, going idle, coming
    /// back into use). Only a real arrival is worth an overlay: the device was away for 2+ minutes,
    /// and it hasn't been announced in the last 10.
    private func worthAnnouncing(_ id: String) -> Bool {
        let now = Date()
        if now < quietUntil { return false }
        if let gone = lastDisconnect[id], now.timeIntervalSince(gone) < 120 { return false }
        if let shown = lastShown[id], now.timeIntervalSince(shown) < 600 { return false }
        return true
    }

    @objc private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:)))
        let launching = Date().timeIntervalSince(startedAt) < 3 // devices already connected at launch
        let id = device.addressString ?? device.name ?? ""
        let announce = !launching && worthAnnouncing(id)
        // AirPods report battery a moment after the link comes up: try at 1.5 s, then once more at 3.5 s.
        func settle(_ attempt: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + (launching ? 0 : (attempt == 0 ? 1.5 : 2))) { [weak self] in
                guard let self, device.isConnected() else { return }
                let acc = Self.describe(device)
                self.connected.removeAll { $0.id == acc.id }
                self.connected.append(acc)
                guard announce else { return }
                if acc.headline == nil, attempt == 0 { settle(1); return }
                self.lastShown[acc.id] = Date()
                self.onConnect?(acc)
            }
        }
        settle(0)
    }

    @objc private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        note.unregister()
        let id = device.addressString ?? device.name ?? ""
        lastDisconnect[id] = Date()
        connected.removeAll { $0.id == id }
    }

    func refreshBatteries() {
        connected = connected.map { acc in
            guard let dev = IOBluetoothDevice(addressString: acc.id) else { return acc }
            return Self.describe(dev)
        }
    }

    private static func describe(_ d: IOBluetoothDevice) -> Accessory {
        let name = d.name ?? "Bluetooth device"
        return Accessory(id: d.addressString ?? name, name: name, symbol: symbol(for: d, name: name),
                         left: battery(d, "batteryPercentLeft"), right: battery(d, "batteryPercentRight"),
                         caseLevel: battery(d, "batteryPercentCase"), single: battery(d, "batteryPercentSingle"))
    }

    /// macOS exposes AirPods/Beats battery levels as undocumented properties; read them only if present.
    private static func battery(_ d: IOBluetoothDevice, _ key: String) -> Int? {
        guard d.responds(to: NSSelectorFromString(key)),
              let n = d.value(forKey: key) as? NSNumber, n.intValue > 0, n.intValue <= 100 else { return nil }
        return n.intValue
    }

    private static func symbol(for d: IOBluetoothDevice, name: String) -> String {
        let info = d.addressString.flatMap(DeviceCatalog.bluetoothInfo(address:))
        return DeviceCatalog.identify(name: name, vendorID: info?.vendor, productID: info?.product,
                                      minorType: info?.minor ?? (d.deviceClassMajor == kBluetoothDeviceClassMajorAudio ? "headphones" : nil)).symbol
    }
}

struct BatteryRing: View {
    var label: String
    var percent: Int

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                Circle().stroke(.white.opacity(0.16), lineWidth: 2.4)
                Circle().trim(from: 0, to: CGFloat(percent) / 100)
                    .stroke(percent <= 20 ? Color.red : Color.green, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(label.isEmpty ? "\(percent)%" : "\(label) \(percent)%")
                .font(.system(size: 12, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
        }
    }
}
