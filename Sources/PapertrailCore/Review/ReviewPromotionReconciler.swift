import Foundation

public struct ReviewPromotionRecovery: Codable, Equatable, Sendable {
  public let generationID: UUID
  public let versionID: UUID?
  public let action: String
  public let relativePath: String?
}

public struct ReviewPromotionReconciler: Sendable {
  public init() {}

  public func reconcile(
    paperID: UUID, paths: LibraryPaths, store: any ReviewGenerationStore,
    fileManager: FileManager = .default
  ) throws -> [ReviewPromotionRecovery] {
    var reports: [ReviewPromotionRecovery] = []
    let records = try store.generations(paperID: paperID)
    for record in records {
      let generationRoot = paths.generation(record.id, paperID: paperID)
      let reviewRoot = generationRoot.appendingPathComponent("review", isDirectory: true)
      let quarantineRoot = generationRoot.appendingPathComponent("quarantine", isDirectory: true)
      var expectedNames = Set<String>()
      if let committed = record.reviewVersionID { expectedNames.insert(committed.uuidString.lowercased()) }
      if let intended = record.promotionVersionID { expectedNames.insert(intended.uuidString.lowercased()) }

      if let versionID = record.promotionVersionID,
        let relative = record.promotionRelativePath
      {
        let final = try paths.url(forRelativePath: relative)
        let partial = final.deletingLastPathComponent()
          .appendingPathComponent(".partial-\(versionID.uuidString.lowercased())", isDirectory: true)
        let finalExists = fileManager.fileExists(atPath: final.path)
        let partialExists = fileManager.fileExists(atPath: partial.path)
        if finalExists && record.reviewVersionID == nil {
          let integrityPassed: Bool
          if let manifestSHA256 = record.promotionManifestSHA256 {
            integrityPassed = (try? ReviewPromotionIntegrity.verify(
              root: final, expectedManifestSHA256: manifestSHA256,
              generationID: record.id, versionID: versionID,
              evidenceState: record.evidenceReportState, fileManager: fileManager)) != nil
          } else {
            integrityPassed = false
          }
          guard record.processOutcome == .turnCompleted,
            record.structuralValidation == .passed,
            integrityPassed
          else {
            try quarantine(final, root: quarantineRoot, fileManager: fileManager)
            try store.markPromotionPhase(generationID: record.id, phase: .quarantined)
            reports.append(.init(
              generationID: record.id, versionID: versionID,
              action: "quarantined-uncommitted-final", relativePath: relative))
            continue
          }
          try store.recoverPromotion(generationID: record.id)
          reports.append(.init(
            generationID: record.id, versionID: versionID,
            action: "recovered-final-without-changing-selection", relativePath: relative))
        } else if partialExists && !finalExists {
          let partialRelative = try paths.relativePath(for: partial)
          try quarantine(partial, root: quarantineRoot, fileManager: fileManager)
          try store.markPromotionPhase(generationID: record.id, phase: .quarantined)
          reports.append(.init(
            generationID: record.id, versionID: versionID,
              action: "quarantined-partial", relativePath: partialRelative))
        }
      }

      if fileManager.fileExists(atPath: reviewRoot.path) {
        for child in try fileManager.contentsOfDirectory(
          at: reviewRoot, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        {
          guard child.lastPathComponent != ".DS_Store",
            !expectedNames.contains(child.lastPathComponent),
            !child.lastPathComponent.hasPrefix(".partial-")
          else { continue }
          let childRelative = try paths.relativePath(for: child)
          try quarantine(child, root: quarantineRoot, fileManager: fileManager)
          reports.append(.init(
            generationID: record.id, versionID: UUID(uuidString: child.lastPathComponent),
            action: "quarantined-orphan-final", relativePath: childRelative))
        }
      }
    }
    return reports
  }

  private func quarantine(_ item: URL, root: URL, fileManager: FileManager) throws {
    try SecurePathContainment.rejectSymlinkComponents(
      from: item.deletingLastPathComponent(), through: item,
      fileManager: fileManager)
    try fileManager.createDirectory(
      at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let destination = root.appendingPathComponent(
      item.lastPathComponent + "-" + UUID().uuidString.lowercased())
    guard !fileManager.fileExists(atPath: destination.path) else {
      throw ReviewGenerationStoreError.versionAlreadyExists
    }
    let values = try item.resourceValues(forKeys: [.isDirectoryKey])
    try fileManager.setAttributes(
      [.posixPermissions: values.isDirectory == true ? 0o700 : 0o600],
      ofItemAtPath: item.path)
    try fileManager.moveItem(at: item, to: destination)
  }
}
