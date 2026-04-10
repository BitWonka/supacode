// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "supacode-mcp",
  platforms: [.macOS("26.0")],
  dependencies: [
    .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
  ],
  targets: [
    .target(
      name: "SupacodeMCPLib",
      path: "Sources/SupacodeMCPLib",
    ),
    .executableTarget(
      name: "supacode-mcp",
      dependencies: [
        "SupacodeMCPLib",
        .product(name: "MCP", package: "swift-sdk"),
      ],
      path: "Sources/CLI",
    ),
    .testTarget(
      name: "SupacodeMCPTests",
      dependencies: ["SupacodeMCPLib"],
      path: "Tests",
    ),
  ]
)
