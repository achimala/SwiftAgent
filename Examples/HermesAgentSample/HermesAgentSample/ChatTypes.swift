import Foundation

struct ChatEntry: Identifiable, Equatable {
    enum Kind: String {
        case assistant
        case user
        case tool
        case status
        case error
        case debug
        case reasoning
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var body: String
    var isStreaming = false
    var toolCallID: String?
    var toolName: String?
    var toolInput: String?
    var toolOutput: String?
    var toolSucceeded: Bool?
}

struct ToolEvent: Decodable {
    let id: String?
    let name: String?
    let args: [String: JSONValue]?
    let ok: Bool?
    let resultPreview: String?
    let status: String?
    let preview: String?
    let duration: Double?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case args
        case ok
        case resultPreview = "result_preview"
        case status
        case preview
        case duration
        case isError = "is_error"
    }
}

struct TimingEvent: Decodable {
    let label: String
    let elapsedMs: Double
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case label
        case elapsedMs = "elapsed_ms"
        case detail
    }
}

struct HermesChatResult: Decodable {
    let finalResponse: String?
    let lastReasoning: String?
    let error: String?
    let reasoningTokens: Int?

    enum CodingKeys: String, CodingKey {
        case finalResponse = "final_response"
        case lastReasoning = "last_reasoning"
        case error
        case reasoningTokens = "reasoning_tokens"
    }
}

enum JSONValue: Decodable, Equatable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
        }
        return nil
    }

    var description: String {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            String(value)
        case .object(let value):
            value.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        case .array(let value):
            value.map(\.description).joined(separator: ", ")
        case .null:
            "null"
        }
    }
}
