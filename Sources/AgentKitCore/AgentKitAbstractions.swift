import Foundation

public struct AgentKitEvent: Sendable {
    public let kind: String
    public let payload: String

    public init(kind: String, payload: String) {
        self.kind = kind
        self.payload = payload
    }
}

public typealias HermesChatEvent = AgentKitEvent

public struct AgentKitShellCommand: Sendable {
    public var command: String
    public var cwd: URL?
    public var environment: [String: String]

    public init(command: String, cwd: URL? = nil, environment: [String: String] = [:]) {
        self.command = command
        self.cwd = cwd
        self.environment = environment
    }
}

public struct AgentKitShellResult: Sendable {
    public let command: String
    public let output: String
    public let status: Int32

    public init(command: String, output: String, status: Int32) {
        self.command = command
        self.output = output
        self.status = status
    }
}

public typealias HermesShellResult = AgentKitShellResult

public protocol AgentKitShellEnvironment: Sendable {
    func run(_ command: AgentKitShellCommand) throws -> AgentKitShellResult
}

public extension AgentKitShellEnvironment {
    func run(
        _ command: String,
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> AgentKitShellResult {
        try run(AgentKitShellCommand(command: command, cwd: cwd, environment: environment))
    }
}

public struct AgentKitModelRequest: Sendable {
    public let rawJSON: String

    public init(rawJSON: String) {
        self.rawJSON = rawJSON
    }
}

public protocol AgentKitModelProvider: Sendable {
    func complete(
        request: AgentKitModelRequest,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) async throws -> String
}

public protocol AgentKitAgentImplementation: Sendable {
    associatedtype Configuration: Sendable

    func chat(
        message: String,
        configuration: Configuration,
        agentSourcePath: URL,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) throws -> String
}

public final class AgentKitMockShellEnvironment: AgentKitShellEnvironment, @unchecked Sendable {
    public private(set) var commands: [AgentKitShellCommand] = []
    public var handler: @Sendable (AgentKitShellCommand) throws -> AgentKitShellResult
    private let lock = NSLock()

    public init(
        handler: @escaping @Sendable (AgentKitShellCommand) throws -> AgentKitShellResult = {
            AgentKitShellResult(command: $0.command, output: "", status: 0)
        }
    ) {
        self.handler = handler
    }

    public func run(_ command: AgentKitShellCommand) throws -> AgentKitShellResult {
        lock.lock()
        commands.append(command)
        lock.unlock()
        return try handler(command)
    }
}

public actor AgentKitMockModelProvider: AgentKitModelProvider {
    public private(set) var requests: [AgentKitModelRequest] = []
    public var handler: @Sendable (AgentKitModelRequest) async throws -> String

    public init(
        handler: @escaping @Sendable (AgentKitModelRequest) async throws -> String = { _ in
            #"{"final_response":"mock response","tool_calls":[],"last_reasoning":"","reasoning_tokens":0}"#
        }
    ) {
        self.handler = handler
    }

    public func complete(
        request: AgentKitModelRequest,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) async throws -> String {
        requests.append(request)
        onEvent(AgentKitEvent(kind: "mock_model_request", payload: request.rawJSON))
        return try await handler(request)
    }
}
