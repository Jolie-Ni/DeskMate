import Foundation

public struct SessionLabel: Decodable {
    public let id: String
    public let label: String
    public let intent: String
}

private struct LabelBatchResponse: Decodable {
    let labels: [SessionLabel]
}

/// Sends sessions to Haiku 4.5 in batches and gets back a label + intent for
/// each. Cheap enough to re-run every analysis.
public struct LabelingService {
    public let client: AnthropicClient
    public var batchSize: Int

    public init(client: AnthropicClient, batchSize: Int = 12) {
        self.client = client
        self.batchSize = batchSize
    }

    public func label(
        _ sessions: [Session],
        progress: ((Int, Int) -> Void)? = nil
    ) async throws -> [String: SessionLabel] {
        var out: [String: SessionLabel] = [:]
        let batches = sessions.chunked(into: batchSize)

        for (idx, batch) in batches.enumerated() {
            progress?(idx + 1, batches.count)
            let labels = try await labelBatch(batch)
            for label in labels { out[label.id] = label }
        }
        return out
    }

    private func labelBatch(_ batch: [Session]) async throws -> [SessionLabel] {
        let userPayload = batch.map { sessionDigest($0) }
        let userJSON = (try? JSONEncoder().encode(userPayload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "[]"

        let request = MessagesRequest(
            model: "claude-haiku-4-5",
            maxTokens: 4096,
            system: [.init(text: Self.systemPrompt, cacheControl: .init())],
            messages: [.init(role: "user", content: userJSON)],
            outputConfig: .init(format: .init(schema: Self.schema))
        )
        return try await client.messagesParsed(request, as: LabelBatchResponse.self).labels
    }

    private func sessionDigest(_ s: Session) -> [String: String] {
        let durationMin = Int(s.durationSeconds / 60.0)
        return [
            "id": s.id,
            "app": s.appName,
            "host": s.urlHost ?? "",
            "paths": s.urlPaths.joined(separator: ", "),
            "titles": s.titles.joined(separator: " | "),
            "ocr": s.ocrSnippet,
            "duration_min": "\(durationMin)",
        ]
    }

    static let systemPrompt: String = """
    You label work sessions for a knowledge worker's productivity tool.

    Each session is a continuous chunk of time the user spent in one app or website.
    For each session, return:
    - label: 5-10 word specific description of what they were doing.
      "Researching Jane Doe on LinkedIn" beats "Browsing web".
      "Drafting Medium post on AI agents" beats "Writing".
    - intent: one of these categories:
        research, writing, coding, communication, planning,
        admin, learning, entertainment, other

    Be specific in labels. Use evidence from titles, URL paths, and OCR text.
    Return all labels in a single JSON object: { "labels": [...] }.
    """

    static let schema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "labels": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("object"),
                    "properties": .object([
                        "id":     .object(["type": .string("string")]),
                        "label":  .object(["type": .string("string")]),
                        "intent": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("research"), .string("writing"),
                                .string("coding"), .string("communication"),
                                .string("planning"), .string("admin"),
                                .string("learning"), .string("entertainment"),
                                .string("other"),
                            ]),
                        ]),
                    ]),
                    "required": .array([.string("id"), .string("label"), .string("intent")]),
                    "additionalProperties": .bool(false),
                ]),
            ]),
        ]),
        "required": .array([.string("labels")]),
        "additionalProperties": .bool(false),
    ])
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
