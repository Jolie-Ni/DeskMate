import Foundation
import GRDB

public struct Capture: Codable, FetchableRecord, MutablePersistableRecord {
    public var id: Int64?
    public var ts: Date
    public var appName: String
    public var windowTitle: String?
    public var url: String?
    public var screenshotPath: String?
    public var ocrText: String?
    public var isRedacted: Bool

    public static let databaseTableName = "captures"

    public init(
        id: Int64? = nil,
        ts: Date,
        appName: String,
        windowTitle: String?,
        url: String?,
        screenshotPath: String?,
        ocrText: String?,
        isRedacted: Bool
    ) {
        self.id = id
        self.ts = ts
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
        self.screenshotPath = screenshotPath
        self.ocrText = ocrText
        self.isRedacted = isRedacted
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}
