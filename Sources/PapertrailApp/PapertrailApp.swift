import PapertrailCore
import SwiftUI

#if !PPR_PORTABLE_SCHEMA
  import SwiftData
#endif

@main
struct PapertrailApp: App {
  private let paths: LibraryPaths?
  private let launchRepairMessage: String?
  #if !PPR_PORTABLE_SCHEMA
    private let container: ModelContainer?
  #endif

  init() {
    var repairMessage: String?
    let resolvedPaths: LibraryPaths?
    do {
      if let isolatedSupport = Self.commandLineApplicationSupport() {
        resolvedPaths = LibraryPaths(applicationSupport: isolatedSupport)
      } else {
        resolvedPaths = try LibraryPaths.system()
      }
    } catch {
      resolvedPaths = nil
      repairMessage = "The Application Support folder is unavailable: \(error.localizedDescription)"
    }
    #if !PPR_PORTABLE_SCHEMA
      var resolvedContainer: ModelContainer?
    #endif
    if let resolvedPaths {
      do {
        try resolvedPaths.createRootTopology()
        #if !PPR_PORTABLE_SCHEMA
          let container = try ModelContainerFactory.make(at: resolvedPaths.storeURL)
          resolvedContainer = container
          let issues = try ApplicationLaunchCoordinator.reconcile(
            container: container, paths: resolvedPaths)
        #else
          let store = try ModelContainerFactory.make(at: resolvedPaths.storeURL)
          let issues = try ApplicationLaunchCoordinator.reconcile(
            store: store, paths: resolvedPaths)
        #endif
        if !issues.isEmpty {
          repairMessage = "The local library opened with \(issues.count) recoverable item(s)."
        }
      } catch {
        repairMessage = "The durable local library needs repair: \(error.localizedDescription)"
      }
    }
    self.paths = resolvedPaths
    self.launchRepairMessage = repairMessage
    #if !PPR_PORTABLE_SCHEMA
      self.container = resolvedContainer
    #endif
  }

  /// Keeps release-launch verification away from the owner's live library. The override is
  /// intentionally command-line-only so normal Finder launches always use Application Support.
  private static func commandLineApplicationSupport() -> URL? {
    let arguments = ProcessInfo.processInfo.arguments
    guard let flag = arguments.firstIndex(of: "--papertrail-application-support"),
      arguments.indices.contains(flag + 1)
    else { return nil }
    let path = arguments[flag + 1]
    guard path.hasPrefix("/") else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
  }

  var body: some Scene {
    WindowGroup("Papertrail") {
      if let paths {
        #if !PPR_PORTABLE_SCHEMA
          if let container {
            PaperLibraryView(
              paths: paths, container: container, launchRepairMessage: launchRepairMessage
            ).modelContainer(container)
          } else {
            ContentUnavailableView(
              "Library unavailable", systemImage: "externaldrive.badge.exclamationmark",
              description: Text(
                launchRepairMessage ?? "The durable local library could not be opened."))
          }
        #else
          PaperLibraryView(
            paths: paths, launchRepairMessage: launchRepairMessage)
        #endif
      } else {
        ContentUnavailableView(
          "Library unavailable", systemImage: "externaldrive.badge.exclamationmark",
          description: Text(
            launchRepairMessage ?? "The Application Support folder could not be located."))
      }
    }
    .defaultSize(width: 1280, height: 820)
  }
}
