import Foundation

#if canImport(PDFKit)
  import PDFKit
#endif

public enum PDFTitleSource: String, Codable, Sendable {
  case metadata
  case firstPageText
  case temporaryFilename
}

public struct ExtractedPDFTitle: Equatable, Sendable {
  public let title: String
  public let source: PDFTitleSource
  public let requiresCorrection: Bool
}

public enum PDFTitleExtractorError: Error, Equatable {
  case unreadablePDF(String)
}

public struct PDFTitleExtractor: Sendable {
  public init() {}

  public func extract(from url: URL) throws -> ExtractedPDFTitle {
    #if canImport(PDFKit)
      guard let document = PDFDocument(url: url) else {
        throw PDFTitleExtractorError.unreadablePDF(url.path)
      }
      if let rawTitle = document.documentAttributes?[PDFDocumentAttribute.titleAttribute]
        as? String,
        let title = FilenameSanitizer.displayTitle(rawTitle)
      {
        return ExtractedPDFTitle(title: title, source: .metadata, requiresCorrection: false)
      }
      if let pageText = document.page(at: 0)?.string {
        for line in pageText.split(whereSeparator: \Character.isNewline) {
          if let title = FilenameSanitizer.displayTitle(String(line)), title.count >= 4 {
            return ExtractedPDFTitle(
              title: title, source: .firstPageText, requiresCorrection: false)
          }
        }
      }
    #endif
    let fallback =
      FilenameSanitizer.displayTitle(url.deletingPathExtension().lastPathComponent)
      ?? "Untitled PDF"
    return ExtractedPDFTitle(title: fallback, source: .temporaryFilename, requiresCorrection: true)
  }
}
