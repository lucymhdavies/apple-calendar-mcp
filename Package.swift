// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CalendarMCP",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.11.0")
    ],
    targets: [
        .executableTarget(
            name: "CalendarMCP",
            dependencies: [.product(name: "MCP", package: "swift-sdk")],
            path: "Sources/CalendarMCP",
            exclude: ["Info.plist"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/CalendarMCP/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "CalendarMCPTests",
            dependencies: ["CalendarMCP"],
            path: "Tests/CalendarMCPTests"
        )
    ]
)