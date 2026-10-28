import Foundation
import PDFKit

public enum ReviewDeckExportError: Error, Equatable, LocalizedError, Sendable {
  case documentMissing
  case packagingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .documentMissing:
      "This review version has no presentation document to export. Generate a new version first."
    case .packagingFailed(let detail): "The PowerPoint file could not be written: \(detail)"
    }
  }
}

/// Writes a presentation as an editable PowerPoint file (which Google Slides and Keynote also
/// open): slide text in real placeholders, the script and Q&A as speaker notes, and each
/// referenced figure or table cropped from the paper's PDF.
public struct ReviewDeckExporter {
  public struct Summary: Equatable, Sendable {
    public let slideCount: Int
    public let figureCount: Int
    public let placedFigureCount: Int
  }

  public init() {}

  /// The document a promoted version was rendered from: the generation's validated output, with
  /// unverifiable excerpts pruned again when the generation needed that last resort.
  public static func promotedDocument(
    workspace: URL, operationID: UUID, pageTexts: () throws -> [String]
  ) throws -> ReviewDocumentV2 {
    let url = workspace.appendingPathComponent(
      "output/operations/\(operationID.uuidString.lowercased())/review.json")
    guard var data = try? Data(contentsOf: url) else { throw ReviewDeckExportError.documentMissing }
    // Decks generated before equation cards omit the key; it means none.
    if var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
      var slides = object["slides"] as? [[String: Any]]
    {
      for index in slides.indices where slides[index]["equations"] == nil {
        slides[index]["equations"] = [Any]()
      }
      object["slides"] = slides
      data = (try? JSONSerialization.data(withJSONObject: object)) ?? data
    }
    guard let document = try? ReviewDocumentDecoder().decode(data) else {
      throw ReviewDeckExportError.documentMissing
    }
    guard FileManager.default.fileExists(
      atPath: workspace.appendingPathComponent("evidence-pruning.json").path)
    else { return document }
    return document.pruningUnverifiedEvidence(pageTexts: try pageTexts()).document
  }

  public func export(
    document: ReviewDocumentV2, paperTitle: String, pdf: PDFDocument?, to destination: URL
  ) throws -> Summary {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory.appendingPathComponent(
      "papertrail-deck-\(UUID().uuidString)", isDirectory: true)
    defer { try? fileManager.removeItem(at: root) }
    var package = Package(title: document.title)
    let pages = Dictionary(
      document.evidence.map { ($0.id, $0.pageIndex) }, uniquingKeysWith: { first, _ in first })
    let locator = pdf.map(PDFFigureLocator.init(document:))

    let subtitle = document.title.localizedCaseInsensitiveContains(paperTitle) ? "논문 발표" : paperTitle
    package.addSlide(Slide.titleSlide(title: document.title, subtitle: subtitle))
    var figureCount = 0, placed = 0
    for (index, slide) in document.slides.enumerated() {
      var images: [Slide.Figure] = []
      var missing: [String] = []
      for figure in slide.figures {
        figureCount += 1
        let hints = figure.evidenceIDs.compactMap { pages[$0].map { $0 - 1 } }
        guard let locator, let location = locator.locate(label: figure.label, pageHints: hints),
          let image = locator.renderImage(location)
        else {
          missing.append(figure.label)
          continue
        }
        placed += 1
        images.append(Slide.Figure(
          label: figure.label, page: location.pageIndex + 1, image: image,
          aspect: location.rect.width / max(location.rect.height, 1),
          isWholePage: location.isWholePage))
      }
      package.addSlide(Slide(
        number: index + 2, review: slide, pages: pages, figures: images, missingFigures: missing))
    }

    try package.write(to: root)
    let archive = root.appendingPathComponent("deck.pptx")
    let zip = Process()
    zip.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zip.currentDirectoryURL = root
    zip.arguments = ["-X", "-D", "-r", "-q", "deck.pptx", "[Content_Types].xml", "_rels", "docProps", "ppt"]
    try zip.run()
    zip.waitUntilExit()
    guard zip.terminationStatus == 0 else {
      throw ReviewDeckExportError.packagingFailed("zip exited with \(zip.terminationStatus)")
    }
    if fileManager.fileExists(atPath: destination.path) {
      _ = try fileManager.replaceItemAt(destination, withItemAt: archive)
    } else {
      try fileManager.moveItem(at: archive, to: destination)
    }
    return Summary(
      slideCount: document.slides.count + 1, figureCount: figureCount, placedFigureCount: placed)
  }
}

// MARK: - Slides

/// Slide geometry in EMU (914400 per inch) on a 13.333 × 7.5 inch, 16:9 slide.
private enum EMU {
  static let inch = 914_400
  static let slideWidth = 12_192_000
  static let slideHeight = 6_858_000
  static let margin = 548_640
  static let bodyTop = 1_554_480
  static let bodyHeight = 4_754_880
  static let contentWidth = slideWidth - 2 * margin
  static let gutter = 365_760
  static let leftWidth = 5_303_520
  static var rightX: Int { margin + leftWidth + gutter }
  static var rightWidth: Int { contentWidth - leftWidth - gutter }
}

private struct Slide {
  struct Figure {
    let label: String
    let page: Int
    let image: (data: Data, fileExtension: String)
    let aspect: CGFloat
    let isWholePage: Bool
  }

  var layout = 2
  var shapes: [String] = []
  var images: [(data: Data, fileExtension: String)] = []
  var notes: [String] = []

  static func titleSlide(title: String, subtitle: String) -> Slide {
    var slide = Slide()
    slide.layout = 1
    slide.shapes = [
      placeholder(id: 2, name: "Title 1", type: "ctrTitle", paragraphs: [paragraph(title)]),
      placeholder(id: 3, name: "Subtitle 2", type: "subTitle", idx: 1, paragraphs: [paragraph(subtitle)]),
    ]
    return slide
  }

  init() {}

  init(
    number: Int, review: ReviewSlide, pages: [String: Int], figures: [Figure], missingFigures: [String]
  ) {
    var id = 2
    func nextID() -> Int { id += 1; return id }

    var tag: String?
    switch review.kind {
    case .paper: tag = nil
    case .critique: tag = "비판적 검토"
    case .questions: tag = "토론 질문"
    }
    if let tag {
      shapes.append(Self.textBox(
        id: nextID(), name: "Section", x: EMU.margin, y: 137_160, width: EMU.contentWidth,
        height: 274_320, paragraphs: [Self.paragraph(tag, size: 1200, bold: true, color: "accent1")]))
    }
    shapes.append(Self.placeholder(id: 2, name: "Title 1", type: "title", paragraphs: [Self.paragraph(review.title)]))
    let hasMedia = !figures.isEmpty || !review.equations.isEmpty
    let size = hasMedia ? 2000 : 2400
    let bullets = review.points.map { point -> (text: String, xml: String) in
      let cited = Array(Set(point.evidenceIDs.compactMap { pages[$0] })).sorted()
      let reference = cited.isEmpty ? "" : "  p." + cited.map(String.init).joined(separator: ", ")
      return (point.text + reference, Self.paragraph(runs: [
        Self.run(point.text, size: size), Self.run(reference, size: 1100, color: "8C8C8C"),
      ]))
    }

    // Figures go beside the text or in a band below it, whichever shows them larger; equation
    // cards always take the side column, under any figures.
    let captionHeight = 274_320, equationHeight = 868_680, gap = 137_160
    let equationsHeight = review.equations.count * (equationHeight + gap)
    var textFrame = hasMedia
      ? (EMU.margin, EMU.bodyTop, EMU.leftWidth, EMU.bodyHeight) : nil
    var placed = Self.grid(
      figures.map(\.aspect),
      in: CGRect(x: EMU.rightX, y: EMU.bodyTop, width: EMU.rightWidth, height: EMU.bodyHeight - equationsHeight),
      caption: captionHeight, gap: gap)
    if !figures.isEmpty && review.equations.isEmpty {
      let textHeight = min(
        max(Self.textHeight(bullets.map(\.text), width: EMU.contentWidth, size: size), EMU.inch),
        EMU.bodyHeight * 3 / 5)
      let band = Self.grid(
        figures.map(\.aspect),
        in: CGRect(
          x: EMU.margin, y: EMU.bodyTop + textHeight + gap, width: EMU.contentWidth,
          height: EMU.bodyHeight - textHeight - gap),
        caption: captionHeight, gap: gap)
      if band.area > placed.area {
        placed = band
        textFrame = (EMU.margin, EMU.bodyTop, EMU.contentWidth, textHeight)
      }
    }
    shapes.append(Self.placeholder(
      id: nextID(), name: "Content 2", idx: 1, paragraphs: bullets.map(\.xml), frame: textFrame))
    for (figure, frame) in zip(figures, placed.frames) {
      images.append(figure.image)
      shapes.append(Self.picture(
        id: nextID(), relationship: "rId\(images.count + 2)", name: figure.label,
        description: "\(figure.label), p.\(figure.page)", x: Int(frame.minX), y: Int(frame.minY),
        width: Int(frame.width), height: Int(frame.height)))
      let caption = "\(figure.label) · p.\(figure.page)" + (figure.isWholePage ? " (페이지 전체)" : "")
      shapes.append(Self.textBox(
        id: nextID(), name: "Caption", x: Int(frame.midX) - 1_371_600, y: Int(frame.maxY) + 45_720,
        width: 2_743_200, height: captionHeight,
        paragraphs: [Self.paragraph(caption, size: 1100, color: "6B7280", centered: true)]))
    }
    var y = EMU.bodyTop + EMU.bodyHeight - equationsHeight + gap
    for equation in review.equations {
      shapes.append(Self.textBox(
        id: nextID(), name: equation.label, x: EMU.rightX, y: y, width: EMU.rightWidth,
        height: equationHeight, fill: "bg2",
        paragraphs: [
          Self.paragraph(equation.label, size: 1100, bold: true, color: "accent1"),
          Self.paragraph(equation.latex, size: 1400, font: "Menlo"),
        ]))
      y += equationHeight + gap
    }
    shapes.append(Self.textBox(
      id: nextID(), name: "Slide Number", x: EMU.slideWidth - EMU.margin - 914_400,
      y: EMU.slideHeight - 411_480, width: 914_400, height: 274_320,
      paragraphs: [
        "<a:p><a:pPr algn=\"r\"/><a:fld id=\"{B6F15528-21DE-4FAA-801E-634DDDAF4B2B}\" type=\"slidenum\">"
          + "<a:rPr lang=\"en-US\" sz=\"1000\"><a:solidFill><a:srgbClr val=\"9CA3AF\"/></a:solidFill></a:rPr>"
          + "<a:t>\(number)</a:t></a:fld></a:p>"
      ]))

    notes = review.script.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    if !review.figures.isEmpty {
      notes += ["", "[그림·표 설명]"]
      notes += review.figures.map { figure in
        let page = figure.evidenceIDs.compactMap { pages[$0] }.first.map { " (p.\($0))" } ?? ""
        let missing = missingFigures.contains(figure.label) ? " — PDF에서 그림을 찾지 못했습니다." : ""
        return "\(figure.label)\(page): \(figure.description)\(missing)"
      }
    }
    if !review.equations.isEmpty {
      notes += ["", "[수식 해설]"]
      for equation in review.equations {
        notes += ["\(equation.label): \(equation.meaning)"]
        notes += equation.variables.map { "  \($0.symbol): \($0.meaning)" }
      }
    }
    if !review.qa.isEmpty {
      notes += ["", "[예상 질문]"]
      for item in review.qa { notes += ["Q. \(item.question)", "A. \(item.answer)"] }
    }
  }

  var xml: String {
    """
    \(Package.declaration)<p:sld \(Package.namespaces)><p:cSld><p:spTree>\(Package.groupHeader)\
    \(shapes.joined())</p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sld>
    """
  }

  // MARK: Shape builders

  static func placeholder(
    id: Int, name: String, type: String? = nil, idx: Int? = nil, paragraphs: [String],
    frame: (Int, Int, Int, Int)? = nil
  ) -> String {
    let typeAttribute = type.map { " type=\"\($0)\"" } ?? ""
    let idxAttribute = idx.map { " idx=\"\($0)\"" } ?? ""
    let spPr = frame.map { "<p:spPr>\(xfrm($0.0, $0.1, $0.2, $0.3))</p:spPr>" } ?? "<p:spPr/>"
    return """
      <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(escape(name))"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
      <p:nvPr><p:ph\(typeAttribute)\(idxAttribute)/></p:nvPr></p:nvSpPr>\(spPr)\
      <p:txBody><a:bodyPr><a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs.joined())</p:txBody></p:sp>
      """
  }

  static func textBox(
    id: Int, name: String, x: Int, y: Int, width: Int, height: Int, fill: String? = nil,
    paragraphs: [String]
  ) -> String {
    let fillXML = fill.map { "<a:solidFill><a:schemeClr val=\"\($0)\"/></a:solidFill>" } ?? "<a:noFill/>"
    let inset = fill == nil ? 0 : 91_440
    return """
      <p:sp><p:nvSpPr><p:cNvPr id="\(id)" name="\(escape(name))"/><p:cNvSpPr txBox="1"/><p:nvPr/></p:nvSpPr>\
      <p:spPr>\(xfrm(x, y, width, height))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\(fillXML)</p:spPr>\
      <p:txBody><a:bodyPr wrap="square" lIns="\(inset)" tIns="\(inset)" rIns="\(inset)" bIns="\(inset)">\
      <a:normAutofit/></a:bodyPr><a:lstStyle/>\(paragraphs.joined())</p:txBody></p:sp>
      """
  }

  static func picture(
    id: Int, relationship: String, name: String, description: String, x: Int, y: Int, width: Int,
    height: Int
  ) -> String {
    """
    <p:pic><p:nvPicPr><p:cNvPr id="\(id)" name="\(escape(name))" descr="\(escape(description))"/>\
    <p:cNvPicPr><a:picLocks noChangeAspect="1"/></p:cNvPicPr><p:nvPr/></p:nvPicPr>\
    <p:blipFill><a:blip r:embed="\(relationship)"/><a:stretch><a:fillRect/></a:stretch></p:blipFill>\
    <p:spPr>\(xfrm(x, y, width, height))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
    <a:ln w="6350"><a:solidFill><a:srgbClr val="D1D5DB"/></a:solidFill></a:ln></p:spPr></p:pic>
    """
  }

  /// Lays figures out in the column count that gives them the most total area; each cell holds
  /// a figure fitted to its aspect ratio with its caption below.
  static func grid(_ aspects: [CGFloat], in area: CGRect, caption: Int, gap: Int)
    -> (frames: [CGRect], area: CGFloat)
  {
    var best: (frames: [CGRect], area: CGFloat) = ([], 0)
    guard !aspects.isEmpty else { return best }
    for columns in 1...aspects.count {
      let rows = (aspects.count + columns - 1) / columns
      let cellWidth = (area.width - CGFloat(gap * (columns - 1))) / CGFloat(columns)
      let cellHeight = (area.height - CGFloat(gap * (rows - 1))) / CGFloat(rows)
      let imageHeight = cellHeight - CGFloat(caption)
      guard cellWidth > 0, imageHeight > 0 else { continue }
      var frames: [CGRect] = []
      for (index, aspect) in aspects.enumerated() {
        let width = min(cellWidth, imageHeight * aspect), height = width / aspect
        let cellX = area.minX + CGFloat(index % columns) * (cellWidth + CGFloat(gap))
        let cellY = area.minY + CGFloat(index / columns) * (cellHeight + CGFloat(gap))
        frames.append(CGRect(x: cellX + (cellWidth - width) / 2, y: cellY, width: width, height: height))
      }
      let total = frames.reduce(0) { $0 + $1.width * $1.height }
      if total > best.area { best = (frames, total) }
    }
    return best
  }

  /// A generous estimate of the bullets' height: Hangul and other wide glyphs take a full em,
  /// everything else about half.
  static func textHeight(_ texts: [String], width: Int, size: Int) -> Int {
    let em = CGFloat(size) / 100 * 12_700
    let usable = CGFloat(width - 285_750 - 182_880)
    let height = texts.reduce(CGFloat(91_440)) { total, text in
      let advance = text.unicodeScalars.reduce(CGFloat(0)) { $0 + ($1.value >= 0x1100 ? 1 : 0.55) } * em
      return total + max(1, (advance / usable).rounded(.up)) * em * 1.2 + 12 * 12_700
    }
    return Int(height)
  }

  static func xfrm(_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> String {
    "<a:xfrm><a:off x=\"\(x)\" y=\"\(y)\"/><a:ext cx=\"\(width)\" cy=\"\(height)\"/></a:xfrm>"
  }

  static func paragraph(
    _ text: String, size: Int? = nil, bold: Bool = false, color: String? = nil,
    font: String? = nil, centered: Bool = false
  ) -> String {
    paragraph(
      runs: [run(text, size: size, bold: bold, color: color, font: font)],
      properties: centered ? "<a:pPr algn=\"ctr\"/>" : "")
  }

  static func paragraph(runs: [String], properties: String = "") -> String {
    "<a:p>\(properties)\(runs.joined())</a:p>"
  }

  /// `color` is a scheme color name or a six-digit RGB hex value.
  static func run(
    _ text: String, size: Int? = nil, bold: Bool = false, color: String? = nil, font: String? = nil
  ) -> String {
    guard !text.isEmpty else { return "" }
    var attributes = "lang=\"ko-KR\""
    if let size { attributes += " sz=\"\(size)\"" }
    if bold { attributes += " b=\"1\"" }
    var children = ""
    if let color {
      children += color.count == 6 && color.allSatisfy(\.isHexDigit)
        ? "<a:solidFill><a:srgbClr val=\"\(color)\"/></a:solidFill>"
        : "<a:solidFill><a:schemeClr val=\"\(color)\"/></a:solidFill>"
    }
    if let font { children += "<a:latin typeface=\"\(font)\"/>" }
    return "<a:r><a:rPr \(attributes) dirty=\"0\">\(children)</a:rPr><a:t>\(escape(text))</a:t></a:r>"
  }

  /// Escapes markup and drops control characters XML 1.0 cannot carry.
  static func escape(_ text: String) -> String {
    var result = ""
    for scalar in text.unicodeScalars {
      switch scalar {
      case "&": result += "&amp;"
      case "<": result += "&lt;"
      case ">": result += "&gt;"
      case "\"": result += "&quot;"
      case "\t": result.unicodeScalars.append(" ")
      case _ where scalar.value < 0x20 || (0xFFFE...0xFFFF).contains(scalar.value): continue
      default: result.unicodeScalars.append(scalar)
      }
    }
    return result
  }
}

// MARK: - Package

/// The OOXML parts of a deck with one master, two layouts, and a notes master.
private struct Package {
  static let declaration = #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
  static let namespaces =
    #"xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main""#
  static let groupHeader =
    #"<p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr><a:xfrm><a:off x="0" y="0"/><a:ext cx="0" cy="0"/><a:chOff x="0" y="0"/><a:chExt cx="0" cy="0"/></a:xfrm></p:grpSpPr>"#
  private static let relationshipBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/"

  let title: String
  private var slides: [Slide] = []

  init(title: String) { self.title = title }

  mutating func addSlide(_ slide: Slide) { slides.append(slide) }

  func write(to root: URL) throws {
    var files: [String: Data] = [:]
    func put(_ path: String, _ xml: String) { files[path] = Data(xml.utf8) }
    var overrides = [
      ("/ppt/presentation.xml", "presentationml.presentation.main+xml"),
      ("/ppt/slideMasters/slideMaster1.xml", "presentationml.slideMaster+xml"),
      ("/ppt/slideLayouts/slideLayout1.xml", "presentationml.slideLayout+xml"),
      ("/ppt/slideLayouts/slideLayout2.xml", "presentationml.slideLayout+xml"),
      ("/ppt/notesMasters/notesMaster1.xml", "presentationml.notesMaster+xml"),
      ("/ppt/theme/theme1.xml", "theme+xml"),
      ("/ppt/theme/theme2.xml", "theme+xml"),
    ]
    var presentationRelationships = [
      ("rId1", "slideMaster", "slideMasters/slideMaster1.xml"),
      ("rId2", "notesMaster", "notesMasters/notesMaster1.xml"),
      ("rId3", "theme", "theme/theme1.xml"),
    ]
    var slideIDs = ""
    var mediaCount = 0
    for (offset, slide) in slides.enumerated() {
      let number = offset + 1
      overrides.append(("/ppt/slides/slide\(number).xml", "presentationml.slide+xml"))
      presentationRelationships.append(("rId\(number + 10)", "slide", "slides/slide\(number).xml"))
      slideIDs += #"<p:sldId id="\#(255 + number)" r:id="rId\#(number + 10)"/>"#
      put("ppt/slides/slide\(number).xml", slide.xml)
      var relationships = [("rId1", "slideLayout", "../slideLayouts/slideLayout\(slide.layout).xml")]
      if !slide.notes.isEmpty {
        relationships.append(("rId2", "notesSlide", "../notesSlides/notesSlide\(number).xml"))
        overrides.append(("/ppt/notesSlides/notesSlide\(number).xml", "presentationml.notesSlide+xml"))
        put("ppt/notesSlides/notesSlide\(number).xml", Self.notes(slide.notes))
        put("ppt/notesSlides/_rels/notesSlide\(number).xml.rels", Self.relationships([
          ("rId1", "notesMaster", "../notesMasters/notesMaster1.xml"),
          ("rId2", "slide", "../slides/slide\(number).xml"),
        ]))
      }
      for (index, image) in slide.images.enumerated() {
        mediaCount += 1
        let name = "image\(mediaCount).\(image.fileExtension)"
        files["ppt/media/\(name)"] = image.data
        relationships.append(("rId\(index + 3)", "image", "../media/\(name)"))
      }
      put("ppt/slides/_rels/slide\(number).xml.rels", Self.relationships(relationships))
    }

    put("[Content_Types].xml", """
      \(Self.declaration)<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">\
      <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>\
      <Default Extension="xml" ContentType="application/xml"/><Default Extension="png" ContentType="image/png"/>\
      <Default Extension="jpeg" ContentType="image/jpeg"/>\
      <Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/>\
      \(overrides.map { #"<Override PartName="\#($0.0)" ContentType="application/vnd.openxmlformats-officedocument.\#($0.1)"/>"# }.joined())\
      </Types>
      """)
    put("_rels/.rels", """
      \(Self.declaration)<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">\
      <Relationship Id="rId1" Type="\(Self.relationshipBase)officeDocument" Target="ppt/presentation.xml"/>\
      <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/>\
      </Relationships>
      """)
    put("docProps/core.xml", """
      \(Self.declaration)<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" \
      xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>\(Slide.escape(title))</dc:title>\
      <dc:creator>Papertrail</dc:creator></cp:coreProperties>
      """)
    put("ppt/presentation.xml", """
      \(Self.declaration)<p:presentation \(Self.namespaces) saveSubsetFonts="1">\
      <p:sldMasterIdLst><p:sldMasterId id="2147483648" r:id="rId1"/></p:sldMasterIdLst>\
      <p:notesMasterIdLst><p:notesMasterId r:id="rId2"/></p:notesMasterIdLst>\
      <p:sldIdLst>\(slideIDs)</p:sldIdLst>\
      <p:sldSz cx="\(EMU.slideWidth)" cy="\(EMU.slideHeight)"/><p:notesSz cx="6858000" cy="9144000"/>\
      </p:presentation>
      """)
    put("ppt/_rels/presentation.xml.rels", Self.relationships(presentationRelationships))
    put("ppt/slideMasters/slideMaster1.xml", Self.master)
    put("ppt/slideMasters/_rels/slideMaster1.xml.rels", Self.relationships([
      ("rId1", "slideLayout", "../slideLayouts/slideLayout1.xml"),
      ("rId2", "slideLayout", "../slideLayouts/slideLayout2.xml"),
      ("rId3", "theme", "../theme/theme1.xml"),
    ]))
    put("ppt/slideLayouts/slideLayout1.xml", Self.titleLayout)
    put("ppt/slideLayouts/slideLayout2.xml", Self.contentLayout)
    for layout in 1...2 {
      put("ppt/slideLayouts/_rels/slideLayout\(layout).xml.rels", Self.relationships([
        ("rId1", "slideMaster", "../slideMasters/slideMaster1.xml")
      ]))
    }
    put("ppt/notesMasters/notesMaster1.xml", Self.notesMaster)
    put("ppt/notesMasters/_rels/notesMaster1.xml.rels", Self.relationships([
      ("rId1", "theme", "../theme/theme2.xml")
    ]))
    put("ppt/theme/theme1.xml", Self.theme)
    put("ppt/theme/theme2.xml", Self.theme)

    for (path, data) in files {
      let url = root.appendingPathComponent(path)
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      try data.write(to: url)
    }
  }

  private static func relationships(_ items: [(String, String, String)]) -> String {
    declaration
      + #"<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">"#
      + items.map { #"<Relationship Id="\#($0.0)" Type="\#(relationshipBase)\#($0.1)" Target="\#($0.2)"/>"# }
      .joined() + "</Relationships>"
  }

  private static func notes(_ lines: [String]) -> String {
    let paragraphs = lines.map { line in
      line.isEmpty
        ? #"<a:p><a:endParaRPr lang="ko-KR"/></a:p>"#
        : #"<a:p><a:r><a:rPr lang="ko-KR" dirty="0"/><a:t>\#(Slide.escape(line))</a:t></a:r></a:p>"#
    }.joined()
    return """
      \(declaration)<p:notes \(namespaces)><p:cSld><p:spTree>\(groupHeader)\
      <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr>\
      <p:nvPr><p:ph type="sldImg"/></p:nvPr></p:nvSpPr><p:spPr/></p:sp>\
      <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
      <p:nvPr><p:ph type="body" idx="1"/></p:nvPr></p:nvSpPr><p:spPr/>\
      <p:txBody><a:bodyPr/><a:lstStyle/>\(paragraphs)</p:txBody></p:sp>\
      </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:notes>
      """
  }

  private static let colorMap =
    #"<p:clrMap bg1="lt1" tx1="dk1" bg2="lt2" tx2="dk2" accent1="accent1" accent2="accent2" accent3="accent3" accent4="accent4" accent5="accent5" accent6="accent6" hlink="hlink" folHlink="folHlink"/>"#

  private static func level(_ n: Int, size: Int, bullet: String?, margin: Int = 0, bold: Bool = false, color: String = "tx1") -> String {
    let bulletXML = bullet.map {
      #"<a:buClr><a:schemeClr val="accent1"/></a:buClr><a:buFont typeface="Arial"/><a:buChar char="\#($0)"/>"#
    } ?? "<a:buNone/>"
    let indent = bullet == nil ? "" : #" marL="\#(margin)" indent="-\#(min(margin, 285_750))""#
    return #"<a:lvl\#(n)pPr\#(indent) algn="l"><a:spcBef><a:spcPts val="\#(bullet == nil ? 0 : 1200)"/></a:spcBef>\#(bulletXML)<a:defRPr sz="\#(size)"\#(bold ? #" b="1""# : "")><a:solidFill><a:schemeClr val="\#(color)"/></a:solidFill><a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl\#(n)pPr>"#
  }

  private static var master: String {
    let title = Slide.placeholder(
      id: 2, name: "Title Placeholder 1", type: "title", paragraphs: [Slide.paragraph("Title")],
      frame: (EMU.margin, 228_600, EMU.contentWidth, 960_120))
      .replacingOccurrences(of: "<a:bodyPr>", with: #"<a:bodyPr anchor="b">"#)
    let body = Slide.placeholder(
      id: 3, name: "Text Placeholder 2", type: "body", idx: 1, paragraphs: [Slide.paragraph("Text")],
      frame: (EMU.margin, EMU.bodyTop, EMU.contentWidth, EMU.bodyHeight))
    // A short accent rule under every title.
    let accent = """
      <p:sp><p:nvSpPr><p:cNvPr id="4" name="Accent"/><p:cNvSpPr/><p:nvPr userDrawn="1"/></p:nvSpPr>\
      <p:spPr>\(Slide.xfrm(EMU.margin, 1_243_584, 731_520, 45_720))<a:prstGeom prst="rect"><a:avLst/></a:prstGeom>\
      <a:solidFill><a:schemeClr val="accent1"/></a:solidFill><a:ln><a:noFill/></a:ln></p:spPr></p:sp>
      """
    return """
      \(declaration)<p:sldMaster \(namespaces)><p:cSld><p:bg><p:bgPr><a:solidFill><a:schemeClr val="bg1"/></a:solidFill>\
      <a:effectLst/></p:bgPr></p:bg><p:spTree>\(groupHeader)\(title)\(body)\(accent)</p:spTree></p:cSld>\(colorMap)\
      <p:sldLayoutIdLst><p:sldLayoutId id="2147483649" r:id="rId1"/><p:sldLayoutId id="2147483650" r:id="rId2"/></p:sldLayoutIdLst>\
      <p:txStyles><p:titleStyle>\
      <a:lvl1pPr algn="l"><a:defRPr sz="2800" b="1"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
      <a:latin typeface="+mj-lt"/><a:ea typeface="+mj-ea"/><a:cs typeface="+mj-cs"/></a:defRPr></a:lvl1pPr></p:titleStyle>\
      <p:bodyStyle>\(level(1, size: 2000, bullet: "•", margin: 285_750))\(level(2, size: 1600, bullet: "–", margin: 685_800))</p:bodyStyle>\
      <p:otherStyle>\(level(1, size: 1400, bullet: nil))</p:otherStyle></p:txStyles></p:sldMaster>
      """
  }

  private static var titleLayout: String {
    let title = Slide.placeholder(
      id: 2, name: "Title 1", type: "ctrTitle", paragraphs: ["<a:p><a:endParaRPr lang=\"ko-KR\"/></a:p>"],
      frame: (EMU.margin, 2_011_680, EMU.contentWidth, 1_463_040))
    let subtitle = Slide.placeholder(
      id: 3, name: "Subtitle 2", type: "subTitle", idx: 1,
      paragraphs: ["<a:p><a:endParaRPr lang=\"ko-KR\"/></a:p>"],
      frame: (EMU.margin, 3_657_600, EMU.contentWidth, 1_097_280))
    return """
      \(declaration)<p:sldLayout \(namespaces) type="title" preserve="1"><p:cSld name="Title Slide"><p:spTree>\(groupHeader)\
      \(title.replacingOccurrences(of: "<a:lstStyle/>", with: #"<a:lstStyle><a:lvl1pPr><a:defRPr sz="3600"/></a:lvl1pPr></a:lstStyle>"#))\
      \(subtitle.replacingOccurrences(of: "<a:lstStyle/>", with: #"<a:lstStyle><a:lvl1pPr marL="0" indent="0"><a:buNone/><a:defRPr sz="1800"><a:solidFill><a:srgbClr val="6B7280"/></a:solidFill></a:defRPr></a:lvl1pPr></a:lstStyle>"#))\
      </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
      """
  }

  private static var contentLayout: String {
    let empty = ["<a:p><a:endParaRPr lang=\"ko-KR\"/></a:p>"]
    return """
      \(declaration)<p:sldLayout \(namespaces) type="obj" preserve="1"><p:cSld name="Title and Content"><p:spTree>\(groupHeader)\
      \(Slide.placeholder(id: 2, name: "Title 1", type: "title", paragraphs: empty))\
      \(Slide.placeholder(id: 3, name: "Content Placeholder 2", idx: 1, paragraphs: empty))\
      </p:spTree></p:cSld><p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>
      """
  }

  private static var notesMaster: String {
    """
    \(declaration)<p:notesMaster \(namespaces)><p:cSld><p:bg><p:bgRef idx="1001"><a:schemeClr val="bg1"/></p:bgRef></p:bg><p:spTree>\(groupHeader)\
    <p:sp><p:nvSpPr><p:cNvPr id="2" name="Slide Image Placeholder 1"/><p:cNvSpPr><a:spLocks noGrp="1" noRot="1" noChangeAspect="1"/></p:cNvSpPr>\
    <p:nvPr><p:ph type="sldImg" idx="2"/></p:nvPr></p:nvSpPr><p:spPr>\(Slide.xfrm(685_800, 1_143_000, 5_486_400, 3_086_100))\
    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom><a:noFill/><a:ln w="12700"><a:solidFill><a:prstClr val="black"/></a:solidFill></a:ln></p:spPr></p:sp>\
    <p:sp><p:nvSpPr><p:cNvPr id="3" name="Notes Placeholder 2"/><p:cNvSpPr><a:spLocks noGrp="1"/></p:cNvSpPr>\
    <p:nvPr><p:ph type="body" sz="quarter" idx="3"/></p:nvPr></p:nvSpPr><p:spPr>\(Slide.xfrm(685_800, 4_400_550, 5_486_400, 3_600_450))\
    <a:prstGeom prst="rect"><a:avLst/></a:prstGeom></p:spPr><p:txBody><a:bodyPr/><a:lstStyle/>\
    <a:p><a:endParaRPr lang="ko-KR"/></a:p></p:txBody></p:sp></p:spTree></p:cSld>\(colorMap)\
    <p:notesStyle><a:lvl1pPr marL="0" algn="l"><a:defRPr sz="1200"><a:solidFill><a:schemeClr val="tx1"/></a:solidFill>\
    <a:latin typeface="+mn-lt"/><a:ea typeface="+mn-ea"/><a:cs typeface="+mn-cs"/></a:defRPr></a:lvl1pPr></p:notesStyle></p:notesMaster>
    """
  }

  private static var theme: String {
    let fonts = #"<a:latin typeface="Arial"/><a:ea typeface=""/><a:cs typeface=""/><a:font script="Hang" typeface="맑은 고딕"/>"#
    let fills = String(repeating: #"<a:solidFill><a:schemeClr val="phClr"/></a:solidFill>"#, count: 3)
    let lines = [6350, 12700, 19050].map {
      #"<a:ln w="\#($0)"><a:solidFill><a:schemeClr val="phClr"/></a:solidFill></a:ln>"#
    }.joined()
    let colors = [
      ("dk1", "1F2328"), ("lt1", "FFFFFF"), ("dk2", "334155"), ("lt2", "F1F5F9"),
      ("accent1", "0F766E"), ("accent2", "C2410C"), ("accent3", "2563EB"), ("accent4", "7C3AED"),
      ("accent5", "CA8A04"), ("accent6", "DB2777"), ("hlink", "2563EB"), ("folHlink", "7C3AED"),
    ].map { "<a:\($0.0)><a:srgbClr val=\"\($0.1)\"/></a:\($0.0)>" }.joined()
    return """
      \(declaration)<a:theme xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" name="Papertrail">\
      <a:themeElements><a:clrScheme name="Papertrail">\(colors)</a:clrScheme>\
      <a:fontScheme name="Papertrail"><a:majorFont>\(fonts)</a:majorFont><a:minorFont>\(fonts)</a:minorFont></a:fontScheme>\
      <a:fmtScheme name="Papertrail"><a:fillStyleLst>\(fills)</a:fillStyleLst><a:lnStyleLst>\(lines)</a:lnStyleLst>\
      <a:effectStyleLst>\(String(repeating: "<a:effectStyle><a:effectLst/></a:effectStyle>", count: 3))</a:effectStyleLst>\
      <a:bgFillStyleLst>\(fills)</a:bgFillStyleLst></a:fmtScheme></a:themeElements>\
      <a:objectDefaults/><a:extraClrSchemeLst/></a:theme>
      """
  }
}
