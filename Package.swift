// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Pergola",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "Pergola",
            path: "Sources/Pergola",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("Accelerate"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreLocation"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("EventKit"),
            ]
        )
    ]
)
