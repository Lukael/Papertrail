import Darwin
import Foundation

public struct CodexModelDescriptor: Codable, Equatable, Sendable, Identifiable {
  public var id: String { model }
  public let model: String
  public let displayName: String
  public let hidden: Bool
  public let isDefault: Bool
  public let defaultReasoningEffort: CodexReasoningEffort
  public let supportedReasoningEfforts: [CodexReasoningEffort]

  public init(
    model: String, displayName: String, hidden: Bool, isDefault: Bool,
    defaultReasoningEffort: CodexReasoningEffort,
    supportedReasoningEfforts: [CodexReasoningEffort]
  ) {
    self.model = model
    self.displayName = displayName
    self.hidden = hidden
    self.isDefault = isDefault
    self.defaultReasoningEffort = defaultReasoningEffort
    self.supportedReasoningEfforts = supportedReasoningEfforts
  }

  private enum CodingKeys: String, CodingKey {
    case model, displayName, hidden, isDefault, defaultReasoningEffort, supportedReasoningEfforts
  }
  private struct Effort: Codable {
    let reasoningEffort: CodexReasoningEffort
  }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    model = try values.decode(String.self, forKey: .model)
    guard CodexInvocation.isValidModelIdentifier(model) else {
      throw DecodingError.dataCorruptedError(
        forKey: .model, in: values, debugDescription: "Invalid model identifier")
    }
    displayName = try values.decode(String.self, forKey: .displayName)
    hidden = try values.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    isDefault = try values.decode(Bool.self, forKey: .isDefault)
    defaultReasoningEffort = try values.decode(
      CodexReasoningEffort.self, forKey: .defaultReasoningEffort)
    supportedReasoningEfforts = try values.decode([Effort].self, forKey: .supportedReasoningEfforts)
      .map(\.reasoningEffort)
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    try values.encode(model, forKey: .model)
    try values.encode(displayName, forKey: .displayName)
    try values.encode(hidden, forKey: .hidden)
    try values.encode(isDefault, forKey: .isDefault)
    try values.encode(defaultReasoningEffort, forKey: .defaultReasoningEffort)
    try values.encode(
      supportedReasoningEfforts.map { Effort(reasoningEffort: $0) },
      forKey: .supportedReasoningEfforts)
  }
}

public enum CodexModelCatalogError: Error, LocalizedError {
  case timedOut, invalidResponse, outputLimit, emptyCatalog
  case serverFailure(String)

  public var errorDescription: String? {
    switch self {
    case .timedOut: "Codex model discovery timed out."
    case .invalidResponse: "Codex returned an invalid model catalog response."
    case .serverFailure(let detail): "Codex model discovery failed. \(detail)"
    case .outputLimit: "Codex model discovery exceeded its output limit."
    case .emptyCatalog: "Codex returned no available models."
    }
  }
}

public struct CodexModelCatalog: Sendable {
  public init() {}

  public func fetch(executableURL: URL, timeout: TimeInterval = 20) throws -> [CodexModelDescriptor]
  {
    guard executableURL.path.hasPrefix("/") else {
      throw CodexInvocationError.executableMustBeAbsolute
    }
    guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
      throw CodexInvocationError.executableNotRunnable
    }
    guard timeout.isFinite, timeout > 0 else { throw CodexModelCatalogError.timedOut }
    let process = Process()
    let input = Pipe()
    let output = Pipe()
    let errors = Pipe()
    process.executableURL = executableURL
    process.arguments = ["app-server", "--listen", "stdio://", "-c", #"model_provider="openai""#]
    process.environment = CodexCapabilityChecker.minimalEnvironment()
    process.currentDirectoryURL = FileManager.default.temporaryDirectory
    process.standardInput = input
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    try? input.fileHandleForReading.close()
    try? output.fileHandleForWriting.close()
    try? errors.fileHandleForWriting.close()
    defer {
      try? input.fileHandleForWriting.close()
      if process.isRunning {
        process.terminate()
        let grace = Date().addingTimeInterval(0.2)
        while process.isRunning, Date() < grace { Thread.sleep(forTimeInterval: 0.005) }
        if process.isRunning { Darwin.kill(process.processIdentifier, SIGKILL) }
      }
      process.waitUntilExit()
      try? output.fileHandleForReading.close()
      try? errors.fileHandleForReading.close()
    }
    let descriptor = output.fileHandleForReading.fileDescriptor
    let inputDescriptor = input.fileHandleForWriting.fileDescriptor
    let errorDescriptor = errors.fileHandleForReading.fileDescriptor
    guard fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) != -1,
      fcntl(inputDescriptor, F_SETFL, fcntl(inputDescriptor, F_GETFL) | O_NONBLOCK) != -1,
      fcntl(errorDescriptor, F_SETFL, fcntl(errorDescriptor, F_GETFL) | O_NONBLOCK) != -1,
      fcntl(inputDescriptor, F_SETNOSIGPIPE, 1) != -1
    else {
      throw CodexModelCatalogError.serverFailure("")
    }
    let deadline = Date().addingTimeInterval(timeout)
    var framer = CodexJSONLFramer()
    var records: [Data] = []
    var byteCount = 0
    var nextID = 0
    var stderr = Data()
    func drainStderr() {
      var buffer = [UInt8](repeating: 0, count: 4096)
      let count = Darwin.read(errorDescriptor, &buffer, buffer.count)
      if count > 0, stderr.count < 4096 {
        stderr.append(contentsOf: buffer.prefix(min(count, 4096 - stderr.count)))
      }
    }
    func failure(_ detail: String? = nil) -> CodexModelCatalogError {
      drainStderr()
      let data = detail.map { Data($0.utf8) } ?? stderr
      return .serverFailure(DiagnosticExporter(maximumStderrBytes: 4096).redactedStderr(data))
    }
    func write(_ message: [String: Any]) throws {
      guard Date() < deadline else { throw CodexModelCatalogError.timedOut }
      var data = try JSONSerialization.data(withJSONObject: message)
      data.append(0x0A)
      try data.withUnsafeBytes { bytes in
        var offset = 0
        while offset < bytes.count {
          guard Date() < deadline else { throw CodexModelCatalogError.timedOut }
          let count = Darwin.write(
            inputDescriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
          if count > 0 {
            offset += count
          } else if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
            Thread.sleep(forTimeInterval: 0.005)
          } else {
            throw failure()
          }
        }
      }
    }
    func request(_ method: String, params: [String: Any]) throws -> Data {
      nextID += 1
      let id = nextID
      try write(["id": id, "method": method, "params": params])
      while Date() < deadline {
        drainStderr()
        while !records.isEmpty {
          let record = records.removeFirst()
          guard let message = try JSONSerialization.jsonObject(with: record) as? [String: Any]
          else {
            throw CodexModelCatalogError.invalidResponse
          }
          guard message["id"] != nil else { continue }  // Server notifications.
          guard let responseID = message["id"] as? Int, responseID == id else {
            throw CodexModelCatalogError.invalidResponse
          }
          if let error = message["error"] as? [String: Any] {
            let code = error["code"] as? Int ?? 0
            throw failure("RPC \(code): \(error["message"] as? String ?? "Unknown error")")
          }
          guard message["error"] == nil, let result = message["result"] else {
            throw failure()
          }
          return try JSONSerialization.data(withJSONObject: result, options: [.fragmentsAllowed])
        }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let count = Darwin.read(descriptor, &buffer, buffer.count)
        if count > 0 {
          byteCount += count
          guard byteCount <= 8_388_608 else { throw CodexModelCatalogError.outputLimit }
          let batch = framer.consume(Data(buffer.prefix(count)))
          guard batch.error == nil else { throw CodexModelCatalogError.invalidResponse }
          guard records.count + batch.records.count <= 1_000 else {
            throw CodexModelCatalogError.outputLimit
          }
          records.append(contentsOf: batch.records)
        } else if count == 0 {
          try framer.finish()
          throw failure()
        } else if errno != EAGAIN && errno != EWOULDBLOCK && errno != EINTR {
          throw failure()
        } else {
          Thread.sleep(forTimeInterval: 0.005)
        }
      }
      throw CodexModelCatalogError.timedOut
    }
    _ = try request(
      "initialize",
      params: [
        "clientInfo": ["name": "papertrail", "title": "Papertrail", "version": "1.0"]
      ])
    try write(["method": "initialized"])
    var cursor: String?
    var cursors = Set<String>()
    var identifiers = Set<String>()
    var models: [CodexModelDescriptor] = []
    for _ in 0..<100 {
      var params: [String: Any] = ["limit": 100, "includeHidden": false]
      if let cursor { params["cursor"] = cursor }
      let page = try JSONDecoder().decode(Page.self, from: request("model/list", params: params))
      for model in page.data where !model.hidden && identifiers.insert(model.model).inserted {
        models.append(model)
      }
      guard let next = page.nextCursor else {
        guard !models.isEmpty else { throw CodexModelCatalogError.emptyCatalog }
        return models
      }
      guard !next.isEmpty, next.utf8.count <= 4096, cursors.insert(next).inserted else {
        throw CodexModelCatalogError.invalidResponse
      }
      cursor = next
    }
    throw CodexModelCatalogError.outputLimit
  }

  private struct Page: Decodable {
    let data: [CodexModelDescriptor]
    let nextCursor: String?
  }
}
