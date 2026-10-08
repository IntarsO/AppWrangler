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
			path: "Sources/AppWrangler"
		),
		.testTarget(
			name: "AppWranglerKitTests",
			dependencies: ["AppWranglerKit", "ProcKit"],
			path: "Tests/AppWranglerKitTests"
		),
	]
)
