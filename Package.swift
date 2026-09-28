// swift-tools-version:6.2
import PackageDescription

let mcp: Target.Dependency = .product(name: "MCP", package: "swift-sdk")

let package = Package(
    name: "MergeCue",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MergeCueCore", targets: ["MergeCueCore"]),
        .library(name: "MergeCueStore", targets: ["MergeCueStore"]),
        .library(name: "MergeCueNetworking", targets: ["MergeCueNetworking"]),
        .library(name: "MergeCueIPC", targets: ["MergeCueIPC"]),
        .library(name: "GitHubAdapter", targets: ["GitHubAdapter"]),
        .library(name: "GitLabAdapter", targets: ["GitLabAdapter"]),
        .library(name: "BitbucketCloudAdapter", targets: ["BitbucketCloudAdapter"]),
        .library(name: "MergeCueFixtures", targets: ["MergeCueFixtures"]),
        .library(name: "WorkspaceInspector", targets: ["WorkspaceInspector"]),
        .library(name: "AgentHandoff", targets: ["AgentHandoff"]),
        .library(name: "MergeCueSync", targets: ["MergeCueSync"]),
        .library(name: "MergeCueEngine", targets: ["MergeCueEngine"]),
        .library(name: "MergeCueMCPServer", targets: ["MergeCueMCPServer"]),
        .library(name: "MergeCueRuntime", targets: ["MergeCueRuntime"]),
        .library(name: "MergeCueUI", targets: ["MergeCueUI"]),
        .executable(name: "mergecue-mcp", targets: ["mergecue-mcp"]),
        .executable(name: "mergecue-agent-sim", targets: ["mergecue-agent-sim"]),
        .executable(name: "mergecue-snapshots", targets: ["mergecue-snapshots"]),
        .executable(name: "mergecue-demo-host", targets: ["mergecue-demo-host"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        // MARK: Foundation layer
        .target(name: "MergeCueCore"),
        .target(
            name: "MergeCueStore",
            dependencies: ["MergeCueCore"],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "MergeCueNetworking",
            dependencies: ["MergeCueCore"],
            linkerSettings: [.linkedFramework("Security")]
        ),
        .target(name: "MergeCueIPC", dependencies: ["MergeCueCore"]),

        // MARK: Providers
        .target(name: "GitHubAdapter", dependencies: ["MergeCueCore", "MergeCueNetworking"]),
        .target(name: "GitLabAdapter", dependencies: ["MergeCueCore", "MergeCueNetworking"]),
        .target(name: "BitbucketCloudAdapter", dependencies: ["MergeCueCore", "MergeCueNetworking"]),
        .target(
            name: "MergeCueFixtures",
            dependencies: ["MergeCueCore", "MergeCueNetworking", "GitHubAdapter", "GitLabAdapter", "BitbucketCloudAdapter"],
            resources: [.copy("Resources")]
        ),

        // MARK: Local workspace and agents
        .target(name: "WorkspaceInspector", dependencies: ["MergeCueCore"]),
        .target(name: "AgentHandoff", dependencies: ["MergeCueCore", "MergeCueIPC", mcp]),

        // MARK: Services
        .target(name: "MergeCueSync", dependencies: ["MergeCueCore", "MergeCueStore"]),
        .target(name: "MergeCueEngine", dependencies: ["MergeCueCore", "MergeCueStore", "MergeCueIPC"], exclude: ["README.md"]),
        .target(name: "MergeCueMCPServer", dependencies: ["MergeCueCore", "MergeCueIPC", mcp]),
        .target(
            name: "MergeCueRuntime",
            dependencies: [
                "MergeCueCore", "MergeCueStore", "MergeCueNetworking", "MergeCueIPC",
                "GitHubAdapter", "GitLabAdapter", "BitbucketCloudAdapter", "MergeCueFixtures",
                "WorkspaceInspector", "AgentHandoff", "MergeCueSync", "MergeCueEngine",
            ]
        ),

        // MARK: UI
        .target(
            name: "MergeCueUI",
            dependencies: ["MergeCueCore", "MergeCueEngine", "MergeCueRuntime", "AgentHandoff", "WorkspaceInspector"],
            resources: [.process("Resources")],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        // MARK: Executables
        .executableTarget(name: "mergecue-mcp", dependencies: ["MergeCueMCPServer"]),
        .executableTarget(
            name: "mergecue-agent-sim",
            dependencies: ["MergeCueCore", "MergeCueIPC", "MergeCueFixtures", mcp]
        ),
        .executableTarget(
            name: "mergecue-demo-host",
            dependencies: ["MergeCueRuntime", "MergeCueEngine", "MergeCueFixtures", "MergeCueCore", "MergeCueIPC"]
        ),
        .executableTarget(
            name: "mergecue-snapshots",
            dependencies: ["MergeCueUI", "MergeCueRuntime", "MergeCueFixtures"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        // MARK: Tests
        .testTarget(name: "MergeCueCoreTests", dependencies: ["MergeCueCore"]),
        .testTarget(name: "MergeCueStoreTests", dependencies: ["MergeCueStore"]),
        .testTarget(name: "MergeCueNetworkingTests", dependencies: ["MergeCueNetworking"]),
        .testTarget(name: "MergeCueIPCTests", dependencies: ["MergeCueIPC"]),
        .testTarget(name: "GitHubAdapterTests", dependencies: ["GitHubAdapter", "MergeCueFixtures"]),
        .testTarget(name: "GitLabAdapterTests", dependencies: ["GitLabAdapter", "MergeCueFixtures"]),
        .testTarget(name: "BitbucketCloudAdapterTests", dependencies: ["BitbucketCloudAdapter", "MergeCueFixtures"]),
        .testTarget(name: "MergeCueFixturesTests", dependencies: ["MergeCueFixtures"]),
        .testTarget(name: "WorkspaceInspectorTests", dependencies: ["WorkspaceInspector"]),
        .testTarget(name: "AgentHandoffTests", dependencies: ["AgentHandoff"]),
        .testTarget(name: "MergeCueSyncTests", dependencies: ["MergeCueSync", "MergeCueFixtures"]),
        .testTarget(name: "MergeCueEngineTests", dependencies: ["MergeCueEngine", "MergeCueFixtures"]),
        .testTarget(name: "MergeCueMCPServerTests", dependencies: ["MergeCueMCPServer", mcp]),
        .testTarget(
            name: "MergeCueRuntimeTests",
            dependencies: [
                "MergeCueRuntime", "MergeCueCore", "MergeCueNetworking", "MergeCueFixtures", "MergeCueEngine",
                "MergeCueIPC", "GitHubAdapter", "GitLabAdapter", "BitbucketCloudAdapter", "AgentHandoff",
            ]
        ),
        .testTarget(
            name: "MergeCueUITests",
            dependencies: ["MergeCueUI", "MergeCueRuntime", "MergeCueEngine", "MergeCueCore", "AgentHandoff"]
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: [
                "MergeCueRuntime", "MergeCueMCPServer", "MergeCueFixtures", "MergeCueEngine",
                "MergeCueSync", "WorkspaceInspector", "AgentHandoff", "MergeCueCore", "MergeCueIPC",
                "MergeCueNetworking", "MergeCueStore", mcp,
            ]
        ),
    ]
)
