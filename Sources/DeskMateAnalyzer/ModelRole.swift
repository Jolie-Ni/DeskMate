import Foundation

/// What a model is being asked to do, rather than which model does it.
///
/// The three jobs in DeskMate want genuinely different things, and naming the
/// job rather than the model is what lets the answer change without touching
/// the code that asks the question:
///
///   - `labeling` runs once per unlabelled session, in batches, and wants cheap
///     and fast far more than it wants clever.
///   - `reasoning` runs a handful of times per analysis and carries the whole
///     product — pattern detection and automation planning. Depth is the point.
///   - `narration` reads ~45k characters of screen text and writes prose. Its
///     constraint is the context window, not the reasoning.
///
/// Lives in the analyzer rather than `DeskMateCore` on purpose: the daemon
/// depends on Core and must never acquire an LLM code path. Every binary that
/// does talk to a model already imports this target.
public enum ModelRole: String, CaseIterable, Sendable {
    case labeling
    case reasoning
    case narration

    /// `DESKMATE_MODEL_LABELING`, `…_REASONING`, `…_NARRATION`.
    public var environmentKey: String {
        "DESKMATE_MODEL_" + rawValue.uppercased()
    }

    /// What the environment says this role should use, if anything.
    ///
    /// A model name is the thing most likely to age out, and the nightly
    /// summary runs unattended — it has to be fixable without a rebuild. Empty
    /// is treated as unset: `daily-summary.sh` exports its variables
    /// unconditionally, so an unset value arrives as "" rather than absent, and
    /// taking that literally would send an empty model name.
    ///
    /// What it falls back to belongs to the provider, not here — see
    /// `LLMProvider.model(for:)`. A role is a job to be done; only the endpoint
    /// knows which of its models does that job.
    public var environmentOverride: String? {
        for key in environmentKeys {
            let value = ProcessInfo.processInfo.environment[key]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let value, !value.isEmpty { return value }
        }
        return nil
    }

    /// Every variable consulted for this role, in precedence order.
    ///
    /// `narration` keeps `DESKMATE_SUMMARY_MODEL` as a second name: it is
    /// documented in `docs/reference.md` and may well be sitting in someone's
    /// launchd plist, and silently ignoring it would take the nightly job back
    /// to a model the operator thought they had overridden.
    public var environmentKeys: [String] {
        switch self {
        case .narration: return [environmentKey, "DESKMATE_SUMMARY_MODEL"]
        default:         return [environmentKey]
        }
    }
}

/// One model per role, all three required.
///
/// A struct rather than a dictionary so a provider cannot be built with a role
/// missing — the failure that would otherwise surface as a 404 on the one call
/// that uses the role nobody filled in.
public struct RoleModels: Equatable {
    public var labeling: String
    public var reasoning: String
    public var narration: String

    public init(labeling: String, reasoning: String, narration: String) {
        self.labeling = labeling
        self.reasoning = reasoning
        self.narration = narration
    }

    public subscript(role: ModelRole) -> String {
        get {
            switch role {
            case .labeling:  return labeling
            case .reasoning: return reasoning
            case .narration: return narration
            }
        }
        set {
            switch role {
            case .labeling:  labeling = newValue
            case .reasoning: reasoning = newValue
            case .narration: narration = newValue
            }
        }
    }

    /// Applies only the roles present in `overrides`, leaving the rest alone.
    /// Config files name the one model someone wanted to change, not all three.
    public func applying(_ overrides: [ModelRole: String]) -> RoleModels {
        var out = self
        for (role, model) in overrides where !model.isEmpty {
            out[role] = model
        }
        return out
    }
}
