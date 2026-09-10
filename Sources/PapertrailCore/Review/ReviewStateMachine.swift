import Foundation

public enum ReviewStateTransitionError: Error, Equatable {
  case invalidProcess(from: ProcessOutcome, to: ProcessOutcome)
  case invalidStructure(from: StructuralValidationState, to: StructuralValidationState)
  case invalidEvidence(from: EvidenceReportState, to: EvidenceReportState)
  case invalidQuality(from: QualityVerificationState, to: QualityVerificationState)
  case invalidPromotion(from: ReviewPromotionPhase, to: ReviewPromotionPhase)
}

public enum ReviewStateMachine {
  public static func validate(process from: ProcessOutcome, to: ProcessOutcome) throws {
    let allowed: Set<ProcessOutcome>
    switch from {
    case .pending: allowed = [.running, .failed, .cancelled, .interrupted, .protocolFailure]
    case .running: allowed = [.turnCompleted, .failed, .cancelled, .interrupted, .protocolFailure]
    case .turnCompleted: allowed = [.cancelled, .protocolFailure]
    case .failed, .cancelled, .interrupted, .protocolFailure: allowed = []
    }
    guard allowed.contains(to) else { throw ReviewStateTransitionError.invalidProcess(from: from, to: to) }
  }

  public static func validate(
    structure from: StructuralValidationState, to: StructuralValidationState
  ) throws {
    let valid = (from == .notRun && to == .running)
      || (from == .running && (to == .passed || to == .failed))
    guard valid else { throw ReviewStateTransitionError.invalidStructure(from: from, to: to) }
  }

  public static func validate(evidence from: EvidenceReportState, to: EvidenceReportState) throws {
    guard from == .missing && (to == .produced || to == .invalid) else {
      throw ReviewStateTransitionError.invalidEvidence(from: from, to: to)
    }
  }

  public static func validate(
    quality from: QualityVerificationState, to: QualityVerificationState
  ) throws {
    let valid = (from == .notPerformed && to == .inProgress)
      || (from == .inProgress && (to == .verified || to == .failed))
      || (from == .failed && to == .inProgress)
    guard valid else { throw ReviewStateTransitionError.invalidQuality(from: from, to: to) }
  }

  public static func validate(promotion from: ReviewPromotionPhase, to: ReviewPromotionPhase) throws {
    let valid = (from == .none && to == .intentRecorded)
      || (from == .intentRecorded && (to == .filesMoved || to == .quarantined))
      || (from == .filesMoved && (to == .committed || to == .quarantined))
      || (from == .committed && (to == .selected || to == .recoveryRequired))
    guard valid else { throw ReviewStateTransitionError.invalidPromotion(from: from, to: to) }
  }
}
