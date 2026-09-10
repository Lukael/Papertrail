import Foundation

public struct ReviewPromotionManifestEntry: Codable, Equatable, Sendable {
  public let relativePath: String
  public let sha256: String
  public let byteCount: Int
}

public struct ReviewPromotionManifest: Codable, Equatable, Sendable {
  public let schemaVersion: Int
  public let generationID: UUID
  public let versionID: UUID
  public let evidenceState: EvidenceReportState
  public let structuralValidation: StructuralValidationState
  public let independentSemanticOrVisualVerification: Bool
  public let entries: [ReviewPromotionManifestEntry]
}

public enum ReviewPromotionIntegrityError: Error, Equatable {
  case missingManifest
  case manifestMismatch
  case unsafePath(String)
  case symbolicLink(String)
  case mutableItem(String)
  case tooManyFiles(Int)
  case contentTooLarge(Int64)
  case invalidRequiredArtifact(String)
}

public enum ReviewEvidenceIntegrity {
  public static func validProduced(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return object["trust"] as? String == "agent-produced-untrusted"
      && object["independentlyVerified"] as? Bool == false
  }

  public static func validFallback(_ data: Data) -> Bool {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return object["trust"] as? String == "missing-or-invalid"
      && object["independentlyVerified"] as? Bool == false
  }
}

public struct ReviewFallbackEvidence: Encodable, Equatable, Sendable {
  public let trust: String
  public let independentlyVerified: Bool
  public init() {
    trust = "missing-or-invalid"
    independentlyVerified = false
  }
}

public enum ReviewPromotionIntegrity {
  public static let manifestName = "promotion-manifest.json"
  public static let maximumFileCount = 4_096
  public static let maximumFileBytes: Int64 = 128 * 1024 * 1024
  public static let maximumTreeBytes: Int64 = 512 * 1024 * 1024
  public static let maximumManifestBytes: Int64 = 2 * 1024 * 1024

  public static func makeManifest(
    root: URL, generationID: UUID, versionID: UUID,
    evidenceState: EvidenceReportState, fileManager: FileManager = .default
  ) throws -> ReviewPromotionManifest {
    ReviewPromotionManifest(
      schemaVersion: 1, generationID: generationID, versionID: versionID,
      evidenceState: evidenceState, structuralValidation: .passed,
      independentSemanticOrVisualVerification: false,
      entries: try inventory(root: root, requireImmutable: false, fileManager: fileManager))
  }

  @discardableResult
  public static func verify(
    root: URL, expectedManifestSHA256: String, generationID: UUID, versionID: UUID,
    evidenceState: EvidenceReportState, fileManager: FileManager = .default
  ) throws -> ReviewPromotionManifest {
    _ = try SecurePathContainment.requireExisting(root, inside: root.deletingLastPathComponent())
    let manifestURL = root.appendingPathComponent(manifestName)
    let manifestFingerprint = try FileFingerprint.read(
      manifestURL, maximumByteCount: maximumManifestBytes)
    guard manifestFingerprint.sha256 == expectedManifestSHA256 else {
      throw ReviewPromotionIntegrityError.manifestMismatch
    }
    let manifest = try JSONDecoder().decode(
      ReviewPromotionManifest.self, from: Data(contentsOf: manifestURL))
    guard manifest.schemaVersion == 1, manifest.generationID == generationID,
      manifest.versionID == versionID, manifest.evidenceState == evidenceState,
      manifest.structuralValidation == .passed,
      manifest.independentSemanticOrVisualVerification == false
    else { throw ReviewPromotionIntegrityError.manifestMismatch }
    let actual = try inventory(root: root, requireImmutable: true, fileManager: fileManager)
    guard actual == manifest.entries else { throw ReviewPromotionIntegrityError.manifestMismatch }
    try verifyRequiredArtifacts(
      root: root, manifest: manifest, fileManager: fileManager)
    return manifest
  }

  private static func inventory(
    root: URL, requireImmutable: Bool, fileManager: FileManager
  ) throws -> [ReviewPromotionManifestEntry] {
    try SecurePathContainment.rejectSymlinkComponents(
      from: root.deletingLastPathComponent(), through: root, fileManager: fileManager)
    let rootValues = try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
    guard rootValues.isDirectory == true else {
      throw ReviewPromotionIntegrityError.unsafePath(root.path)
    }
    guard rootValues.isSymbolicLink != true else {
      throw ReviewPromotionIntegrityError.symbolicLink(root.path)
    }
    if requireImmutable { try requireReadOnly(root, fileManager: fileManager) }
    let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
    guard let enumerator = fileManager.enumerator(
      at: root, includingPropertiesForKeys: Array(keys), options: [])
    else { throw ReviewPromotionIntegrityError.unsafePath(root.path) }
    var entries: [ReviewPromotionManifestEntry] = []
    var total: Int64 = 0
    let prefix = root.standardizedFileURL.path + "/"
    for case let item as URL in enumerator {
      let values = try item.resourceValues(forKeys: keys)
      if values.isSymbolicLink == true {
        throw ReviewPromotionIntegrityError.symbolicLink(item.path)
      }
      _ = try SecurePathContainment.requireExisting(item, inside: root)
      if requireImmutable { try requireReadOnly(item, fileManager: fileManager) }
      guard values.isRegularFile == true else { continue }
      let canonical = item.standardizedFileURL
      guard canonical.path.hasPrefix(prefix) else {
        throw ReviewPromotionIntegrityError.unsafePath(item.path)
      }
      let relative = String(canonical.path.dropFirst(prefix.count))
      if relative == manifestName { continue }
      guard !relative.isEmpty, !relative.contains(".."), !relative.contains("\\") else {
        throw ReviewPromotionIntegrityError.unsafePath(relative)
      }
      let fingerprint = try FileFingerprint.read(item, maximumByteCount: maximumFileBytes)
      entries.append(ReviewPromotionManifestEntry(
        relativePath: relative, sha256: fingerprint.sha256,
        byteCount: fingerprint.byteCount))
      guard entries.count <= maximumFileCount else {
        throw ReviewPromotionIntegrityError.tooManyFiles(entries.count)
      }
      total += Int64(entries.last!.byteCount)
      guard total <= maximumTreeBytes else {
        throw ReviewPromotionIntegrityError.contentTooLarge(total)
      }
    }
    return entries.sorted { $0.relativePath < $1.relativePath }
  }

  private static func verifyRequiredArtifacts(
    root: URL, manifest: ReviewPromotionManifest, fileManager: FileManager
  ) throws {
    let required = [
      "index.html", "sanitization-report.json", "validation-report.json",
      "evidence-report.json",
    ]
    let paths = Set(manifest.entries.map(\.relativePath))
    for relative in required where !paths.contains(relative) {
      throw ReviewPromotionIntegrityError.invalidRequiredArtifact(relative)
    }
    let htmlURL = root.appendingPathComponent("index.html")
    let htmlFingerprint = try FileFingerprint.read(htmlURL, maximumByteCount: maximumFileBytes)
    let htmlData = try Data(contentsOf: htmlURL)
    guard htmlData.count == htmlFingerprint.byteCount,
      let html = String(data: htmlData, encoding: .utf8)
    else { throw ReviewPromotionIntegrityError.invalidRequiredArtifact("index.html") }
    let validationURL = root.appendingPathComponent("validation-report.json")
    let validationFingerprint = try FileFingerprint.read(
      validationURL, maximumByteCount: maximumManifestBytes)
    let validation = try JSONDecoder().decode(
      ReviewValidationReport.self, from: Data(contentsOf: validationURL))
    let currentValidation = try ReviewValidator().validate(
      reviewDirectory: root, html: html, fileManager: fileManager)
    guard validationFingerprint.byteCount > 0, validation.passed,
      validation.independentSemanticOrVisualVerification == false,
      currentValidation == validation
    else {
      throw ReviewPromotionIntegrityError.invalidRequiredArtifact("validation-report.json")
    }
    let sanitizationURL = root.appendingPathComponent("sanitization-report.json")
    _ = try FileFingerprint.read(sanitizationURL, maximumByteCount: maximumManifestBytes)
    let sanitization = try JSONDecoder().decode(
      ReviewSanitizationReport.self, from: Data(contentsOf: sanitizationURL))
    guard sanitization.csp == ReviewResourceSanitizer.contentSecurityPolicy else {
      throw ReviewPromotionIntegrityError.invalidRequiredArtifact("sanitization-report.json")
    }
    let evidenceURL = root.appendingPathComponent("evidence-report.json")
    let evidenceFingerprint = try FileFingerprint.read(
      evidenceURL, maximumByteCount: maximumManifestBytes)
    let evidence = try Data(contentsOf: evidenceURL)
    guard evidence.count == evidenceFingerprint.byteCount,
      manifest.evidenceState == .produced
        ? ReviewEvidenceIntegrity.validProduced(evidence)
        : ReviewEvidenceIntegrity.validFallback(evidence)
    else { throw ReviewPromotionIntegrityError.invalidRequiredArtifact("evidence-report.json") }
  }

  private static func requireReadOnly(_ url: URL, fileManager: FileManager) throws {
    let attributes = try fileManager.attributesOfItem(atPath: url.path)
    let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o777
    guard mode & 0o222 == 0 else {
      throw ReviewPromotionIntegrityError.mutableItem(url.path)
    }
  }
}
