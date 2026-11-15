import AppKit
import IOKit
import os

/// Notices USB devices being plugged in and taken out (an iPhone, a drive, a keyboard, a dock), for the
/// Connections line under the notch. Needs no permissions: macOS tells any app about USB devices.
///
/// Devices don't arrive cleanly: an iPhone attaches, drops off a tenth of a second later and attaches
/// again over a second after that (and does the same when it's unlocked or trusted). So nothing is said
/// per event. Once USB has been quiet for a moment, what's plugged in is compared with what was last
/// shown, and only the difference is announced.
///
///  • What was plugged in before Pergola started isn't announced.
///  • Hubs and the Mac's own built-in parts are skipped.
///  • A dock brings several devices at once: they're shown as one line ("CalDigit TS4 and 3 more").
///  • A device that drops off and comes back within the quiet moment isn't announced either way.
@MainActor
final class USBDevices {
    var onChange: ((_ name: String, _ symbol: String, _ on: Bool) -> Void)?

    private struct Device { var name: String; var symbol: String; var key: String }

    private var port: IONotificationPortRef?
    private var added: io_iterator_t = 0
    private var removed: io_iterator_t = 0
    /// Every USB device present, by registry ID (also the ones not worth announcing, as nil).
    private var present: [UInt64: Device?] = [:]
    /// The devices the user was last told about (by vendor, product and serial), in the order they came.
    private var shown: [String: Device] = [:]
    private var settle: DispatchWorkItem?
    /// How long USB must stay quiet before anything is said: longer than an iPhone's re-attach.
    private static let quietTime = 2.0
    /// Everything re-attaches when the Mac wakes; that isn't news.
    private var quietUntil = Date()

    func start() {
        guard port == nil, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(port).takeUnretainedValue(), .defaultMode)
        let me = Unmanaged.passUnretained(self).toOpaque()

        IOServiceAddMatchingNotification(port, kIOFirstMatchNotification, IOServiceMatching("IOUSBHostDevice"), { refcon, iterator in
            guard let refcon else { return }
            MainActor.assumeIsolated { Unmanaged<USBDevices>.fromOpaque(refcon).takeUnretainedValue().didAdd(iterator) }
        }, me, &added)
        IOServiceAddMatchingNotification(port, kIOTerminatedNotification, IOServiceMatching("IOUSBHostDevice"), { refcon, iterator in
            guard let refcon else { return }
            MainActor.assumeIsolated { Unmanaged<USBDevices>.fromOpaque(refcon).takeUnretainedValue().didRemove(iterator) }
        }, me, &removed)

        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietUntil = Date().addingTimeInterval(15) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.quietUntil = .distantFuture }
        }

        // Arm both notifications by reading what's there now; that is only remembered.
        didAdd(added)
        didRemove(removed)
        settle?.cancel()
        settle = nil
        shown = current()
    }

    private func didAdd(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            let device = Self.describe(service)
            present[id] = device
            Log.connections.info("usb added \(device?.name ?? "(skipped)", privacy: .public)")
        }
        scheduleSettle()
    }

    private func didRemove(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var id: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &id)
            guard let entry = present.removeValue(forKey: id) else { continue }
            Log.connections.info("usb removed \(entry?.name ?? "(skipped)", privacy: .public)")
        }
        scheduleSettle()
    }

    /// Every event restarts the wait, so a burst of them is judged once, after it's over.
    private func scheduleSettle() {
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.settled() } }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.quietTime, execute: work)
    }

    /// The devices plugged in now, by key.
    private func current() -> [String: Device] {
        var out: [String: Device] = [:]
        for case let device? in present.values { out[device.key] = device }
        return out
    }

    private func settled() {
        settle = nil
        // Read each device again now that it has published its interfaces (which say what it is).
        for (id, entry) in present where entry != nil {
            let service = IOServiceGetMatchingService(kIOMainPortDefault, IORegistryEntryIDMatching(id))
            guard service != 0 else { continue }
            if let fresh = Self.describe(service) { present[id] = fresh }
            IOObjectRelease(service)
        }
        let now = current()
        let arrived = now.values.filter { shown[$0.key] == nil }.sorted { $0.name < $1.name }
        let left = shown.values.filter { now[$0.key] == nil }.sorted { $0.name < $1.name }
        shown = now
        guard Date() >= quietUntil else { return }
        // Something new plugged in is the news; if only things went, say that.
        if let first = arrived.first {
            Log.connections.info("usb announce connected \(first.name, privacy: .public) (+\(arrived.count - 1))")
            onChange?(Self.together(first.name, arrived.count), first.symbol, true)
        } else if let first = left.first {
            Log.connections.info("usb announce gone \(first.name, privacy: .public) (+\(left.count - 1))")
            onChange?(Self.together(first.name, left.count), first.symbol, false)
        }
    }

    private static func together(_ name: String, _ count: Int) -> String {
        count > 1 ? "\(name) and \(count - 1) more" : name
    }

    // MARK: What a device is

    private static func property(_ s: io_service_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(s, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// The device's name and icon, or nil for hubs and the Mac's own parts.
    private static func describe(_ s: io_service_t) -> Device? {
        let product = (property(s, "USB Product Name") as? String ?? property(s, "kUSBProductString") as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        let vendor = (property(s, "USB Vendor Name") as? String ?? "").trimmingCharacters(in: .whitespaces)
        let deviceClass = (property(s, "bDeviceClass") as? NSNumber)?.intValue ?? 0
        let builtIn = (property(s, "Built-In") as? Bool) == true
            || (property(s, "non-removable") as? String)?.lowercased() == "yes"
        let lower = product.lowercased()
        if deviceClass == 9 || builtIn || product.isEmpty
            || ["hub", "billboard", "bridge", "host controller", "usb controller", "t2 controller"].contains(where: lower.contains) {
            return nil
        }
        // A vague name ("USB Storage", "Flash Disk", "Receiver") means more with its maker in front;
        // a real product name ("iPhone", "T7 Shield", "Scarlett 2i2") is left as it is.
        var name = product
        let maker = vendor.replacingOccurrences(of: " Inc.", with: "").replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespaces)
        let vague = ["usb", "storage", "disk", "flash", "device", "drive", "receiver", "keyboard", "mouse",
                     "camera", "audio", "composite", "mass", "gadget", "adapter", "reader"]
        let vid = (property(s, "idVendor") as? NSNumber)?.intValue ?? 0
        if !maker.isEmpty, vid != 0x05AC, product.count <= 20,
           vague.contains(where: lower.contains),
           !lower.contains(maker.lowercased().split(separator: " ").first.map(String.init) ?? "~") {
            name = "\(maker) \(product)"
        }
        let pid = (property(s, "idProduct") as? NSNumber)?.intValue ?? 0
        let serial = property(s, "USB Serial Number") as? String ?? "\((property(s, "locationID") as? NSNumber)?.intValue ?? 0)"
        return Device(name: name, symbol: symbol(name: lower, service: s, deviceClass: deviceClass),
                      key: "\(vid):\(pid):\(serial)")
    }

    private static func symbol(name: String, service s: io_service_t, deviceClass: Int) -> String {
        let n = " \(name) "
        let words: [(words: [String], symbol: String)] = [
            (["iphone"], "iphone"), (["ipad"], "ipad"), (["watch"], "applewatch"), (["ipod"], "ipod"),
            (["keyboard"], "keyboard"), (["mouse", "trackpad", "trackball"], "computermouse"),
            (["controller", "gamepad", "dualsense", "dualshock", "xbox", "joy-con"], "gamecontroller.fill"),
            (["camera", "webcam", "facetime", "brio", "c920", "c922", "obsbot", "cam link"], "web.camera"),
            (["microphone", " mic", "yeti", "shure", "rode", "blue snowball"], "mic.fill"),
            (["headset", "headphone", "earbud", "airpods", "beats"], "headphones"),
            (["speaker", "audio", " dac", "focusrite", "scarlett", "interface"], "hifispeaker.fill"),
            (["printer", "laserjet", "deskjet", "officejet", "pixma"], "printer.fill"),
            (["ethernet", "lan adapter", " lan "], "network"),
            (["card reader", "sd reader", "reader"], "sdcard.fill"),
            (["ssd", "drive", "disk", "flash", "storage", "sandisk", " t7 ", " t9 ", "extreme", "my passport", "seagate",
              "lacie", "kingston", "samsung"], "externaldrive.fill"),
            (["yubikey", "security key"], "key.fill"),
            (["display", "monitor"], "display"),
            (["dock", "thunderbolt"], "cable.connector"),
        ]
        for entry in words where entry.words.contains(where: n.contains) { return entry.symbol }
        // Otherwise go by what the device says it does (its interfaces' USB classes).
        let classes = interfaceClasses(s) + [deviceClass]
        if classes.contains(8) { return "externaldrive.fill" }
        if classes.contains(14) { return "web.camera" }
        if classes.contains(1) { return "hifispeaker.fill" }
        if classes.contains(7) { return "printer.fill" }
        if classes.contains(3) { return "keyboard" }
        if classes.contains(6) { return "camera.fill" }
        return "cable.connector"
    }

    private static func interfaceClasses(_ s: io_service_t) -> [Int] {
        var iterator: io_iterator_t = 0
        guard IORegistryEntryCreateIterator(s, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var out: [Int] = []
        while case let child = IOIteratorNext(iterator), child != 0 {
            if let c = property(child, "bInterfaceClass") as? NSNumber { out.append(c.intValue) }
            IOObjectRelease(child)
        }
        return out
    }
}
