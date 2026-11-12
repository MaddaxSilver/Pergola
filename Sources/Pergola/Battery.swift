import Foundation
import IOKit.ps

@Observable @MainActor
final class Battery {
    var hasBattery = false
    var percent = 100
    var charging = false
    var pluggedIn = false
    /// Minutes until the battery is full, once macOS has an estimate (it takes a little while after
    /// plugging in).
    var minutesToFull: Int?

    @ObservationIgnored var onPlugChange: ((Bool) -> Void)?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var started = false

    func start() {
        read(notify: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let me = Unmanaged<Battery>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.read(notify: true) }
        }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .defaultMode)
            source = src
        }
    }

    private func read(notify: Bool) {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let list = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(info, ps)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            hasBattery = true
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let max = d[kIOPSMaxCapacityKey] as? Int ?? 100
            percent = max > 0 ? Int((Double(cur) / Double(max) * 100).rounded()) : cur
            charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let full = d[kIOPSTimeToFullChargeKey] as? Int ?? -1
            minutesToFull = charging && full > 0 ? full : nil
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            if plugged != pluggedIn {
                pluggedIn = plugged
                if notify && plugged {
                    onPlugChange?(plugged)
                    // The time-to-full estimate arrives a few seconds after plugging in; look again so
                    // the line under the notch can fill it in while it's still showing.
                    for delay in [2.0, 4.0, 7.0] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.read(notify: false) }
                    }
                }
            }
        }
    }
}
