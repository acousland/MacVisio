// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacVisio",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "MacVisio", targets: ["MacVisio"])],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", exact: "0.9.20"),
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .executableTarget(name: "MacVisio", dependencies: ["ZIPFoundation",.product(name:"Sparkle",package:"Sparkle")],linkerSettings:[.unsafeFlags(["-Xlinker","-rpath","-Xlinker","@executable_path/../Frameworks"])]),
        .testTarget(name: "MacVisioTests", dependencies: ["MacVisio"], resources:[.copy("Fixtures")])
    ]
)
