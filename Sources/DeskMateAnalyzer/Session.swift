import Foundation
import DeskMateCore

/// A contiguous chunk of activity in one app/host. Built locally from raw
/// captures with no AI involved — the labeling pass adds semantic meaning later.
public struct Session: Identifiable, Codable {
    public let id: String  // stable hash of (start, bucket)
    public let startTs: Date
    public let endTs: Date
    public let appName: String
    public let urlHost: String?
    public let urlPaths: [String]      // distinct URL paths within this session (no query)
    public let titles: [String]        // distinct window titles
    public let ocrSnippet: String      // ~200 char redacted excerpt
    public let captureCount: Int
    public let captureIDs: [Int64]

    public var durationSeconds: TimeInterval { endTs.timeIntervalSince(startTs) }
    public var bucket: String { urlHost ?? appName }
}

public struct SessionClusterer {
    public var maxGapSeconds: TimeInterval
    public var maxOCRChars: Int

    public init(maxGapSeconds: TimeInterval = 300, maxOCRChars: Int = 200) {
        self.maxGapSeconds = maxGapSeconds
        self.maxOCRChars = maxOCRChars
    }

    public func cluster(_ captures: [Capture]) -> [Session] {
        let sorted = captures.sorted { $0.ts < $1.ts }
        var sessions: [Session] = []
        var working: WorkingSession?

        for c in sorted {
            let host = Self.extractHost(c.url)
            let bucket = host ?? c.appName

            if var current = working,
               current.bucket == bucket,
               c.ts.timeIntervalSince(current.endTs) <= maxGapSeconds {
                current.absorb(c, host: host)
                working = current
            } else {
                if let previous = working {
                    sessions.append(previous.finalize(maxOCRChars: maxOCRChars))
                }
                working = WorkingSession(seed: c, host: host)
            }
        }

        if let last = working {
            sessions.append(last.finalize(maxOCRChars: maxOCRChars))
        }
        return sessions
    }

    static func extractHost(_ raw: String?) -> String? {
        guard let raw = raw, var host = URL(string: raw)?.host?.lowercased() else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.isEmpty || host == "newtab" { return nil }
        return host
    }

    static func extractPath(_ raw: String?) -> String? {
        guard let raw = raw, let path = URL(string: raw)?.path, !path.isEmpty, path != "/"
        else { return nil }
        return path
    }
}

/// Mutable accumulator while clustering. Becomes a `Session` at finalize.
private struct WorkingSession {
    var startTs: Date
    var endTs: Date
    var appName: String
    var urlHost: String?
    var bucket: String { urlHost ?? appName }
    var paths: Set<String> = []
    var titles: Set<String> = []
    var ocrChunks: [String] = []
    var captureIDs: [Int64] = []

    init(seed: Capture, host: String?) {
        startTs = seed.ts
        endTs = seed.ts
        appName = seed.appName
        urlHost = host
        absorb(seed, host: host)
    }

    mutating func absorb(_ c: Capture, host: String?) {
        endTs = c.ts
        if let id = c.id { captureIDs.append(id) }
        if let title = c.windowTitle, !title.isEmpty { titles.insert(title) }
        if let path = SessionClusterer.extractPath(c.url) { paths.insert(path) }
        if let ocr = c.ocrText, !ocr.isEmpty { ocrChunks.append(ocr) }
    }

    func finalize(maxOCRChars: Int) -> Session {
        // Pull a representative OCR snippet: take from the earliest capture
        // (usually has the cleanest "you just landed on this page" text)
        // up to maxOCRChars, stripped of repeated whitespace.
        let raw = ocrChunks.first ?? ""
        let cleaned = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let snippet = cleaned.count > maxOCRChars
            ? String(cleaned.prefix(maxOCRChars)) + "…"
            : cleaned

        let id = "\(Int(startTs.timeIntervalSince1970))-\(bucket)"
        return Session(
            id: id,
            startTs: startTs,
            endTs: endTs,
            appName: appName,
            urlHost: urlHost,
            urlPaths: Array(paths).sorted().prefix(10).map { $0 },
            titles: Array(titles).sorted().prefix(10).map { $0 },
            ocrSnippet: snippet,
            captureCount: captureIDs.count,
            captureIDs: captureIDs
        )
    }
}
