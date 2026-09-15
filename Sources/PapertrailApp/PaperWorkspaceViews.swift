import PapertrailCore
import SwiftUI
import UniformTypeIdentifiers

#if !PPR_PORTABLE_SCHEMA
  import SwiftData
#endif

private struct ImportDraft: Identifiable {
  let id = UUID()
  let sourceURL: URL
  let sourceDescription: String
  let requiresCorrection: Bool
  let holdsSecurityScope: Bool
  var title: String
}

private enum PDFSelectionPurpose {
  case importPaper
  case supplementary(PaperListItem)
}

struct PaperLibraryView: View {
  let launchRepairMessage: String?
  @StateObject private var controller: PaperLibraryController
  @State private var selectedPaperID: UUID?
  @State private var isPDFImporterPresented = false
  @State private var pdfSelectionPurpose: PDFSelectionPurpose = .importPaper
  @State private var importDraft: ImportDraft?
  @State private var paperPendingDeletion: PaperListItem?
  @State private var paperPendingRename: PaperListItem?
  @State private var editedPaperTitle = ""
  @State private var showsAppInformation = false
  @State private var titleQuery = ""
  @State private var paperEditingTags: PaperListItem?

  #if PPR_PORTABLE_SCHEMA
    init(paths: LibraryPaths, launchRepairMessage: String?) {
      self.launchRepairMessage = launchRepairMessage
      _controller = StateObject(wrappedValue: PaperLibraryController(paths: paths))
    }
  #else
    init(paths: LibraryPaths, container: ModelContainer, launchRepairMessage: String?) {
      self.launchRepairMessage = launchRepairMessage
      _controller = StateObject(
        wrappedValue: PaperLibraryController(paths: paths, container: container))
    }
  #endif

  private var selectedPaper: PaperListItem? {
    controller.papers.first(where: { $0.id == selectedPaperID })
  }

  private var matchingPapers: [PaperListItem] {
    PaperListFilter.matching(controller.papers, title: titleQuery)
  }

  var body: some View {
    NavigationSplitView {
      VStack(spacing: 0) {
        HStack(spacing: 6) {
          Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
          TextField("Search paper titles", text: $titleQuery)
            .textFieldStyle(.plain)
            .accessibilityLabel("Search paper titles")
          if !titleQuery.isEmpty {
            Button { titleQuery = "" } label: {
              Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search")
          }
        }
        .padding(8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 10)
        .padding(.top, 10)
        Picker("Sort papers", selection: $controller.sortOrder) {
          ForEach(PaperSortOrder.allCases, id: \.self) { order in
            Text(order.title).tag(order)
          }
        }
        .padding(10)
        List(matchingPapers, selection: $selectedPaperID) { paper in
          HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
              Text(paper.title)
              if !paper.tags.isEmpty {
                Text(paper.tags.map { "#\($0)" }.joined(separator: "  "))
                  .font(.caption)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
                  .help(paper.tags.joined(separator: ", "))
              }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { paperEditingTags = paper } label: {
              Image(systemName: "tag")
            }
            .buttonStyle(.borderless)
            .help("Edit tags")
            .accessibilityLabel("Edit tags for \(paper.title)")
          }
          .tag(paper.id)
            .contextMenu {
              Button("Edit Tags…", systemImage: "tag") { paperEditingTags = paper }
              Button("Rename…", systemImage: "pencil") {
                editedPaperTitle = paper.title
                paperPendingRename = paper
              }
              Button("Add Supplementary PDF…", systemImage: "doc.badge.plus") {
                pdfSelectionPurpose = .supplementary(paper)
                isPDFImporterPresented = true
              }
              Button("Delete Paper…", systemImage: "trash", role: .destructive) {
                paperPendingDeletion = paper
              }
            }
        }
        .overlay {
          if controller.papers.isEmpty {
            ContentUnavailableView(
              "No papers", systemImage: "doc.richtext",
              description: Text("Import a local PDF or drop one into this window."))
          } else if matchingPapers.isEmpty {
            ContentUnavailableView(
              "No matching papers", systemImage: "magnifyingglass",
              description: Text("Try another paper title or clear the search."))
          }
        }
      }
      .navigationTitle("Papers")
    } detail: {
      if let selectedPaper {
        PaperWorkspaceView(
          paper: selectedPaper, controller: controller,
          reviewController: controller.reviewController(paperID: selectedPaper.id),
          chatController: controller.chatController(paperID: selectedPaper.id)
        )
        .id(selectedPaper.id)
      } else {
        ContentUnavailableView("Select a paper", systemImage: "sidebar.left")
      }
    }
    .sheet(item: $paperEditingTags) { paper in
      PaperTagsEditor(paper: paper) { tags in
        try controller.setTags(tags, paperID: paper.id)
      }
    }
    .dropDestination(for: URL.self) { urls, _ in
      guard
        let url = urls.first(where: {
          $0.pathExtension.caseInsensitiveCompare("pdf") == .orderedSame
        })
      else {
        controller.notice = "Drop a local PDF file to import it."
        controller.record(level: .warning, controller.notice ?? "Invalid drop.")
        return false
      }
      beginImport(url, holdsSecurityScope: false)
      return true
    }
    .fileImporter(
      isPresented: $isPDFImporterPresented, allowedContentTypes: [.pdf],
      allowsMultipleSelection: false
    ) { result in
      switch pdfSelectionPurpose {
      case .importPaper:
        do {
          guard let url = try result.get().first else { return }
          beginImport(url, holdsSecurityScope: url.startAccessingSecurityScopedResource())
        } catch {
          controller.notice = "The PDF could not be selected: \(error.localizedDescription)"
          controller.record(level: .error, controller.notice ?? "PDF selection failed.")
        }
      case .supplementary(let paper):
        do {
          guard let url = try result.get().first else { return }
          let holdsSecurityScope = url.startAccessingSecurityScopedResource()
          Task {
            defer {
              if holdsSecurityScope { url.stopAccessingSecurityScopedResource() }
            }
            do {
              _ = try await controller.addSupplementaryPDF(to: paper, from: url)
            } catch {
              controller.notice =
                "The supplementary PDF could not be added: \(error.localizedDescription)"
              controller.record(
                level: .error, controller.notice ?? "Supplementary PDF merge failed.")
            }
          }
        } catch {
          controller.notice = "The supplementary PDF could not be selected: \(error.localizedDescription)"
          controller.record(level: .error, controller.notice ?? "Supplementary PDF selection failed.")
        }
      }
    }
    .sheet(item: $importDraft) { draft in
      ImportConfirmationView(draft: draft) { title in
        defer {
          if draft.holdsSecurityScope { draft.sourceURL.stopAccessingSecurityScopedResource() }
        }
        do {
          let paper = try controller.importPDF(from: draft.sourceURL, title: title)
          selectedPaperID = paper.id
          importDraft = nil
        } catch {
          importDraft = nil
          controller.notice =
            "Import could not be recorded. Any verified orphan copy was preserved for recovery: \(error.localizedDescription)"
          controller.record(level: .error, controller.notice ?? "PDF import failed.")
        }
      } onCancel: {
        if draft.holdsSecurityScope { draft.sourceURL.stopAccessingSecurityScopedResource() }
        importDraft = nil
      }
    }
    .alert(
      "Rename paper",
      isPresented: Binding(
        get: { paperPendingRename != nil },
        set: { if !$0 { paperPendingRename = nil } }
      ),
      presenting: paperPendingRename
    ) { paper in
      TextField("Paper name", text: $editedPaperTitle)
      Button("Cancel", role: .cancel) { paperPendingRename = nil }
      Button("Save") {
        controller.renamePaper(paperID: paper.id, title: editedPaperTitle)
        paperPendingRename = nil
      }
      .disabled(FilenameSanitizer.displayTitle(editedPaperTitle) == nil)
    } message: { _ in
      Text("Enter a new name for this paper.")
    }
    .alert(
      "Delete \(paperPendingDeletion?.title ?? "paper")?",
      isPresented: Binding(
        get: { paperPendingDeletion != nil },
        set: { if !$0 { paperPendingDeletion = nil } }
      )
    ) {
      Button("Cancel", role: .cancel) { paperPendingDeletion = nil }
      Button("Delete Everything", role: .destructive) {
        guard let paper = paperPendingDeletion else { return }
        paperPendingDeletion = nil
        Task {
          if await controller.deletePaper(paperID: paper.id), selectedPaperID == paper.id {
            selectedPaperID = nil
          }
        }
      }
    } message: {
      Text("This permanently deletes the stored PDF copy, every review version, chat history, operation journal, and the paper's complete Papertrail directory. The original PDF outside Papertrail is not changed. This cannot be undone.")
    }
    .alert(
      "Paper library",
      isPresented: Binding(
        get: { controller.notice != nil },
        set: { if !$0 { controller.notice = nil } }
      )
    ) {
      Button("OK") { controller.notice = nil }
    } message: {
      Text(controller.notice ?? "")
    }
    .safeAreaInset(edge: .top) {
      if let launchRepairMessage {
        HStack {
          Label(launchRepairMessage, systemImage: "wrench.and.screwdriver")
          Spacer()
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.18))
      }
    }
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Menu {
          ForEach(CodexModelSelection.allCases) { model in
            Menu {
              ForEach(CodexReasoningEffort.allCases) { effort in
                Button {
                  controller.codexModel = model
                  controller.codexEffort = effort
                } label: {
                  if controller.codexModel == model && controller.codexEffort == effort {
                    Label(effort.title, systemImage: "checkmark")
                  } else {
                    Text(effort.title)
                  }
                }
              }
            } label: {
              if controller.codexModel == model {
                Label(model.title, systemImage: "checkmark")
              } else {
                Text(model.title)
              }
            }
          }
        } label: {
          Text("\(controller.codexModel.title) · \(controller.codexEffort.title)")
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 170, alignment: .leading)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(
          "Codex model \(controller.codexModel.title), reasoning effort \(controller.codexEffort.title)")
        .help("Choose a Codex model, then its reasoning effort, for new reviews and chats.")
        Button("App information", systemImage: "info.circle") {
          showsAppInformation.toggle()
        }
        .labelStyle(.iconOnly)
        .help("Show storage and security information")
      }
      ToolbarItem(placement: .primaryAction) {
        Button("Import PDF", systemImage: "plus") {
          pdfSelectionPurpose = .importPaper
          isPDFImporterPresented = true
        }
          .labelStyle(.iconOnly)
          .help("Copy a PDF losslessly into the private local library.")
      }
    }
    .safeAreaInset(edge: .bottom) {
      ActivityLogBar(log: controller.activityLog)
    }
    .overlay {
      if showsAppInformation {
        ZStack {
          Color.black.opacity(0.3)
            .ignoresSafeArea()
            .onTapGesture { showsAppInformation = false }

          appInformationPanel
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay {
              RoundedRectangle(cornerRadius: 16)
                .stroke(.separator.opacity(0.7), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.25), radius: 24, y: 10)
            .padding(32)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.97)))
        .accessibilityAddTraits(.isModal)
      }
    }
    .animation(.easeOut(duration: 0.16), value: showsAppInformation)
  }

  private var appInformationPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Label("Papertrail information", systemImage: "info.circle.fill")
          .font(.headline)
        Spacer()
        Button("Done") { showsAppInformation = false }
          .keyboardShortcut(.defaultAction)
      }
      if let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String {
        Text("v\(version)")
          .font(.subheadline.monospacedDigit())
          .foregroundStyle(.secondary)
      }
      VStack(alignment: .leading, spacing: 5) {
        Label("Private local storage", systemImage: "lock.laptopcomputer")
          .font(.callout.weight(.semibold))
        Text("Paper, review versions, chat history, and operation journals are stored locally. Nothing is auto-deleted.")
        Text(controller.paths.root.path)
          .font(.caption.monospaced())
          .textSelection(.enabled)
      }
      Divider()
      VStack(alignment: .leading, spacing: 6) {
        Label("Review renderer", systemImage: "network.slash")
          .font(.callout.weight(.semibold))
        Text("Local-only WebView · JavaScript, bridges, remote resources, downloads, and popups are disabled.")
        Label("Codex process", systemImage: "exclamationmark.shield")
          .font(.callout.weight(.semibold))
        Text("Workspace writes are allowed with the accepted residual read, network, and process-spawning authority.")
      }
      .foregroundStyle(.secondary)
    }
    .font(.caption)
    .padding(20)
    .frame(width: 500)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Papertrail storage and security information")
  }

  private func beginImport(_ url: URL, holdsSecurityScope: Bool) {
    do {
      let prepared = try controller.prepareImport(from: url)
      importDraft = ImportDraft(
        sourceURL: url,
        sourceDescription: prepared.extractedTitle.source.rawValue,
        requiresCorrection: prepared.extractedTitle.requiresCorrection,
        holdsSecurityScope: holdsSecurityScope,
        title: prepared.extractedTitle.title)
    } catch {
      if holdsSecurityScope { url.stopAccessingSecurityScopedResource() }
      controller.notice = "Import was rejected before copying: \(error.localizedDescription)"
      controller.record(level: .error, controller.notice ?? "PDF import preparation failed.")
    }
  }
}

private struct ImportConfirmationView: View {
  let draft: ImportDraft
  let onImport: (String) -> Void
  let onCancel: () -> Void
  @State private var title: String

  init(draft: ImportDraft, onImport: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
    self.draft = draft
    self.onImport = onImport
    self.onCancel = onCancel
    _title = State(initialValue: draft.title)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Import PDF").font(.title2).bold()
      Text(draft.sourceURL.lastPathComponent).foregroundStyle(.secondary)
      TextField("Paper title", text: $title)
      if draft.requiresCorrection {
        Label(
          "No embedded or first-page title was found. Confirm this temporary title.",
          systemImage: "exclamationmark.triangle"
        ).font(.callout).foregroundStyle(.orange)
      } else {
        Text("Suggested from \(draft.sourceDescription). You can correct it before copying.")
          .font(.callout).foregroundStyle(.secondary)
      }
      HStack {
        Spacer()
        Button("Cancel", action: onCancel)
        Button("Import") { onImport(title) }.buttonStyle(.borderedProminent)
          .disabled(FilenameSanitizer.displayTitle(title) == nil)
      }
    }
    .padding(24)
    .frame(width: 520)
  }
}

struct PaperWorkspaceView: View {
  let paper: PaperListItem
  @ObservedObject var controller: PaperLibraryController
  @ObservedObject var reviewController: ReviewGenerationController
  @ObservedObject var chatController: PaperChatController
  @State private var showsPaper = true
  @State private var showsReview = false
  @AppStorage("pdfDarkMode") private var pdfDarkMode = false

  private var chatView: some View {
    PaperChatView(controller: chatController)
  }

  var body: some View {
    HSplitView {
      VStack(spacing: 0) {
        workspaceHeader
        Divider()
        sourcePane
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      .frame(
        minWidth: showsPaper && showsReview ? 620 : 420, idealWidth: 720,
        maxHeight: .infinity, alignment: .top)

      chatView
        .frame(minWidth: 340, idealWidth: 440)
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Resizable paper and chat workspace")
    .navigationTitle(paper.title)
    .onAppear {
      controller.record(level: .debug, "Opened paper workspace: \(paper.title)")
    }
    .onChange(of: showsPaper) {
      controller.record(level: .debug, "Paper pane visibility changed to \(showsPaper).")
    }
    .onChange(of: showsReview) {
      controller.record(level: .debug, "Review pane visibility changed to \(showsReview).")
    }
  }

  private var workspaceHeader: some View {
    HStack(spacing: 12) {
      Toggle(isOn: paperVisibility) {
        Label("Paper", systemImage: "doc.richtext")
      }
      .toggleStyle(.button)
      .accessibilityHint("Show or hide the PDF pane. At least one source pane stays visible.")

      Toggle(isOn: reviewVisibility) {
        Label("Review", systemImage: "checklist")
      }
      .toggleStyle(.button)
      .accessibilityHint("Show or hide the review pane. At least one source pane stays visible.")
      Spacer()
      if showsPaper {
        Toggle(isOn: $pdfDarkMode) {
          Label("Dark PDF", systemImage: "moon.fill")
        }
        .toggleStyle(.button)
        .help("Turn PDF dark mode on or off")
        .accessibilityLabel("PDF dark mode")
      }
    }
    .padding(.horizontal, 14).padding(.vertical, 10)
    .background(.bar)
  }

  private var paperVisibility: Binding<Bool> {
    Binding(
      get: { showsPaper },
      set: { requested in
        if requested || showsReview { showsPaper = requested }
      })
  }

  private var reviewVisibility: Binding<Bool> {
    Binding(
      get: { showsReview },
      set: { requested in
        if requested || showsPaper { showsReview = requested }
      })
  }

  @ViewBuilder private var sourcePane: some View {
    if showsPaper && showsReview {
      GeometryReader { geometry in
        HSplitView {
          paperPane.frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity)
          ReviewGenerationView(controller: reviewController)
            .frame(minWidth: 300, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: geometry.size.width, height: geometry.size.height)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .accessibilityLabel("Resizable paper and review panes")
    } else if showsPaper {
      paperPane
    } else {
      ReviewGenerationView(controller: reviewController)
    }
  }

  @ViewBuilder private var paperPane: some View {
    if let url = try? controller.sourceURL(for: paper) {
      PDFDocumentView(
        url: url, pageIndex: paper.pageIndex, scale: paper.scale, isDarkMode: pdfDarkMode
      ) { page, scale in
        controller.updateReadingState(paperID: paper.id, pageIndex: page, scale: scale)
      }
      .accessibilityLabel("PDF reader for \(paper.title)")
    } else {
      ContentUnavailableView {
        Label("Stored PDF unavailable", systemImage: "doc.badge.ellipsis")
      } description: {
        Text("The source path is unsafe or missing. The record and any prior review or chat remain preserved for recovery.")
      } actions: {
        Button("Locate recovery folder") {
          NSWorkspace.shared.activateFileViewerSelecting([controller.paths.paper(paper.id)])
        }
      }
    }
  }
}

private struct ReviewGenerationView: View {
  @ObservedObject var controller: ReviewGenerationController

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Button(controller.generations.isEmpty ? "Generate document" : "Regenerate document", systemImage: "sparkles") {
          controller.generate()
        }.disabled(controller.isRunning)
        if controller.isRunning {
          Button("Cancel", role: .destructive) { controller.cancel() }
          ProgressView().controlSize(.small)
        }
        Spacer()
        Menu("Versions") {
          ForEach(controller.generations, id: \.id) { generation in
            Button(generation.label) { controller.select(generation) }
              .disabled(!generation.isSelectable)
          }
        }.disabled(controller.generations.isEmpty)
      }.padding(10)
      Divider()
      if let review = controller.selectedReviewLocation {
        ReviewHTMLPreview(location: review)
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        ContentUnavailableView(
          "No selectable review", systemImage: "checklist",
          description: Text("Generate a document from the paper and your conversation so far. Earlier versions are preserved."))
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Review reader")
  }
}

private struct ReviewHTMLPreview: View {
  let location: SelectedReviewLocation
  @StateObject private var externalLinks: ExternalLinkConfirmationController
  @State private var loadState: RestrictedReviewWebView.ReviewLoadState = .loading
  @State private var reloadToken = 0

  init(location: SelectedReviewLocation) {
    self.location = location
    _externalLinks = StateObject(
      wrappedValue: ExternalLinkConfirmationController { NSWorkspace.shared.open($0) })
  }

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        RestrictedReviewWebView(
          location: location, reloadToken: reloadToken,
          onExternalLinkRequested: { destination in externalLinks.request(destination) },
          onLoadStateChanged: { loadState = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel("Restricted local review reader")
        .accessibilityHint("JavaScript, bridges, downloads, popups, and remote resources are disabled")

        if case .loading = loadState {
          ProgressView().controlSize(.small).accessibilityLabel("Loading review")
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      if case .failed(let reason) = loadState {
        HStack {
          Label("The immutable review was preserved. \(reason)", systemImage: "arrow.clockwise.circle")
          Spacer()
          Button("Retry secure load") { reloadToken += 1 }
        }
        .font(.caption).padding(8).background(.orange.opacity(0.12))
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .alert(
      "Open external publication link?",
      isPresented: Binding(
        get: { externalLinks.pendingDestination != nil },
        set: { if !$0 { externalLinks.deny() } }
      ),
      presenting: externalLinks.pendingDestination
    ) { destination in
      Button("Cancel", role: .cancel) { externalLinks.deny() }
      Button("Open in Browser") { externalLinks.confirm() }
    } message: { destination in
      Text("The review cannot load this address. Open it in your system browser after confirming the destination:\n\n\(destination.absoluteString)")
    }
  }
}

private struct PaperChatView: View {
  @ObservedObject var controller: PaperChatController
  @AppStorage("chatTextSizePercent") private var textSizePercent = 100
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var activeQuestionID: UUID?
  @State private var isTranscriptNearBottom = true
  @State private var transcriptMetrics = ChatTranscriptMetrics()
  @State private var visibleMessageLimit = ChatTranscriptWindow.pageSize

  var body: some View {
    let questions = controller.messages.filter { $0.role == "user" }
    let questionNumbers = Dictionary(
      uniqueKeysWithValues: questions.enumerated().map { ($0.element.id, $0.offset + 1) })
    let firstVisibleIndex = ChatTranscriptWindow.startIndex(
      count: controller.messages.count, visibleLimit: visibleMessageLimit)

    return VStack(alignment: .leading, spacing: 0) {
      HStack {
        Label("Paper chat", systemImage: "bubble.left.and.bubble.right").font(.headline)
        Spacer()
        HStack(spacing: 4) {
          Button("A−") { textSizePercent = max(80, min(200, textSizePercent) - 10) }
            .disabled(textSizePercent <= 80)
            .accessibilityLabel("Decrease chat text size")
            .help("Decrease chat text size")
          Button("\(min(200, max(80, textSizePercent)))%") { textSizePercent = 100 }
            .monospacedDigit()
            .frame(minWidth: 48)
            .accessibilityLabel("Reset chat text size to 100 percent")
            .help("Reset chat text size to 100%")
          Button("A+") { textSizePercent = min(200, max(80, textSizePercent) + 10) }
            .disabled(textSizePercent >= 200)
            .accessibilityLabel("Increase chat text size")
            .help("Increase chat text size")
        }
        .controlSize(.small)
        Button("Refresh context", systemImage: "arrow.triangle.2.circlepath") {
          controller.refreshContext()
        }.disabled(controller.isRunning || !controller.isAvailable)
      }
      .padding(.horizontal)
      .padding(.top)
      .padding(.bottom, 10)
      Divider()
      ScrollViewReader { proxy in
        ZStack(alignment: .trailing) {
          ScrollView {
            // Keep native math views mounted: lazy recycling can leave WebKit blank.
            VStack(alignment: .leading, spacing: 18) {
              if firstVisibleIndex > 0 {
                Button("Load earlier messages (\(firstVisibleIndex))") {
                  let anchor = controller.messages[firstVisibleIndex].id
                  isTranscriptNearBottom = false
                  visibleMessageLimit += ChatTranscriptWindow.pageSize
                  DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
                }
                .frame(maxWidth: .infinity)
              }
              if controller.isLoading && controller.messages.isEmpty {
                ProgressView("Loading conversation…")
                  .frame(maxWidth: .infinity, minHeight: 240)
              } else if controller.messages.isEmpty {
                ContentUnavailableView {
                  Label("Start a conversation", systemImage: "bubble.left.and.bubble.right")
                } description: {
                  Text("Ask about this paper. Messages are stored by the app and survive relaunch.")
                }
                .frame(maxWidth: .infinity, minHeight: 240)
              }
              ForEach(controller.messages.suffix(from: firstVisibleIndex)) { message in
                ChatMessageRow(
                  message: message,
                  questionNumber: questionNumbers[message.id],
                  questionCount: questions.count,
                  isActiveQuestion: message.id == activeQuestionID,
                  canRetry: controller.canRetry(message) && !controller.isRunning,
                  onRetry: { controller.retry(message) })
                .id(message.id)
                .background {
                  if message.role == "user" {
                    GeometryReader { geometry in
                      Color.clear.preference(
                        key: ChatQuestionOffsetPreferenceKey.self,
                        value: [
                          message.id: geometry.frame(in: .named("paper-chat-scroll")).minY
                        ])
                    }
                  }
                }
              }
              if let live = controller.liveAssistant {
                ChatLiveResponseRow(state: live)
                  .id("live-assistant")
              }
              Color.clear
                .frame(height: 1)
                .id("chat-bottom")
                .background {
                  GeometryReader { geometry in
                    Color.clear.preference(
                      key: ChatBottomOffsetPreferenceKey.self,
                      value: geometry.frame(in: .named("paper-chat-scroll")).maxY)
                  }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(ChatScrollBoundaryView())
          }
          // Keep the transcript and the native scroll indicator out of the
          // trailing question-navigation rail, including at narrow widths.
          .padding(.trailing, 52)
          .coordinateSpace(name: "paper-chat-scroll")
          .background {
            GeometryReader { geometry in
              Color.clear.preference(
                key: ChatViewportHeightPreferenceKey.self,
                value: geometry.size.height)
            }
          }
          .onPreferenceChange(ChatViewportHeightPreferenceKey.self) { height in
            transcriptMetrics.viewportHeight = height
            updateTranscriptFollowState()
          }
          .onPreferenceChange(ChatQuestionOffsetPreferenceKey.self) { offsets in
            updateActiveQuestion(from: offsets)
          }
          .onPreferenceChange(ChatBottomOffsetPreferenceKey.self) { bottomOffset in
            transcriptMetrics.bottomOffset = bottomOffset
            updateTranscriptFollowState()
          }

          if !questions.isEmpty {
            ChatQuestionRail(
              questions: questions,
              activeQuestionID: activeQuestionID,
              onSelect: { questionID in
                activeQuestionID = questionID
                isTranscriptNearBottom = false
                if let index = controller.messages.firstIndex(where: { $0.id == questionID }),
                  index < firstVisibleIndex
                {
                  visibleMessageLimit = ChatTranscriptWindow.limitRevealing(
                    index: index, count: controller.messages.count,
                    currentLimit: visibleMessageLimit)
                  DispatchQueue.main.async { scroll(proxy, to: questionID, anchor: .top) }
                } else {
                  scroll(proxy, to: questionID, anchor: .top)
                }
              }
            )
            .padding(.trailing, 10)
            .padding(.vertical, 14)
          }
        }
        .onChange(of: controller.messages.count) { oldCount, newCount in
          visibleMessageLimit = ChatTranscriptWindow.adjustedLimit(
            visibleMessageLimit, oldCount: oldCount, newCount: newCount)
          if let last = controller.messages.last {
            if last.role == "user" {
              activeQuestionID = last.id
              isTranscriptNearBottom = true
              proxy.scrollTo("chat-bottom", anchor: .bottom)
            } else if isTranscriptNearBottom {
              proxy.scrollTo("chat-bottom", anchor: .bottom)
            }
          }
        }
        .onChange(of: controller.liveRevision) {
          if controller.liveAssistant != nil, isTranscriptNearBottom {
            proxy.scrollTo("live-assistant", anchor: .bottom)
          }
        }
        .onAppear {
          if activeQuestionID == nil { activeQuestionID = questions.last?.id }
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      chatComposerPanel
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Paper-scoped chat")
  }

  private func updateActiveQuestion(from offsets: [UUID: CGFloat]) {
    guard !offsets.isEmpty else { return }
    let activationLine: CGFloat = 44
    let preceding = offsets.filter { $0.value <= activationLine }.max { $0.value < $1.value }
    let following = offsets.filter { $0.value > activationLine }.min { $0.value < $1.value }
    if let candidate = preceding ?? following, candidate.key != activeQuestionID {
      activeQuestionID = candidate.key
    }
  }

  private func updateTranscriptFollowState() {
    guard transcriptMetrics.viewportHeight > 0 else { return }
    let isNearBottom = transcriptMetrics.bottomOffset.map {
      $0 <= transcriptMetrics.viewportHeight + 96
    } ?? false
    if isNearBottom != isTranscriptNearBottom {
      isTranscriptNearBottom = isNearBottom
    }
  }

  private func scroll(_ proxy: ScrollViewProxy, to questionID: UUID, anchor: UnitPoint) {
    if reduceMotion {
      proxy.scrollTo(questionID, anchor: anchor)
    } else {
      withAnimation(.easeInOut(duration: 0.2)) {
        proxy.scrollTo(questionID, anchor: anchor)
      }
    }
  }

  private var chatComposerPanel: some View {
    chatComposer
    .frame(maxWidth: .infinity)
    .padding(.horizontal, 14)
    .padding(.top, 10)
    // NavigationSplitView does not propagate the library-level bottom inset into
    // its detail column on macOS. Reserve the disclosure bar height explicitly.
    .padding(.bottom, 40)
    .frame(maxWidth: .infinity)
    .background(.bar)
    .overlay(alignment: .top) { Divider() }
  }

  private var chatComposer: some View {
    HStack(alignment: .bottom, spacing: 10) {
      TextField("Ask about this paper", text: $controller.input, axis: .vertical)
        .textFieldStyle(.plain)
        .lineLimit(1...6)
        .disabled(controller.isRunning)
        .onSubmit { controller.send() }

      if controller.isRunning {
        Button("Cancel", systemImage: "stop.fill", role: .destructive) {
          controller.cancel()
        }
        .labelStyle(.iconOnly)
        .help("Cancel response")
      } else {
        Button("Send", systemImage: "arrow.up") { controller.send() }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.circle)
          .controlSize(.small)
          .disabled(
            controller.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
              || !controller.isAvailable)
          .help("Send message")
      }
    }
    .padding(.horizontal, 13)
    .padding(.vertical, 10)
    .background(.regularMaterial)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 16, style: .continuous)
        .stroke(Color.secondary.opacity(0.22), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
  }
}

/// High-frequency geometry samples must not invalidate the full transcript.
/// Only derived navigation/follow-state changes are published through SwiftUI state.
private final class ChatTranscriptMetrics {
  var viewportHeight: CGFloat = 0
  var bottomOffset: CGFloat?
}

private struct ChatQuestionOffsetPreferenceKey: PreferenceKey {
  static let defaultValue: [UUID: CGFloat] = [:]

  static func reduce(value: inout [UUID: CGFloat], nextValue: () -> [UUID: CGFloat]) {
    value.merge(nextValue(), uniquingKeysWith: { _, new in new })
  }
}

private struct ChatBottomOffsetPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat? = nil

  static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
    value = nextValue() ?? value
  }
}

private struct ChatViewportHeightPreferenceKey: PreferenceKey {
  static let defaultValue: CGFloat = 0

  static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
    value = nextValue()
  }
}

private struct ChatQuestionRail: View {
  let questions: [ChatMessageRecord]
  let activeQuestionID: UUID?
  let onSelect: (UUID) -> Void
  @State private var hoveredQuestionID: UUID?

  private var activeIndex: Int {
    questions.firstIndex(where: { $0.id == activeQuestionID }) ?? max(questions.count - 1, 0)
  }

  var body: some View {
    VStack(spacing: 5) {
      Button {
        onSelect(questions[max(activeIndex - 1, 0)].id)
      } label: {
        Label("Previous question", systemImage: "chevron.up")
          .labelStyle(.iconOnly)
          .frame(width: 36, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background(Color.primary.opacity(0.07), in: Circle())
      .disabled(activeIndex == 0)
      .help("Previous question")

      ZStack {
        Capsule(style: .continuous)
          .fill(Color.primary.opacity(0.08))
          .frame(width: 6)

        ScrollViewReader { railProxy in
          ScrollView {
            LazyVStack(spacing: 0) {
              ForEach(Array(questions.enumerated()), id: \.element.id) { index, question in
                ChatQuestionRailMarker(
                  question: question,
                  number: index + 1,
                  total: questions.count,
                  isActive: question.id == activeQuestionID,
                  isHovered: question.id == hoveredQuestionID,
                  onHover: { hovering in
                    if hovering { hoveredQuestionID = question.id }
                    else if hoveredQuestionID == question.id { hoveredQuestionID = nil }
                  },
                  onSelect: { onSelect(question.id) })
                  .id(question.id)
              }
            }
            .padding(.vertical, 4)
          }
          .scrollIndicators(.hidden)
          .onChange(of: activeQuestionID) {
            if let activeQuestionID { railProxy.scrollTo(activeQuestionID, anchor: .center) }
          }
        }
      }
      // Size the whole track so both the scroll view and capsule stay compact.
      .frame(width: 36, height: min(CGFloat(questions.count * 24 + 8), 320))

      Button {
        onSelect(questions[min(activeIndex + 1, questions.count - 1)].id)
      } label: {
        Label("Next question", systemImage: "chevron.down")
          .labelStyle(.iconOnly)
          .frame(width: 36, height: 32)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .background(Color.primary.opacity(0.07), in: Circle())
      .disabled(activeIndex >= questions.count - 1)
      .help("Next question")
    }
    .padding(.horizontal, 5)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule(style: .continuous))
    .overlay {
      Capsule(style: .continuous)
        .stroke(Color.primary.opacity(0.10), lineWidth: 1)
    }
    .shadow(color: .black.opacity(0.10), radius: 8, y: 2)
    // Keep the preview outside the marker ScrollView so its bounds cannot clip it.
    .overlay(alignment: .trailing) {
      if let index = questions.firstIndex(where: { $0.id == hoveredQuestionID }) {
        HStack(spacing: 7) {
          Text("\(index + 1)").monospacedDigit().foregroundStyle(Color.accentColor)
          Text(questions[index].draft ?? questions[index].content)
            .lineLimit(2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .padding(10)
        .frame(width: 240)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.1)) }
        .offset(x: -46)
        .allowsHitTesting(false)
        .accessibilityLabel("Question preview")
      }
    }
    .zIndex(2)
    .accessibilityElement(children: .contain)
    .accessibilityLabel("Question navigation, question \(activeIndex + 1) of \(questions.count)")
  }
}

private struct ChatQuestionRailMarker: View {
  let question: ChatMessageRecord
  let number: Int
  let total: Int
  let isActive: Bool
  let isHovered: Bool
  let onHover: (Bool) -> Void
  let onSelect: () -> Void

  private var content: String { question.draft ?? question.content }

  var body: some View {
    Button(action: onSelect) {
      Capsule(style: .continuous)
        .fill(isActive || isHovered ? Color.accentColor : Color.secondary.opacity(0.52))
        .frame(width: isActive || isHovered ? 8 : 4, height: 6)
        .frame(width: 36, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover(perform: onHover)
    .accessibilityLabel("Question \(number) of \(total): \(content)")
    .accessibilityAddTraits(isActive ? .isSelected : [])
  }
}

private struct ChatLiveResponseRow: View {
  let state: ChatLiveAssistantState

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "sparkles")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
        .background(Color.accentColor)
        .clipShape(Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 8) {
        Text("Papertrail")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(state.response == nil ? "Thinking" : "Responding")
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
        }
        if let reasoning = state.reasoning, reasoning != "Thinking…" {
          Text(reasoning)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(4)
        }
        if let response = state.response {
          ChatMessageContentView(text: response)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Papertrail assistant, Thinking and responding")
  }
}

private struct ChatMessageRow: View {
  let message: ChatMessageRecord
  let questionNumber: Int?
  let questionCount: Int
  let isActiveQuestion: Bool
  let canRetry: Bool
  let onRetry: () -> Void

  private var isUser: Bool { message.role == "user" }

  var body: some View {
    Group {
      if isUser {
        userMessage
      } else {
        assistantMessage
      }
    }
    .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(accessibilityIdentity)
  }

  private var userMessage: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let questionNumber {
        Label("You · Question \(questionNumber)", systemImage: isActiveQuestion ? "bookmark.fill" : "bookmark")
          .font(.caption2.weight(isActiveQuestion ? .bold : .semibold))
          .foregroundStyle(isActiveQuestion ? Color.accentColor : Color.secondary)
      }
      ChatMessageContentView(text: message.draft ?? message.content)
      timestamp
      deliveryState
    }
    .padding(.horizontal, 14)
    .padding(.vertical, 10)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.accentColor.opacity(0.16))
    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(
          isActiveQuestion ? Color.accentColor : Color.clear,
          lineWidth: isActiveQuestion ? 2 : 0)
    }
    .shadow(color: Color.accentColor.opacity(isActiveQuestion ? 0.16 : 0), radius: 7, y: 2)
  }

  private var accessibilityIdentity: String {
    guard isUser, let questionNumber else { return "Papertrail assistant" }
    let active = isActiveQuestion ? ", current question" : ""
    return "You, question \(questionNumber) of \(questionCount)\(active)"
  }

  private var assistantMessage: some View {
    HStack(alignment: .top, spacing: 10) {
      Image(systemName: "sparkles")
        .font(.caption.weight(.semibold))
        .foregroundStyle(.white)
        .frame(width: 26, height: 26)
        .background(Color.accentColor)
        .clipShape(Circle())
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text("Papertrail")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        ChatMessageContentView(text: message.draft ?? message.content)
        timestamp
        deliveryState
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var timestamp: some View {
    Text(message.createdAt, format: .dateTime.year().month().day().hour().minute())
      .font(.caption2)
      .foregroundStyle(.secondary)
      .textSelection(.enabled)
      .help(message.createdAt.formatted(date: .complete, time: .complete))
  }

  @ViewBuilder private var deliveryState: some View {
    if message.deliveryState != "committed" {
      HStack(spacing: 8) {
        Text(message.deliveryState)
          .font(.caption2)
          .foregroundStyle(.secondary)
        if canRetry {
          Button("Retry") { onRetry() }
            .buttonStyle(.link)
            .font(.caption2)
        }
      }
    }
  }
}
