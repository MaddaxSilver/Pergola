import Foundation
import CoreAudio

/// Recognises audio and Bluetooth devices so Pergola can show the right icon (and model name) even
/// when a device has been renamed. Checks, in order:
///   1. the hardware model (Bluetooth vendor + product ID), e.g. Apple 0x2024 = AirPods Pro 2
///   2. keywords in the device's name (brands and product lines)
///   3. the Bluetooth device type macOS reports (headphones, loudspeaker, gamepad…)
///   4. how it's connected (built-in, AirPlay, HDMI, USB…)
enum DeviceCatalog {
    struct Match {
        let symbol: String
        let model: String?
    }

    // MARK: 1. Hardware models (Apple vendor ID 0x004C)

    private static let apple: [Int: Match] = [
        0x2002: .init(symbol: "airpods", model: "AirPods"),
        0x200F: .init(symbol: "airpods", model: "AirPods (2nd generation)"),
        0x2013: .init(symbol: "airpods.gen3", model: "AirPods (3rd generation)"),
        0x2019: .init(symbol: "airpods.gen4", model: "AirPods 4"),
        0x201B: .init(symbol: "airpods.gen4", model: "AirPods 4 with Active Noise Cancellation"),
        0x200E: .init(symbol: "airpodspro", model: "AirPods Pro"),
        0x2014: .init(symbol: "airpodspro", model: "AirPods Pro 2"),
        0x2024: .init(symbol: "airpodspro", model: "AirPods Pro 2 (USB-C)"),
        0x2027: .init(symbol: "airpodspro", model: "AirPods Pro 3"),
        0x200A: .init(symbol: "airpodsmax", model: "AirPods Max"),
        0x201F: .init(symbol: "airpodsmax", model: "AirPods Max (USB-C)"),
        0x2003: .init(symbol: "beats.powerbeats3", model: "Powerbeats3"),
        0x2005: .init(symbol: "beats.earphones", model: "BeatsX"),
        0x2006: .init(symbol: "beats.headphones", model: "Beats Solo3"),
        0x2009: .init(symbol: "beats.headphones", model: "Beats Studio3"),
        0x200B: .init(symbol: "beats.powerbeatspro", model: "Powerbeats Pro"),
        0x200C: .init(symbol: "beats.headphones", model: "Beats Solo Pro"),
        0x200D: .init(symbol: "beats.powerbeats", model: "Powerbeats"),
        0x2010: .init(symbol: "beats.earphones", model: "Beats Flex"),
        0x2011: .init(symbol: "beats.studiobuds", model: "Beats Studio Buds"),
        0x2012: .init(symbol: "beats.fitpro", model: "Beats Fit Pro"),
        0x2016: .init(symbol: "beats.studiobuds", model: "Beats Studio Buds +"),
        0x2017: .init(symbol: "beats.headphones", model: "Beats Studio Pro"),
        0x201D: .init(symbol: "beats.powerbeatspro", model: "Powerbeats Pro 2"),
        0x2025: .init(symbol: "beats.headphones", model: "Beats Solo 4"),
        0x2026: .init(symbol: "beats.solobuds", model: "Beats Solo Buds"),
    ]

    // MARK: 2. Name keywords (checked in order; first hit wins)

    private static let keywords: [(words: [String], symbol: String)] = [
        (["airpods max"], "airpodsmax"),
        (["airpods pro"], "airpodspro"),
        (["airpods 4"], "airpods.gen4"),
        (["airpods 3", "airpods (3"], "airpods.gen3"),
        (["airpods"], "airpods"),
        (["earpods"], "earpods"),
        (["powerbeats pro"], "beats.powerbeatspro"),
        (["powerbeats"], "beats.powerbeats"),
        (["studio buds"], "beats.studiobuds"),
        (["fit pro"], "beats.fitpro"),
        (["solo buds"], "beats.solobuds"),
        (["beats pill", "pill+"], "beats.pill"),
        (["beats"], "beats.headphones"),
        (["homepod mini"], "homepodmini"),
        (["homepod"], "homepod"),
        (["apple tv"], "appletv"),
        (["carplay", " car", "car "], "car.fill"),
        // Speakers
        (["speaker", "soundlink", "soundbar", "sound bar", "jbl", "flip", "charge", "boombox", "boom", "wonderboom",
          "thump", "soundcore", "sonos", "marshall", "bose home", "ultimate ears", "tribit", "anker", "bang & olufsen",
          "beosound", "harman", "klipsch", "audioengine", "edifier", "creative"], "hifispeaker.fill"),
        // Earbuds
        (["buds", "earbuds", "wf-", "freebuds", "jabra elite", "nothing ear", "tws"], "earbuds"),
        // Over-ear / on-ear headphones
        (["headphone", "wh-", "xm4", "xm5", "xm6", "quietcomfort", "qc35", "qc45", "qc ultra", "momentum", "sennheiser",
          "audio-technica", "ath-", "hyperx", "steelseries", "arctis", "razer", "logitech g", "headset"], "headphones"),
        (["tv", "hdmi", "display", "monitor", "lg ", "samsung"], "tv"),
        (["macbook", "built-in", "internal speaker"], "laptopcomputer"),
        (["imac", "studio display"], "display"),
    ]

    // MARK: Lookup

    static func identify(name: String, vendorID: Int? = nil, productID: Int? = nil,
                         minorType: String? = nil, transport: UInt32? = nil) -> Match {
        if vendorID == 0x004C, let pid = productID, let m = apple[pid] { return m }

        let n = " \(name.lowercased()) "
        for entry in keywords where entry.words.contains(where: { n.contains($0) }) {
            return Match(symbol: entry.symbol, model: nil)
        }

        switch minorType?.lowercased() ?? "" {
        case let t where t.contains("loudspeaker") || t.contains("portable audio") || t.contains("hifi") || t.contains("speaker"):
            return Match(symbol: "hifispeaker.fill", model: nil)
        case let t where t.contains("headphone") || t.contains("headset") || t.contains("handsfree"):
            return Match(symbol: "headphones", model: nil)
        case let t where t.contains("gamepad") || t.contains("joystick"): return Match(symbol: "gamecontroller.fill", model: nil)
        case let t where t.contains("keyboard"): return Match(symbol: "keyboard", model: nil)
        case let t where t.contains("mouse"): return Match(symbol: "magicmouse", model: nil)
        case let t where t.contains("car"): return Match(symbol: "car.fill", model: nil)
        default: break
        }

        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return Match(symbol: "laptopcomputer", model: nil)
        case kAudioDeviceTransportTypeAirPlay: return Match(symbol: "airplay.audio", model: nil)
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: return Match(symbol: "tv", model: nil)
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return Match(symbol: "headphones", model: nil)
        case kAudioDeviceTransportTypeUSB: return Match(symbol: "hifispeaker", model: nil)
        default: return Match(symbol: "dot.radiowaves.left.and.right", model: nil)
        }
    }

    /// Core Audio reports a Bluetooth device's model as "<productID> <vendorID>" in hex, e.g. "2024 4c".
    static func ids(fromModelUID uid: String?) -> (vendor: Int, product: Int)? {
        let parts = (uid ?? "").split(separator: " ")
        guard parts.count == 2, let p = Int(parts[0], radix: 16), let v = Int(parts[1], radix: 16) else { return nil }
        return (v, p)
    }

    // MARK: Bluetooth details (vendor / product / type) from System Information

    private static let lock = NSLock()
    nonisolated(unsafe) private static var bluetooth: [String: (vendor: Int?, product: Int?, minor: String?)] = [:]

    /// Normalises "D0:3E:07:DD:E2:B2" and "d0-3e-07-dd-e2-b2" to the same key.
    static func key(_ address: String) -> String { address.lowercased().filter(\.isHexDigit) }

    static func bluetoothInfo(address: String) -> (vendor: Int?, product: Int?, minor: String?)? {
        lock.lock(); defer { lock.unlock() }
        return bluetooth[key(address)]
    }

    /// Reads paired Bluetooth devices from System Information in the background (takes about a second).
    static func refreshBluetooth(completion: (@Sendable () -> Void)? = nil) {
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
            p.arguments = ["SPBluetoothDataType", "-json"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard let json = try? JSONSerialization.jsonObject(with: data) else { return }

            var found: [String: (vendor: Int?, product: Int?, minor: String?)] = [:]
            // Walk the whole tree: every dictionary with a device address is a device.
            func hex(_ v: Any?) -> Int? {
                guard let s = v as? String else { return nil }
                return Int(s.lowercased().replacingOccurrences(of: "0x", with: "").split(separator: " ").first ?? "", radix: 16)
            }
            func walk(_ node: Any) {
                if let dict = node as? [String: Any] {
                    if let addr = dict["device_address"] as? String {
                        found[key(addr)] = (hex(dict["device_vendorID"]), hex(dict["device_productID"]), dict["device_minorType"] as? String)
                    }
                    dict.values.forEach(walk)
                } else if let arr = node as? [Any] {
                    arr.forEach(walk)
                }
            }
            walk(json)
            lock.lock(); bluetooth = found; lock.unlock()
            completion?()
        }
    }
}
