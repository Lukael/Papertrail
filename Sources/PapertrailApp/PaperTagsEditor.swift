import SwiftUI

struct PaperTagsEditor: View {
  let paper: PaperListItem
  let onSave: ([String]) throws -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var tags: [String]
  @State private var input = ""
  @State private var saveError: String?

  init(paper: PaperListItem, onSave: @escaping ([String]) throws -> Void) {
    self.paper = paper
    self.onSave = onSave
    _tags = State(initialValue: paper.tags)
  }

  private var candidate: String { input.trimmingCharacters(in: .whitespacesAndNewlines) }
  private var isDuplicate: Bool {
    tags.contains { $0.caseInsensitiveCompare(candidate) == .orderedSame }
  }
  private var canAdd: Bool {
    !candidate.isEmpty && candidate.count <= 64 && tags.count < 32 && !isDuplicate
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Paper tags").font(.headline)
      Text(paper.title).foregroundStyle(.secondary).lineLimit(2)
      HStack {
        TextField("New tag", text: $input)
          .onSubmit { if canAdd { addTag() } }
        Button("Add", action: addTag).disabled(!canAdd)
      }
      Text("Up to 32 tags, 64 characters each.")
        .font(.caption).foregroundStyle(.secondary)
      if tags.isEmpty {
        Text("No tags yet").foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 80)
      } else {
        ScrollView {
          VStack(spacing: 8) {
            ForEach(tags, id: \.self) { tag in
              HStack {
                Label(tag, systemImage: "tag").lineLimit(2)
                Spacer()
                Button {
                  tags.removeAll { $0 == tag }
                } label: { Image(systemName: "xmark.circle.fill") }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(tag)")
              }
              .padding(8)
              .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            }
          }
        }
        .frame(maxHeight: 240)
      }
      if let saveError {
        Text(saveError).font(.caption).foregroundStyle(.red)
      }
      HStack {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Save") {
          do {
            // Include a pending tag so Save never silently discards typed text.
            let pending = candidate.isEmpty || isDuplicate ? tags : tags + [candidate]
            try onSave(pending)
            dismiss()
          } catch { saveError = error.localizedDescription }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!candidate.isEmpty && !isDuplicate && !canAdd)
      }
    }
    .padding(20)
    .frame(width: 380)
  }

  private func addTag() {
    guard canAdd else { return }
    tags.append(candidate)
    input = ""
    saveError = nil
  }
}
