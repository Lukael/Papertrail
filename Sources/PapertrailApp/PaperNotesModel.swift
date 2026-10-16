import Foundation
import PapertrailCore

/// One paper's highlights and saved chat answers. Each change is written before it is shown.
@MainActor
final class PaperNotesModel: ObservableObject {
  @Published private(set) var notes: [PaperNote] = []
  private let paperID: UUID
  private let store: PaperNoteStore
  private let activityLog: AppActivityLog

  init(paperID: UUID, store: PaperNoteStore, activityLog: AppActivityLog) {
    self.paperID = paperID
    self.store = store
    self.activityLog = activityLog
    do {
      notes = try store.load(paperID: paperID)
    } catch {
      activityLog.append(level: .error, "Notes could not be loaded: \(error.localizedDescription)")
    }
  }

  func add(_ note: PaperNote) { change { $0.append(note) } }

  func setComment(_ comment: String, id: UUID) {
    change { notes in
      guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
      notes[index].comment = comment
    }
  }

  func remove(id: UUID) { change { $0.removeAll { $0.id == id } } }

  private func change(_ edit: (inout [PaperNote]) -> Void) {
    var next = notes
    edit(&next)
    do {
      try store.save(next, paperID: paperID)
      notes = next
    } catch {
      activityLog.append(level: .error, "Notes could not be saved: \(error.localizedDescription)")
    }
  }
}
