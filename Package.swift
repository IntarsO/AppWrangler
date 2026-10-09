// swift-tools-version:5.9
//
// Build:  ./build.sh        (Command Line Tools only, no Xcode needed)
// Test:   ./test.sh         (unit + limiter integration tests)
//         ./Tests/e2e/run.sh (end-to-end against the built app)
//
import PackageDescription

let package = Package(
	name: "AppWrangler",
	platforms: [.macOS(.v13)],
	targets: [
		.target(
			name: "ProcKit",
			path: "Sources/ProcKit",
			cSettings: [.unsafeFlags(["-Wall", "-Wextra"])]
		),
		.target(
			name: "AppWranglerKit",
			dependencies: ["ProcKit"],
			path: "Sources/AppWranglerKit"
		),
		.executableTarget(
			name: "AppWrangler",
			dependencies: ["AppWranglerKit"],
			path: "Sources/AppWrangler",
			// Embed a small Info.plist so the binary keeps the app's identity (and
			// preferences) when run on its own, e.g. as the MCP server in an .mcpb bundle.
			linkerSettings: [.unsafeFlags(["-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
										   "-Xlinker", Context.packageDirectory + "/Resources/AppWrangler-embedded.plist"])]
		),
		// Restores frozen / efficiency-core apps if AppWrangler dies, even by
		// `killall -9 AppWrangler` (it has its own name for that reason).
		.executableTarget(
			name: "AppWranglerWatchdog",
			dependencies: ["ProcKit"],
			path: "Sources/AppWranglerWatchdog"
		),
		.testTarget(
			name: "AppWranglerKitTests",
			dependencies: ["AppWranglerKit", "ProcKit"],
			path: "Tests/AppWranglerKitTests"
		),
	]
)
