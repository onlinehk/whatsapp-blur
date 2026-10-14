// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WhatsAppBlur",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "WhatsAppBlur", path: "Sources/WhatsAppBlur")
    ]
)
