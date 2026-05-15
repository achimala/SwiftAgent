import Foundation

public enum HermesAgentError: Error, CustomStringConvertible, LocalizedError {
    case missingPythonHome(URL)
    case missingPythonResources
    case missingHermesSource(URL)
    case python(String)

    public var description: String {
        switch self {
        case .missingPythonHome(let url):
            "Python home was not found at \(url.path)"
        case .missingPythonResources:
            "AgentKit Python resources were not found"
        case .missingHermesSource(let url):
            "Bundled Hermes source was not found at \(url.path)"
        case .python(let message):
            message
        }
    }

    public var errorDescription: String? {
        description
    }
}

public struct HermesProbeResult: Sendable {
    public let python: String
    public let hermes: String

    public init(python: String, hermes: String) {
        self.python = python
        self.hermes = hermes
    }
}

public struct HermesChatConfiguration: Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var enableSoul: Bool
    public var enableContext: Bool
    public var enableMemory: Bool

    public init(
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String = "",
        model: String = "dummy-model",
        enableSoul: Bool = true,
        enableContext: Bool = true,
        enableMemory: Bool = true
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.enableSoul = enableSoul
        self.enableContext = enableContext
        self.enableMemory = enableMemory
    }
}

public struct HermesPersistedMessage: Codable, Equatable, Sendable {
    public let role: String
    public let content: String
    public let toolName: String?
    public let toolCallID: String?
    public let toolCalls: [HermesPersistedToolCall]?

    enum CodingKeys: String, CodingKey {
        case role
        case content
        case toolName = "tool_name"
        case toolCallID = "tool_call_id"
        case toolCalls = "tool_calls"
    }
}

public struct HermesPersistedToolCall: Codable, Equatable, Sendable {
    public let id: String?
    public let type: String?
    public let function: HermesPersistedToolFunction?
}

public struct HermesPersistedToolFunction: Codable, Equatable, Sendable {
    public let name: String?
    public let arguments: String?
}

public struct HermesSessionDetail: Codable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let messages: [HermesPersistedMessage]
}

public struct HermesSessionSummary: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let preview: String
    public let model: String
    public let startedAt: String?
    public let lastActive: String?
    public let messageCount: Int
    public let endedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case preview
        case model
        case startedAt = "started_at"
        case lastActive = "last_active"
        case messageCount = "message_count"
        case endedAt = "ended_at"
    }
}

public struct HermesSessionState: Codable, Sendable {
    public let ok: Bool
    public let currentSessionID: String?
    public let currentSession: HermesSessionDetail?
    public let sessions: [HermesSessionSummary]
    public let traceback: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case currentSessionID = "current_session_id"
        case currentSession = "current_session"
        case sessions
        case traceback
    }
}
