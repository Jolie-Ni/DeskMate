import Foundation
import GRDB

/// A label previously computed for a session, kept so a re-run does not pay
/// the labeling model again for work it already did. Session ids are a stable
/// hash of (start, bucket), so they survive re-clustering unchanged.
public struct StoredSessionLabel: Codable, FetchableRecord, PersistableRecord {
    public var sessionID: String
    public var label: String
    public var intent: String
    public var createdAt: Date

    public static let databaseTableName = "session_labels"

    public init(sessionID: String, label: String, intent: String, createdAt: Date = Date()) {
        self.sessionID = sessionID
        self.label = label
        self.intent = intent
        self.createdAt = createdAt
    }
}
