# Design

## Source of truth

- Status: Active
- Last refreshed: 2026-09-10
- Primary product surfaces: paper library, resizable two-pane paper workspace, review, persistent chat, global activity log.
- Evidence reviewed: `Sources/PapertrailApp/PaperWorkspaceViews.swift`, `Sources/PapertrailApp/PaperLibraryController.swift`, `Sources/PapertrailApp/RestrictedReviewWebView.swift`, `Sources/PapertrailCore/Review/ReviewConversationSnapshot.swift`, `Sources/PapertrailCore/Review/ReviewHTMLRenderer.swift`.

## Brand

- Personality: focused, native macOS research workspace.
- Trust signals: toolbar-accessible storage/security disclosure, recoverable failure states, destructive-action confirmation.
- Avoid: web-dashboard styling and opaque background automation.

## Product goals

- Goals: import and organize local papers; chat about each paper; generate an immutable synthesis of the paper and the completed conversation on demand; switch between source PDF, generated document, and paper-scoped chat; keep operational details available through the global log without crowding the document reader.
- Non-goals: remote library sync or browser-like review navigation.
- Success signals: importing or reopening a paper never starts generation; a user can chat first, deliberately generate a document from the paper and completed conversation so far, select a generated version, and delete a paper from one predictable workspace.

## Personas and jobs

- Primary personas: researchers reading and reviewing locally stored academic papers.
- User jobs: inspect the source, develop interpretations through paper-scoped chat, capture the discussion so far as a sourced document, compare generated versions, and retain durable local history.
- Key contexts of use: resizable macOS windows where source reading/review and paper-scoped chat remain available side by side.

## Information architecture

- Primary navigation: native `NavigationSplitView` paper sidebar with a title search field and a persisted Name / Upload date / Recent chat picker. Upload and recent chat sort newest first; recent chat uses user message activity.
- Core screens: import confirmation; paper workspace with independent Paper and Review visibility toggles plus persistent right Chat; sidebar rename dialog; destructive delete confirmation.
- Content hierarchy: global toolbar controls and on-demand app information, resizable source area that shows Paper, Review, or both, persistent paper chat pane, persistent one-line activity log with expandable history.

## Design principles

- Keep primary actions visible and avoid duplicate navigation controls.
- Make generation explicitly user initiated. Import, selection, app launch, and interrupted legacy auto-generation records must never start or resume document generation.
- Treat each Generate action as a fixed snapshot: include the paper text and completed paper-scoped user/assistant messages committed before the click; exclude drafts, in-flight replies, failures, and messages created afterward. A later Generate action may include later completed messages.
- Keep review generation isolated from paper chat: each generation starts a new review thread and receives the fixed paper/conversation snapshot as input, while chat resumes its current paper-scoped thread.
- Allow paper-only generation when no completed chat exists.
- In generated documents, visually and semantically distinguish claims supported by verified paper evidence from discussion questions, interpretations, hypotheses, and open questions; each discussion item retains links to its source message IDs.
- Treat structured JSON as a validated generation boundary and let the app render the accepted data into local static HTML; users interact with the rendered document rather than raw JSON.
- Keep Chat visible while the user shows Paper, Review, or both in the source area; when both are visible, their nested split divider and the main chat divider are the primary width controls.
- Let Review content occupy the full available pane height in Paper-only, Review-only, and split modes; the WebView grows and scrolls inside that area instead of collapsing below the toolbar.
- Separate authored questions from generated answers by alignment, shape, and identity—not color alone.
- Show each user and assistant message's persisted date and time in the transcript so a reopened conversation preserves its chronology.
- Treat every authored question as a stable conversation anchor: emphasize the currently viewed question and provide direct previous/next/marker navigation from a compact trailing-edge rail without leaving the transcript.
- Keep the active chat composer above every persistent bottom bar and safe-area inset.
- Keep the chat composer action-focused: do not repeat paper-context or Codex lifecycle status prose beside the input; route operational status to the global activity log.
- Keep diagnostics global: Review content stays focused and does not repeat process, structure, evidence, or progress text; the bottom log combines app and Codex lifecycle events. Only actionable load failures remain attached to the review.
- Keep secondary disclosures out of the workspace header; place storage and security information beside the model selector in the global toolbar.
- Keep the selected model and reasoning effort fully readable in the toolbar; do not replace or truncate the current selection with an icon or ellipsis when space is available.
- Tradeoffs: prefer native SwiftUI behavior and readable adaptive layouts over pixel-specific web UI imitation.

## Visual language

- Color: system semantic colors only.
- Typography: SwiftUI native hierarchy, captions for diagnostics and status.
- Spacing/layout rhythm: 8-14 point groups; default 1280x820 workspace.
- Shape/radius/elevation: native controls and grouped surfaces.
- Motion: system-default transitions; no ornamental motion.
- Imagery/iconography: SF Symbols inside the product, with the assistant represented by a compact sparkles avatar. The app icon uses a dark midnight rounded square, warm paper stack, and restrained teal evidence trail to remain recognizable at small macOS icon sizes.

## Components

- Existing components to reuse: `PaperLibraryView`, `PaperWorkspaceView`, and `PDFDocumentView` from the reference implementation.
- New/changed components: `ChatMessageRow` separates chat roles, marks question anchors, and shows persisted timestamps; `ChatQuestionRail` exposes translucent trailing-edge transcript navigation with hover previews; `ActivityLogBar` shows diagnostics; `PaperWorkspaceView` owns the resizable source/chat split and full-height review reader; the sidebar context menu owns rename, supplementary-PDF, and delete actions; the toolbar information panel contains storage and authority disclosures.
- Tag editing: each sidebar row shows tags below its title and an accessible tag button. A native sheet supports staged add/remove, pending-input Save, Cancel, and inline persistence errors; the context menu exposes the same editor. Title search preserves the selected sort and has a clear action and no-results state.
- Variants and states: committed, draft, failed/retry, generating/cancel, loading conversation, empty conversation. Long conversations initially show the latest 40 messages; Load earlier messages reveals another 40 while preserving the reading anchor. Selecting an older question reveals its history before navigation. The question rail is 46pt wide including padding; its entire marker track (background and scroll view together) uses content height capped at 320pt so it cannot expand over the transcript.
- Token/component ownership: system semantic colors, materials, typography, and SF Symbols remain owned by SwiftUI.

## Accessibility

- Target standard: macOS native accessibility defaults.
- Keyboard/focus behavior: native list, menu, picker, and text field behavior.
- Contrast/readability: semantic foreground/background colors.
- Screen-reader semantics: each message exposes an explicit You or Papertrail assistant identity; user messages additionally expose their question position and every rail marker announces its question number and content.
- Reduced motion and sensory considerations: message identity does not depend on animation or color alone.

## Responsive behavior

- Supported breakpoints/devices: macOS 14+ with a resizable native split workspace.
- Layout adaptations: Paper and Review visibility toggles never permit an empty source area. When both are enabled, they share the source area through a nested resizable split; the source area and Chat preserve minimum readable widths.
- Touch/hover differences: the trailing question rail stays compact at rest and reveals a one-line, tail-truncated question preview to its left on pointer hover.

## Interaction states

- Loading: after the user chooses Generate document, progress and cancel actions remain visible in Review while detailed progress streams to the global log.
- Empty: native `ContentUnavailableView` introduces paper chat.
- Error: delivery state and retry action remain attached to the affected message.
- Success: committed messages omit transient delivery metadata.
- Rename: right-clicking a paper opens a prefilled rename dialog; Save remains disabled for a blank or invalid display title.
- Transcript follows new assistant output only while near the bottom; scrolling up or choosing a question preserves the reading position. Sending a new message returns to the bottom.
- Transcript navigation: scrolling updates the active question anchor; previous, next, and trailing-rail marker selection move focus to a question and visibly emphasize it.
- Destructive success: paper deletion is reported complete only after its app-owned directory is absent.
- Disabled: send is disabled for empty input or unavailable chat; Generate document is disabled while a generation is running.
- Offline/slow network: the running state keeps the composer visible and exposes cancel.

## Content voice

- Tone: concise, factual, research-oriented.
- Terminology: use “You” and “Papertrail” for chat identities; reserve “Codex” for process/security disclosures.
- Microcopy rules: label the first Review action “Generate document” and later actions “Regenerate document”; explain that generation captures the paper plus completed conversation through the click time. Explain persistence and paper context only where it aids onboarding; omit repeated context and Codex lifecycle labels from the active composer.

## Implementation constraints

- Framework/styling system: SwiftUI, PDFKit, WebKit, and SwiftData for the app; portable JSON storage is limited to command-line test targets.
- Compatibility constraints: macOS 14+.
- Test/screenshot expectations: reference Gate targets must build; UI must retain its draggable two-pane source/chat workspace and local-only review renderer.
- Performance constraints: use lazy message layout and avoid per-message process or storage work in view rendering.
- Design-token constraints: do not introduce a parallel color or typography token system.

## Chat mathematics

- Render inline and display LaTeX in both user and assistant chat messages, using the existing message typography and appearance.
- Preserve code spans, unfinished input, and stored message source. Unsupported expressions remain readable rather than disappearing.
- Vertical scrolling belongs to the transcript, including diagonal gestures over math. Individual messages must not scroll vertically.
- Keep dates, selection, and source copy available; resize math messages with the chat column and allow horizontal scrolling for long display equations.
- Use bundled local KaTeX to produce static MathML; no remote fonts, CDN requests, or page scripts.

## Chat tables

- Render Markdown pipe tables in user and assistant messages, including messages without math, with header cells, row borders, and column alignment.
- Preserve LaTeX within cells and retain the original source for copying. Code-fenced examples remain literal text.
- Wide tables scroll horizontally inside the message; vertical scrolling remains owned by the transcript. Table rendering uses the existing local, script-free HTML view.

## Chat Markdown

- Format headings, paragraphs, emphasis, ordered/unordered lists, block quotes, inline/fenced code, separators, and links alongside tables and LaTeX.
- Preserve literal syntax inside code and the original message for copying. Plain messages keep the lightweight native text path.
- Open explicitly clicked web/email links with the system application; never load remote images or execute message HTML/scripts inside chat.

## Open questions

- [ ] Pixel-level comparison screenshot baseline for the current host.

## PDF appearance

- Show a Dark PDF toggle at the trailing edge of the source toolbar while the PDF pane is visible. Default off; persist the preference across papers and launches.
- Apply a display-only dark color transform to the native PDF view. Turning it off restores original colors without replacing the PDF document or changing page/zoom state.
- Use full-opacity difference blending: white becomes pure black, black becomes white. The current transform also inverts image colors.
- Disable PDF page border shadows in both light and dark mode.
- In dark mode, draw a thin white separator at each page's bottom edge, except the final page; keep it aligned during scrolling and zooming.
