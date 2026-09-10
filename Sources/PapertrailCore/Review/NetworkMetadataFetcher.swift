@preconcurrency import Foundation

public enum NetworkMetadataResult: Codable, Equatable, Sendable {
  case available(title: String, canonicalURL: String)
  case unavailable(reason: String)

  private enum CodingKeys: String, CodingKey { case status, title, canonicalURL, reason }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .status) {
    case "available":
      self = .available(
        title: try values.decode(String.self, forKey: .title),
        canonicalURL: try values.decode(String.self, forKey: .canonicalURL))
    default:
      self = .unavailable(reason: try values.decode(String.self, forKey: .reason))
    }
  }

  public func encode(to encoder: Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .available(let title, let canonicalURL):
      try values.encode("available", forKey: .status)
      try values.encode(title, forKey: .title)
      try values.encode(canonicalURL, forKey: .canonicalURL)
    case .unavailable(let reason):
      try values.encode("unavailable", forKey: .status)
      try values.encode(reason, forKey: .reason)
    }
  }
}

public struct NetworkMetadataFetcher: Sendable {
  public init() {}

  public func fetch(from url: URL, timeout: TimeInterval = 2) async -> NetworkMetadataResult {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    configuration.urlCache = nil
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      let (data, response) = try await session.data(from: url)
      guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let title = object["title"] as? String,
        let canonicalURL = object["canonicalURL"] as? String
      else {
        return .unavailable(
          reason: "Metadata endpoint returned no usable authoritative record for \(url.absoluteString).")
      }
      return .available(title: title, canonicalURL: canonicalURL)
    } catch {
      return .unavailable(
        reason: "Metadata fetch failed for \(url.absoluteString): \(String(describing: error))")
    }
  }
}
