import Foundation

public struct DiagnosticExporter: Sendable {
  public let maximumStderrBytes: Int

  public init(maximumStderrBytes: Int = 1_048_576) {
    self.maximumStderrBytes = maximumStderrBytes
  }

  public func writeRedactedStderr(
    _ data: Data, to url: URL, homePath: String? = ProcessInfo.processInfo.environment["HOME"]
  ) throws {
    let bounded = data.prefix(maximumStderrBytes)
    var text = String(decoding: bounded, as: UTF8.self)
    if let homePath, !homePath.isEmpty {
      text = text.replacingOccurrences(of: homePath, with: "<HOME>")
    }
    let patterns = [
      #"(?i)bearer\s+[A-Za-z0-9._~+\-/=]+"#,
      #"(?i)(api[_-]?key|access[_-]?token|refresh[_-]?token|authorization)[\"']?\s*[:=]\s*[\"']?[^\s\",}]+"#,
    ]
    for pattern in patterns {
      text = text.replacingOccurrences(of: pattern, with: "<REDACTED>", options: .regularExpression)
    }
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    try Data(text.utf8).write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}
