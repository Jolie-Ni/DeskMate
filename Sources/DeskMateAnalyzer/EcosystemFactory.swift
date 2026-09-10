import DeskMateCore
import Foundation

/// Decides which platform a run's *suggestions* target.
///
/// Same three sources as `ProviderFactory`, in the same order — environment,
/// `providers.json`, then a default — because someone reasoning about one of
/// these will reason about the other, and two precedence rules would be one
/// too many.
///
/// The default is the interesting part: it follows the provider rather than
/// being a constant. Most people use one company's model and one company's
/// products, so following is right almost always and silent when it is. The
/// override exists for the case where it is wrong, which is a team whose model
/// and whose tools come from different places.
public enum EcosystemFactory {

    /// The pack a run should use, plus a sentence about why, for logs and the
    /// fixture. The reason is not decoration: "following the provider" and
    /// "you asked for this" are different situations to be in when a plan
    /// recommends something surprising.
    public struct Resolution {
        public let ecosystem: Ecosystem
        public let reason: String
    }

    public static func resolve() -> Resolution {
        // A malformed file is `ProviderFactory`'s to complain about; it will
        // refuse to build a provider and the run stops before this matters.
        let config = (try? ProviderConfig.load()) ?? ProviderConfig()
        return resolve(config)
    }

    public static func resolve(_ config: ProviderConfig) -> Resolution {
        let providerID = ProviderFactory.selectedProviderID(config)

        if let raw = trimmed("DESKMATE_ECOSYSTEM") {
            if let pack = Ecosystem.builtIn(id: raw) {
                return Resolution(ecosystem: pack, reason: "DESKMATE_ECOSYSTEM=\(raw)")
            }
            // Named but unknown. Falling through to the default silently would
            // produce Claude suggestions for someone who asked for something
            // else and got no indication they had misspelled it.
            return Resolution(
                ecosystem: .neutral,
                reason: "DESKMATE_ECOSYSTEM=\(raw) names no known ecosystem "
                    + "(\(known)) — targeting no platform")
        }

        if let raw = config.ecosystem?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            if let pack = Ecosystem.builtIn(id: raw) {
                return Resolution(
                    ecosystem: pack,
                    reason: "\"ecosystem\": \"\(raw)\" in \(ProviderConfig.displayPath)")
            }
            return Resolution(
                ecosystem: .neutral,
                reason: "\"ecosystem\": \"\(raw)\" in \(ProviderConfig.displayPath) "
                    + "names no known ecosystem (\(known)) — targeting no platform")
        }

        let pack = Ecosystem.defaultFor(providerID: providerID)
        return Resolution(
            ecosystem: pack,
            reason: "following the \(providerID) provider")
    }

    static var known: String {
        Ecosystem.builtIn.map(\.id).joined(separator: ", ")
    }

    /// Empty reads as absent, for the same reason it does in `ProviderFactory`:
    /// `daily-summary.sh` exports its variables unconditionally, so an unset one
    /// arrives as "" rather than missing.
    private static func trimmed(_ key: String) -> String? {
        let raw = ProcessInfo.processInfo.environment[key]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (raw?.isEmpty ?? true) ? nil : raw
    }
}
