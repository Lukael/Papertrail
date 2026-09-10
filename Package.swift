// swift-tools-version: 6.0
import Foundation
import PackageDescription

let selectedDeveloperDirectory =
  ProcessInfo.processInfo.environment["DEVELOPER_DIR"]
  ?? ((try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link"))
    ?? "/Library/Developer/CommandLineTools")
let forceSwiftData = ProcessInfo.processInfo.environment["PPR_FORCE_SWIFTDATA"] == "1"
let portableSchemaSettings: [SwiftSetting] =
  !forceSwiftData && selectedDeveloperDirectory.contains("CommandLineTools")
  ? [.define("PPR_PORTABLE_SCHEMA")]
  : []

let package = Package(
  name: "Papertrail",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "PapertrailCore", targets: ["PapertrailCore"]),
    .executable(name: "PapertrailApp", targets: ["PapertrailApp"]),
    .executable(name: "Gate0AHarness", targets: ["Gate0AHarness"]),
    .executable(name: "Gate0ATests", targets: ["Gate0ATests"]),
    .executable(name: "Gate0CTests", targets: ["Gate0CTests"]),
    .executable(name: "Gate0DTests", targets: ["Gate0DTests"]),
    .executable(name: "Gate0ETests", targets: ["Gate0ETests"]),
    .executable(name: "Gate0EHarness", targets: ["Gate0EHarness"]),
    .executable(name: "Gate0FTests", targets: ["Gate0FTests"]),
    .executable(name: "Gate0FHarness", targets: ["Gate0FHarness"]),
    .executable(name: "Gate0GTests", targets: ["Gate0GTests"]),
    .executable(name: "Gate0GHarness", targets: ["Gate0GHarness"]),
    .executable(name: "Gate0HTests", targets: ["Gate0HTests"]),
    .executable(name: "ChatMathTests", targets: ["ChatMathTests"]),
  ],
  targets: [
    .target(
      name: "PapertrailCore",
      dependencies: ["PPRProcessSupervisor"],
      resources: [.copy("Resources/KaTeX")],
      swiftSettings: portableSchemaSettings
    ),
    .target(
      name: "PPRProcessSupervisor",
      publicHeadersPath: "include"
    ),
    .executableTarget(
      name: "PapertrailApp",
      dependencies: ["PapertrailCore"],
      exclude: ["Info.plist", "Resources"],
      swiftSettings: portableSchemaSettings
    ),
    .executableTarget(
      name: "Gate0AHarness",
      dependencies: ["PapertrailCore"],
      exclude: ["Info.plist"]
    ),
    .executableTarget(name: "Gate0ATests", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0CTests", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0DTests", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0ETests", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0EHarness", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0FTests", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0FHarness", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0GTests", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0GHarness", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "Gate0HTests", dependencies: ["PapertrailCore"]),
    .executableTarget(name: "ChatMathTests", dependencies: ["PapertrailCore"]),
  ]
)
