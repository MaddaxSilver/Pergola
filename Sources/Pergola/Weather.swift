import SwiftUI
import CoreLocation

/// Current weather from Open-Meteo (free, no API key). Location comes from Core Location,
/// or from a city typed in Settings.
@Observable @MainActor
final class Weather: NSObject, CLLocationManagerDelegate {
    var temperature: Double?
    var high: Double?
    var low: Double?
    var code = 0
    var isDay = true
    var place = ""
    var status = ""
    var hourly: [Hour] = []
    var wind: Double?
    var uv: Double?

    struct Hour: Identifiable {
        let time: Date
        let temperature: Double
        let code: Int
        let isDay: Bool
        var id: Date { time }
        var symbol: String { Weather.symbol(code: code, isDay: isDay) }
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var coordinate: CLLocationCoordinate2D?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastCity = ""
    @ObservationIgnored private var lastFahrenheit = false

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        lastCity = Prefs.d.string(forKey: Prefs.weatherCity) ?? ""
        lastFahrenheit = Prefs.d.bool(forKey: Prefs.fahrenheit)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settingsChanged() }
        }
    }

    private func settingsChanged() {
        let city = Prefs.d.string(forKey: Prefs.weatherCity) ?? ""
        let f = Prefs.d.bool(forKey: Prefs.fahrenheit)
        guard city != lastCity || f != lastFahrenheit else { return }
        lastCity = city
        lastFahrenheit = f
        if city.isEmpty { coordinate = nil }
        refresh()
    }

    func refresh() {
        guard Prefs.d.bool(forKey: Prefs.weatherEnabled) else { return }
        let city = (Prefs.d.string(forKey: Prefs.weatherCity) ?? "").trimmingCharacters(in: .whitespaces)
        if !city.isEmpty {
            Task { await geocodeAndFetch(city) }
            return
        }
        if let coordinate {
            Task { await fetch(coordinate) }
            return
        }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorized, .authorizedAlways:
            manager.requestLocation()
        default:
            status = "Turn on Location for Pergola, or set a city in Settings."
        }
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.refresh() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        Task { @MainActor in
            self.coordinate = loc.coordinate
            await self.fetch(loc.coordinate)
            if let mark = try? await CLGeocoder().reverseGeocodeLocation(loc).first {
                self.place = mark.locality ?? mark.name ?? ""
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.status = "Couldn't find your location." }
    }

    // MARK: Network

    private func geocodeAndFetch(_ city: String) async {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1")]
        struct R: Decodable { struct P: Decodable { let name: String; let latitude: Double; let longitude: Double }; let results: [P]? }
        guard let url = c.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let p = try? JSONDecoder().decode(R.self, from: data).results?.first else {
            status = "Couldn't find “\(city)”."
            return
        }
        place = p.name
        let coord = CLLocationCoordinate2D(latitude: p.latitude, longitude: p.longitude)
        coordinate = coord
        await fetch(coord)
    }

    private func fetch(_ c: CLLocationCoordinate2D) async {
        var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        comps.queryItems = [
            .init(name: "latitude", value: String(format: "%.3f", c.latitude)),
            .init(name: "longitude", value: String(format: "%.3f", c.longitude)),
            .init(name: "current", value: "temperature_2m,weather_code,is_day,wind_speed_10m"),
            .init(name: "daily", value: "temperature_2m_max,temperature_2m_min,uv_index_max"),
            .init(name: "hourly", value: "temperature_2m,weather_code,is_day"),
            .init(name: "forecast_hours", value: "24"),
            .init(name: "wind_speed_unit", value: Prefs.d.bool(forKey: Prefs.fahrenheit) ? "mph" : "kmh"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "1"),
            .init(name: "timezone", value: "auto"),
            .init(name: "temperature_unit", value: Prefs.d.bool(forKey: Prefs.fahrenheit) ? "fahrenheit" : "celsius"),
        ]
        struct R: Decodable {
            struct Cur: Decodable { let temperature_2m: Double; let weather_code: Int; let is_day: Int; let wind_speed_10m: Double? }
            struct Day: Decodable { let temperature_2m_max: [Double]; let temperature_2m_min: [Double]; let uv_index_max: [Double?]? }
            struct Hr: Decodable { let time: [Double]; let temperature_2m: [Double]; let weather_code: [Int]; let is_day: [Int] }
            let current: Cur
            let daily: Day
            let hourly: Hr?
        }
        guard let url = comps.url, let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(R.self, from: data) else {
            status = "Weather is unavailable right now."
            return
        }
        temperature = r.current.temperature_2m
        code = r.current.weather_code
        isDay = r.current.is_day == 1
        high = r.daily.temperature_2m_max.first
        low = r.daily.temperature_2m_min.first
        wind = r.current.wind_speed_10m
        uv = r.daily.uv_index_max?.first ?? nil
        if let h = r.hourly {
            let n = min(h.time.count, h.temperature_2m.count, h.weather_code.count, h.is_day.count)
            hourly = (0..<n).map { Hour(time: Date(timeIntervalSince1970: h.time[$0]), temperature: h.temperature_2m[$0],
                                        code: h.weather_code[$0], isDay: h.is_day[$0] == 1) }
                .filter { $0.time > Date().addingTimeInterval(-1800) }
        }
        status = ""
    }

    // MARK: Presentation

    var symbol: String { Self.symbol(code: code, isDay: isDay) }

    nonisolated static func symbol(code: Int, isDay: Bool) -> String {
        switch code {
        case 0: isDay ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: "cloud.fill"
        case 45, 48: "cloud.fog.fill"
        case 51...57: "cloud.drizzle.fill"
        case 65, 82: "cloud.heavyrain.fill"
        case 61...67, 80...82: "cloud.rain.fill"
        case 71...77, 85, 86: "cloud.snow.fill"
        case 95...99: "cloud.bolt.rain.fill"
        default: "cloud.fill"
        }
    }

    var summary: String {
        switch code {
        case 0: "Clear"
        case 1: "Mostly clear"
        case 2: "Partly cloudy"
        case 3: "Cloudy"
        case 45, 48: "Fog"
        case 51...57: "Drizzle"
        case 61...67, 80...82: "Rain"
        case 71...77, 85, 86: "Snow"
        case 95...99: "Thunderstorms"
        default: ""
        }
    }

    static func deg(_ v: Double?) -> String { v.map { "\(Int($0.rounded()))°" } ?? "--" }
}

/// The weather page, a detailed view:
/// city, big temperature, H/L/UV, wind and a sparkline on the left; the next hours on the right.
struct WeatherTab: View {
    var weather: Weather

    var body: some View {
        if weather.temperature == nil {
            Text(weather.status.isEmpty ? "Loading weather…" : weather.status)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(weather.place.isEmpty ? "Current Location" : weather.place)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                    HStack(alignment: .top, spacing: 2) {
                        Text(Weather.deg(weather.temperature))
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(.white)
                        Image(systemName: weather.symbol)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 19))
                            .padding(.top, 9)
                    }
                    .frame(height: 48)
                    HStack(spacing: 8) {
                        Text("H:\(Weather.deg(weather.high))  L:\(Weather.deg(weather.low))")
                        if let uv = weather.uv { Text("UV \(Int(uv.rounded()))") }
                    }
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    if let wind = weather.wind {
                        Label("\(Int(wind.rounded())) \(Prefs.d.bool(forKey: Prefs.fahrenheit) ? "mph" : "km/h")", systemImage: "wind")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(.top, 3)
                    }
                    Sparkline(values: weather.hourly.map(\.temperature))
                        .frame(height: 11)
                        .padding(.top, 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Rectangle().fill(.white.opacity(0.12)).frame(width: 1)

                ScrollView(.vertical) {
                  VStack(spacing: 0) {
                    ForEach(weather.hourly) { h in
                        HStack(spacing: 0) {
                            Text(h.time, format: .dateTime.hour())
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                                .frame(width: 46, alignment: .leading)
                            Image(systemName: h.symbol)
                                .symbolRenderingMode(.multicolor)
                                .font(.system(size: 13))
                                .frame(width: 22)
                            Spacer(minLength: 4)
                            Text(Weather.deg(h.temperature))
                                .font(.system(size: 13.5, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .frame(height: 22)
                    }
                  }
                  .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .frame(width: 126)
                .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.06),
                                             .init(color: .black, location: 0.8), .init(color: .clear, location: 1)],
                                     startPoint: .top, endPoint: .bottom))
            }
        }
    }
}

/// Dotted temperature trend for the next day, with a dot on "now".
struct Sparkline: View {
    var values: [Double]

    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1, let lo = values.min(), let hi = values.max() else { return }
            let span = max(hi - lo, 1)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: size.width * CGFloat(i) / CGFloat(values.count - 1),
                        y: size.height - 2 - (size.height - 4) * CGFloat((v - lo) / span))
            }
            var path = Path()
            path.addLines(pts)
            ctx.stroke(path, with: .color(.white.opacity(0.45)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [1.5, 2.5]))
            let now = pts[0]
            ctx.fill(Path(ellipseIn: CGRect(x: now.x, y: now.y - 2.5, width: 5, height: 5)), with: .color(.white))
        }
    }
}
