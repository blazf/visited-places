// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VisitedPlaces",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "VisitedPlaces",
            path: "Sources/VisitedPlaces",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "VisitedPlacesTests",
            dependencies: ["VisitedPlaces"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
