import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Finds a figure or table on a PDF page from its label ("Fig. 3", "Table 2") so the deck can
/// show the paper's own artwork. The caption locates the item; the drawing next to it, read from
/// the page's content stream, bounds it.
public struct PDFFigureLocator {
  public struct Location: Equatable {
    /// Zero-based page index.
    public let pageIndex: Int
    /// Region in page space; the whole crop box when the caption was found but no artwork.
    public let rect: CGRect
    public let isWholePage: Bool
  }

  private let document: PDFDocument

  public init(document: PDFDocument) {
    self.document = document
  }

  /// Searches the hinted zero-based pages first, then the rest of the document.
  public func locate(label: String, pageHints: [Int]) -> Location? {
    guard let (isTable, number) = Self.labelParts(label) else { return nil }
    let kind = isTable ? #"Tab(?:le)?\.?"# : #"Fig(?:ure)?\.?"#
    guard
      let caption = try? NSRegularExpression(
        pattern: #"(?i)^\s*(?:Supplementary\s+)?"# + kind + #"\s*"#
          + NSRegularExpression.escapedPattern(for: number) + #"(?![0-9A-Za-z])\s*(\S?)"#)
    else { return nil }
    var order = pageHints.filter { $0 >= 0 && $0 < document.pageCount }
    for index in 0..<document.pageCount where !order.contains(index) { order.append(index) }
    for index in order {
      guard let page = document.page(at: index),
        let location = locate(caption: caption, isTable: isTable, on: page, index: index)
      else { continue }
      return location
    }
    return nil
  }

  /// Renders a page region at roughly `maximumPixels` on its longer side: PNG keeps line art and
  /// text crisp, and photographic figures that would make a large PNG are stored as JPEG.
  public func renderImage(_ location: Location, maximumPixels: CGFloat = 2000)
    -> (data: Data, fileExtension: String)?
  {
    guard let page = document.page(at: location.pageIndex) else { return nil }
    let rect = location.rect
    let scale = min(4, maximumPixels / max(rect.width, rect.height, 1))
    let width = Int((rect.width * scale).rounded()), height = Int((rect.height * scale).rounded())
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: -rect.minX, y: -rect.minY)
    page.draw(with: .cropBox, to: context)
    guard let image = context.makeImage(), let png = Self.encode(image, as: .png) else { return nil }
    if png.count > 700_000, let jpeg = Self.encode(image, as: .jpeg), jpeg.count < png.count {
      return (jpeg, "jpeg")
    }
    return (png, "png")
  }

  private static func encode(_ image: CGImage, as type: UTType) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
  }

  /// "Supplementary Fig. S1" → (false, "S1"); "Table II" → (true, "II").
  static func labelParts(_ label: String) -> (isTable: Bool, number: String)? {
    let regex = try! NSRegularExpression(
      pattern: #"(?i)(fig(?:ure)?s?\.?|tab(?:le)?\.?)\s*([A-Z]?\d+|[IVXLC]+\b)"#)
    guard let match = regex.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)),
      let kind = Range(match.range(at: 1), in: label),
      let number = Range(match.range(at: 2), in: label)
    else { return nil }
    return (label[kind].lowercased().hasPrefix("tab"), String(label[number]))
  }

  private func locate(
    caption: NSRegularExpression, isTable: Bool, on page: PDFPage, index: Int
  ) -> Location? {
    let bounds = page.bounds(for: .cropBox)
    let lines = (page.selection(for: bounds)?.selectionsByLine() ?? []).map {
      (rect: $0.bounds(for: page), text: $0.string ?? "")
    }.filter { !$0.rect.isEmpty }

    // A caption is followed by punctuation or a capitalized title; running text ("Fig. 3 shows")
    // only matches when nothing better is on the page.
    var best: (index: Int, score: Int)?
    for (offset, line) in lines.enumerated() {
      guard
        let match = caption.firstMatch(
          in: line.text, range: NSRange(line.text.startIndex..., in: line.text))
      else { continue }
      let next = Range(match.range(at: 1), in: line.text).map { line.text[$0] } ?? ""
      let score =
        !next.isEmpty && ".:|—–-".contains(next) ? 2 : next.first?.isUppercase == true ? 1 : 0
      if best == nil || score > best!.score { best = (offset, score) }
    }
    guard let captionIndex = best?.index else { return nil }
    var block = lines[captionIndex].rect
    var last = block
    for line in lines[(captionIndex + 1)...] {
      let aligned =
        abs(line.rect.minX - block.minX) <= 4 || abs(line.rect.midX - block.midX) <= 4
      guard aligned, last.minY - line.rect.maxY <= 4, line.rect.maxY <= last.maxY else { break }
      block = block.union(line.rect)
      last = line.rect
    }

    let pageArea = bounds.width * bounds.height
    // Running headers and footers sit in the outer bands and never belong to a figure.
    let band = bounds.height * 0.06
    let usable = { (rect: CGRect) in
      !rect.isNull && rect.width * rect.height < pageArea * 0.8 && max(rect.width, rect.height) >= 4
        && rect.minY < bounds.maxY - band && rect.maxY > bounds.minY + band
    }
    let drawing = Self.drawing(on: page)
    let paths = drawing.paths.map { $0.intersection(bounds) }.filter(usable)
    let embedded = drawing.embedded.map { $0.intersection(bounds) }.filter(usable)
    let graphics = paths + embedded
    let texts = lines.enumerated().filter { $0.offset != captionIndex }.map(\.element.rect)
      .filter { !block.contains(CGPoint(x: $0.midX, y: $0.midY)) }
    let widths = lines.map { ($0.rect.width / 5).rounded() * 5 }.filter { $0 >= 100 }
    let bodyWidth =
      Dictionary(grouping: widths, by: { $0 }).max { $0.value.count < $1.value.count }?.key
      ?? bounds.width

    func insideGraphics(_ rect: CGRect) -> Bool {
      graphics.contains {
        $0.width * $0.height > 400 && $0.contains(CGPoint(x: rect.midX, y: rect.midY))
      }
    }
    // Body text is a full-width line stacked on another aligned full-width line.
    func isBody(_ rect: CGRect) -> Bool {
      guard rect.width >= bodyWidth * 0.9, !insideGraphics(rect) else { return false }
      return lines.contains { other in
        other.rect != rect && abs(other.rect.minX - rect.minX) <= 3
          && other.rect.width >= bodyWidth * 0.6
          && abs(other.rect.midY - rect.midY) <= 2.2 * max(rect.height, 8)
      }
    }
    // Walks away from the caption collecting drawing until a gap, body text, or another item.
    func walk(up: Bool) -> CGRect? {
      enum Kind { case text, path, embedded }
      var items: [(rect: CGRect, kind: Kind)] = paths.map { ($0, .path) }
      items += embedded.map { ($0, .embedded) }
      items += texts.map { ($0, .text) }
      items = items.filter {
        $0.rect.maxX > block.minX + 2 && $0.rect.minX < block.maxX - 2
          && (up ? $0.rect.maxY > block.maxY - 1 : $0.rect.minY < block.minY + 1)
      }.sorted { up ? $0.rect.minY < $1.rect.minY : $0.rect.maxY > $1.rect.maxY }
      var edge = up ? block.maxY : block.minY
      var region = CGRect.null
      for (rect, kind) in items {
        if (up ? rect.minY - edge : edge - rect.maxY) > 24 { break }
        if kind == .text && isBody(rect) { break }
        // A table holds no embedded images, and a figure ends at a neighbouring table's rule.
        if isTable && kind == .embedded && !region.isNull { break }
        let isRule = kind == .path && rect.height <= 1.5 && rect.width >= block.width * 0.5
        if !isTable && isRule && !region.isNull
          && !region.insetBy(dx: -1, dy: -1).contains(rect)
        { break }
        if kind != .text { region = region.union(rect) }
        edge = up ? max(edge, rect.maxY) : min(edge, rect.minY)
      }
      guard !region.isNull,
        isTable || (region.height >= 12 && region.width * region.height >= pageArea * 0.003)
      else { return nil }
      // Axis labels and legends often sit just outside the artwork's own bounds.
      for rect in texts where rect.intersects(region.insetBy(dx: -8, dy: -8)) && !isBody(rect) {
        region = region.union(rect)
      }
      return region
    }

    let found = isTable ? walk(up: false) ?? walk(up: true) : walk(up: true) ?? walk(up: false)
    guard let found else { return Location(pageIndex: index, rect: bounds, isWholePage: true) }
    return Location(
      pageIndex: index, rect: found.insetBy(dx: -4, dy: -4).intersection(bounds),
      isWholePage: false)
  }

  /// Bounding boxes of painted paths and of placed images and forms, in page space.
  static func drawing(on page: PDFPage) -> (paths: [CGRect], embedded: [CGRect]) {
    guard let pageRef = page.pageRef, let table = CGPDFOperatorTableCreate() else { return ([], []) }
    CGPDFOperatorTableSetCallback(table, "q") { _, info in
      let state = DrawingScan.from(info)
      state.stack.append(state.ctm)
    }
    CGPDFOperatorTableSetCallback(table, "Q") { _, info in
      let state = DrawingScan.from(info)
      if let saved = state.stack.popLast() { state.ctm = saved }
    }
    CGPDFOperatorTableSetCallback(table, "cm") { scanner, info in
      guard let n = DrawingScan.numbers(scanner, 6) else { return }
      let state = DrawingScan.from(info)
      state.ctm = CGAffineTransform(a: n[0], b: n[1], c: n[2], d: n[3], tx: n[4], ty: n[5])
        .concatenating(state.ctm)
    }
    CGPDFOperatorTableSetCallback(table, "m") { DrawingScan.from($1).addPoints($0, 1) }
    CGPDFOperatorTableSetCallback(table, "l") { DrawingScan.from($1).addPoints($0, 1) }
    CGPDFOperatorTableSetCallback(table, "c") { DrawingScan.from($1).addPoints($0, 3) }
    CGPDFOperatorTableSetCallback(table, "v") { DrawingScan.from($1).addPoints($0, 2) }
    CGPDFOperatorTableSetCallback(table, "y") { DrawingScan.from($1).addPoints($0, 2) }
    CGPDFOperatorTableSetCallback(table, "re") { scanner, info in
      guard let n = DrawingScan.numbers(scanner, 4) else { return }
      let state = DrawingScan.from(info)
      state.add(CGPoint(x: n[0], y: n[1]))
      state.add(CGPoint(x: n[0] + n[2], y: n[1] + n[3]))
    }
    for paint in ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*"] {
      CGPDFOperatorTableSetCallback(table, paint) { _, info in
        let state = DrawingScan.from(info)
        if !state.path.isNull { state.paths.append(state.path) }
        state.path = .null
      }
    }
    CGPDFOperatorTableSetCallback(table, "n") { _, info in DrawingScan.from(info).path = .null }
    CGPDFOperatorTableSetCallback(table, "Do") { scanner, info in
      var name: UnsafePointer<CChar>?
      var stream: CGPDFStreamRef?
      guard CGPDFScannerPopName(scanner, &name), let name,
        let object = CGPDFContentStreamGetResource(
          CGPDFScannerGetContentStream(scanner), "XObject", name),
        CGPDFObjectGetValue(object, .stream, &stream), let stream,
        let dictionary = CGPDFStreamGetDictionary(stream)
      else { return }
      // An image fills the unit square; a form draws inside its BBox under its Matrix.
      var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
      var matrix = CGAffineTransform.identity
      var subtype: UnsafePointer<CChar>?
      if CGPDFDictionaryGetName(dictionary, "Subtype", &subtype), let subtype,
        String(cString: subtype) == "Form"
      {
        var array: CGPDFArrayRef?
        if CGPDFDictionaryGetArray(dictionary, "BBox", &array), let array {
          var v = [CGPDFReal](repeating: 0, count: 4)
          for k in 0..<4 { CGPDFArrayGetNumber(array, k, &v[k]) }
          rect = CGRect(
            x: min(v[0], v[2]), y: min(v[1], v[3]), width: abs(v[2] - v[0]), height: abs(v[3] - v[1]))
        }
        if CGPDFDictionaryGetArray(dictionary, "Matrix", &array), let array {
          var v = [CGPDFReal](repeating: 0, count: 6)
          for k in 0..<6 { CGPDFArrayGetNumber(array, k, &v[k]) }
          matrix = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
        }
      }
      let state = DrawingScan.from(info)
      state.embedded.append(rect.applying(matrix.concatenating(state.ctm)))
    }
    let state = DrawingScan()
    let scanner = CGPDFScannerCreate(
      CGPDFContentStreamCreateWithPage(pageRef), table, Unmanaged.passUnretained(state).toOpaque())
    withExtendedLifetime(state) { _ = CGPDFScannerScan(scanner) }
    return (state.paths, state.embedded)
  }
}

/// Graphics state for `PDFFigureLocator.drawing(on:)`; the scanner's C callbacks receive it as
/// their info pointer.
private final class DrawingScan {
  var ctm = CGAffineTransform.identity
  var stack: [CGAffineTransform] = []
  var path = CGRect.null
  var paths: [CGRect] = []
  var embedded: [CGRect] = []

  static func from(_ info: UnsafeMutableRawPointer?) -> DrawingScan {
    Unmanaged<DrawingScan>.fromOpaque(info!).takeUnretainedValue()
  }

  static func numbers(_ scanner: CGPDFScannerRef, _ count: Int) -> [CGFloat]? {
    var values: [CGFloat] = []
    for _ in 0..<count {
      var value: CGPDFReal = 0
      guard CGPDFScannerPopNumber(scanner, &value) else { return nil }
      values.append(value)
    }
    return values.reversed()
  }

  func add(_ point: CGPoint) {
    path = path.union(CGRect(origin: point.applying(ctm), size: .zero))
  }

  func addPoints(_ scanner: CGPDFScannerRef, _ count: Int) {
    guard let values = Self.numbers(scanner, count * 2) else { return }
    for index in 0..<count { add(CGPoint(x: values[index * 2], y: values[index * 2 + 1])) }
  }
}
