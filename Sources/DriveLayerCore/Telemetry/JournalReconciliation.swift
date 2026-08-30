import Foundation

/// What to do with a telemetry journal found on disk.
///
/// A pure decision, deliberately separated from the code that enumerates directories and
/// deletes them. The first version of this lived inside `AppEnvironment` and could only be
/// tested by standing up a whole environment against the shared telemetry store — which
/// meant journals left behind by unrelated tests changed the answer. The policy is worth
/// far more scrutiny than the plumbing, so the policy is what is testable.
enum JournalReconciliation {

    enum Outcome: String, Equatable, Sendable {
        /// Leave it alone.
        case keep
        /// Nothing in the database refers to it and it is old enough to be sure.
        case discard
    }

    /// - Parameters:
    ///   - hasTripRow: whether a drive row with this id exists at all — decodable or not.
    ///     Not the same question as whether the drive can be *read*: a row whose payload
    ///     this build cannot decode still belongs to a drive a later build may recover,
    ///     and its telemetry has to outlive this one.
    ///   - lastWrite: when the journal was last written to, or nil if that cannot be
    ///     determined.
    ///   - grace: how recently a journal may have been written and still be left alone.
    ///     This is what stops reconciliation deleting a drive in progress: a journal being
    ///     written right now has no completed drive behind it either.
    static func outcome(hasTripRow: Bool,
                        lastWrite: Date?,
                        now: Date,
                        grace: TimeInterval) -> Outcome {
        if hasTripRow { return .keep }

        // Undateable means unjudgeable. Refusing to delete something whose age cannot be
        // established costs an empty directory; the alternative risks the opposite mistake,
        // and only one of the two is reversible.
        guard let lastWrite else { return .keep }

        // Where the boundary has to fall one way, it falls towards not deleting data.
        return now.timeIntervalSince(lastWrite) <= grace ? .keep : .discard
    }
}
