import Foundation

public struct SwiftAgentEvent: Sendable {
    public let kind: String
    public let payload: String

    public init(kind: String, payload: String) {
        self.kind = kind
        self.payload = payload
    }
}

public typealias HermesChatEvent = SwiftAgentEvent

public struct SwiftAgentShellCommand: Sendable {
    public var command: String
    public var cwd: URL?
    public var environment: [String: String]

    public init(command: String, cwd: URL? = nil, environment: [String: String] = [:]) {
        self.command = command
        self.cwd = cwd
        self.environment = environment
    }
}

public struct SwiftAgentShellResult: Sendable {
    public let command: String
    public let output: String
    public let status: Int32

    public init(command: String, output: String, status: Int32) {
        self.command = command
        self.output = output
        self.status = status
    }
}

public typealias HermesShellResult = SwiftAgentShellResult

public protocol SwiftAgentShellEnvironment: Sendable {
    func run(_ command: SwiftAgentShellCommand) throws -> SwiftAgentShellResult
}

public extension SwiftAgentShellEnvironment {
    func run(
        _ command: String,
        cwd: URL? = nil,
        environment: [String: String] = [:]
    ) throws -> SwiftAgentShellResult {
        try run(SwiftAgentShellCommand(command: command, cwd: cwd, environment: environment))
    }
}

public struct SwiftAgentModelRequest: Sendable {
    public let rawJSON: String

    public init(rawJSON: String) {
        self.rawJSON = rawJSON
    }
}

public protocol SwiftAgentModelProvider: Sendable {
    func complete(
        request: SwiftAgentModelRequest,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
    ) async throws -> String
}

public protocol SwiftAgentAgentImplementation: Sendable {
    associatedtype Configuration: Sendable

    func chat(
        message: String,
        configuration: Configuration,
        agentSourcePath: URL,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
    ) throws -> String
}

public final class SwiftAgentMockShellEnvironment: SwiftAgentShellEnvironment, @unchecked Sendable {
    public private(set) var commands: [SwiftAgentShellCommand] = []
    public var handler: @Sendable (SwiftAgentShellCommand) throws -> SwiftAgentShellResult
    private let lock = NSLock()

    public init(
        handler: @escaping @Sendable (SwiftAgentShellCommand) throws -> SwiftAgentShellResult = {
            SwiftAgentShellResult(command: $0.command, output: "", status: 0)
        }
    ) {
        self.handler = handler
    }

    public func run(_ command: SwiftAgentShellCommand) throws -> SwiftAgentShellResult {
        lock.lock()
        commands.append(command)
        lock.unlock()
        return try handler(command)
    }
}

public actor SwiftAgentMockModelProvider: SwiftAgentModelProvider {
    public private(set) var requests: [SwiftAgentModelRequest] = []
    public var handler: @Sendable (SwiftAgentModelRequest) async throws -> String

    public init(
        handler: @escaping @Sendable (SwiftAgentModelRequest) async throws -> String = { _ in
            #"{"final_response":"mock response","tool_calls":[],"last_reasoning":"","reasoning_tokens":0}"#
        }
    ) {
        self.handler = handler
    }

    public func complete(
        request: SwiftAgentModelRequest,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
    ) async throws -> String {
        requests.append(request)
        onEvent(SwiftAgentEvent(kind: "mock_model_request", payload: request.rawJSON))
        return try await handler(request)
    }
}
