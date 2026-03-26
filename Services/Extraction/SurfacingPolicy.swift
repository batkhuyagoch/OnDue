import Foundation
import GRDB

// MARK: - SurfacingIntent

/// Where and how loudly an obligation is surfaced. This is distinct from
/// `ObligationLifecycleState`, which governs user-action lifecycle (done, snoozed, etc.).
/// `needsReview` is a lifecycle concern — there is no corresponding SurfacingIntent value.
enum SurfacingIntent: String, Codable, CaseIterable, DatabaseValueConvertible {
    case activeUpcoming  // Future deadline; primary surface; reminder-eligible.
    case activeOverdue   // Past deadline, still actionable per policy; distinct urgency.
    case referenceOnly   // Historical/audit; not primary list; no push notifications.
    case suppress        // Do not show as an obligation row.
}

// MARK: - SurfacingPolicy

enum SurfacingPolicy {
    /// Hypotheses for which a past-deadline item remains actionably overdue.
    /// Items not in this set with a stale deadline degrade to `referenceOnly`.
    static let overdueAllowlist: Set<ObligationHypothesis> = [
        .userActionRequired,
        .deadlineImplied,
        .legalOrCompliance,
        .legalComplianceResponse,
        .paymentFailure,
        .documentExpiration,
        .identityVerification,
        .appointmentActionRequired
    ]

    /// Determine where this obligation is placed in the surface hierarchy.
    ///
    /// - Parameters:
    ///   - deadlineAt: Trusted deadline from `SmartDeadlineExtractor`, if any.
    ///   - internalDate: Original message date (for future staleness heuristics).
    ///   - confidence: Contract-level confidence from `DecisionContract.confidence`.
    ///   - matchedHypotheses: Hypothesis set from `DecisionContract.matchedHypotheses`.
    ///   - now: Current date; injectable for testing.
    static func evaluate(
        deadlineAt: Date?,
        internalDate: Date,
        confidence: HypothesisConfidence,
        matchedHypotheses: Set<ObligationHypothesis>,
        now: Date = Date()
    ) -> SurfacingIntent {
        if let deadline = deadlineAt {
            guard deadline < now else {
                return .activeUpcoming
            }
            // Past deadline: only keep as actionably overdue if hypothesis is in the allowlist.
            if matchedHypotheses.contains(where: { overdueAllowlist.contains($0) }) {
                return .activeOverdue
            }
            return .referenceOnly
        }

        // No trusted deadline.
        switch confidence {
        case .high, .medium:
            return .referenceOnly
        case .low:
            return .suppress
        }
    }
}
