import AppKit
import Network

/// Notices a VPN, an iPhone's Personal Hotspot or a display (cable or AirPlay) connecting and
/// disconnecting, and says so in a line under the notch. Needs no permissions: VPNs and the hotspot
/// are read from the Mac's own network interfaces, displays from the screen list.
@MainActor
final class Connections {
    var onChange: ((_ name: String, _ symbol: String, _ on: Bool) -> Void)?

    private let monitor = NWPathMonitor()
    private var vpn = false
    private var hotspot = false
    private var screens: [CGDirectDisplayID: String] = [:]
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        // The starting state is only remembered: nothing is announced for what was already connected.
        let now = Self.interfaces()
        vpn = now.vpn
        hotspot = now.hotspot
        screens = Self.externalScreens()

        monitor.pathUpdateHandler = { [weak self] _ in
            // Interfaces settle a moment after the path changes (an address arrives later).
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) {
                let state = Self.interfaces()
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.update(vpn: state.vpn, hotspot: state.hotspot) } }
            }
        }
        monitor.start(queue: DispatchQueue(label: "com.pergola.connections", qos: .utility))

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensChanged() }
        }
    }

    private func update(vpn newVPN: Bool, hotspot newHotspot: Bool) {
        if newVPN != vpn {
            vpn = newVPN
            onChange?("VPN", "lock.shield.fill", newVPN)
        }
        if newHotspot != hotspot {
            hotspot = newHotspot
            onChange?("Personal Hotspot", "personalhotspot", newHotspot)
        }
    }

    private func screensChanged() {
        let now = Self.externalScreens()
        for (id, name) in now where screens[id] == nil { onChange?(name, Self.symbol(for: name), true) }
        for (id, name) in screens where now[id] == nil { onChange?(name, Self.symbol(for: name), false) }
        screens = now
    }

    private static func symbol(for name: String) -> String {
        let n = name.lowercased()
        if n.contains("tv") || n.contains("airplay") || n.contains("apple tv") { return "airplayvideo" }
        if n.contains("ipad") || n.contains("sidecar") { return "ipad.landscape" }
        return "display"
    }

    private static func externalScreens() -> [CGDirectDisplayID: String] {
        var out: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
                  CGDisplayIsBuiltin(id) == 0 else { continue }
            out[id] = screen.localizedName
        }
        return out
    }

    /// A VPN is a tunnel interface (utun, ipsec, ppp, wg, tun) with an IPv4 address. macOS's own
    /// tunnels (iCloud, Handoff) only ever carry IPv6 link-local addresses, so they don't count.
    /// The Personal Hotspot always hands out addresses in 172.20.10.0/28.
    nonisolated static func interfaces() -> (vpn: Bool, hotspot: Bool) {
        var vpn = false, hotspot = false
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return (false, false) }
        defer { freeifaddrs(list) }
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            let flags = Int32(ifa.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_RUNNING != 0,
                  let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            var sin = sockaddr_in()
            memcpy(&sin, addr, MemoryLayout<sockaddr_in>.size)
            let ip = UInt32(bigEndian: sin.sin_addr.s_addr)
            if ["utun", "ipsec", "ppp", "wg", "tun", "tap"].contains(where: { name.hasPrefix($0) }) {
                vpn = true
            } else if name.hasPrefix("en"), ip & 0xFFFF_FFF0 == 0xAC14_0A00 { // 172.20.10.0/28
                hotspot = true
            }
        }
        return (vpn, hotspot)
    }
}
