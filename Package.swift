// swift-tools-version: 6.2
import PackageDescription
let package = Package(
    name: "Psst",
    platforms: [.macOS(.v26)],
    products: [.executable(name: "Psst", targets: ["Psst"])],
    targets: [.executableTarget(name: "Psst")],
    swiftLanguageModes: [.v5]
)
