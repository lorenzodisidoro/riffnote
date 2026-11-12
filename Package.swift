// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Riffnote",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Riffnote", targets: ["Riffnote"])],
    targets: [.executableTarget(name: "Riffnote", path: "sources/riffnote")]
)
