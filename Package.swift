// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BelovodieCalendarBridge",
    platforms: [.macOS(.v14)],
    products: [.library(name: "BridgeCore", targets: ["BridgeCore"]),
               .executable(name: "BelovodieCalendarBridge", targets: ["BridgeApp"])],
    targets: [
        .target(name: "BridgeCore"),
        .target(name: "BridgeMac", dependencies: ["BridgeCore"], exclude: ["App.swift"]),
        .executableTarget(name: "BridgeApp", dependencies: ["BridgeMac"], path: "Sources/BridgeMac", exclude: ["EventKitAdapter.swift", "NativeEventKitProvider.swift", "BridgeModel.swift", "CalendarSettingsView.swift", "OwnershipReceiptStore.swift"], sources: ["App.swift"]),
        .testTarget(name: "BridgeCoreTests", dependencies: ["BridgeCore", "BridgeMac"])
    ]
)
