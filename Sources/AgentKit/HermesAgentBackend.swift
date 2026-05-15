import AgentKitCore
import Foundation

public protocol HermesAgentBackend: Sendable {
    func prepare(sourceURL: URL) throws -> String
    func probe(sourceURL: URL) throws -> HermesProbeResult
    func toolProbe(sourceURL: URL) throws -> String
    func send(
        _ message: String,
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) throws -> String
    func sessionState(sourceURL: URL) throws -> HermesSessionState
    func loadSession(_ sessionID: String, sourceURL: URL) throws -> HermesSessionState
    func newSession(sourceURL: URL) throws -> HermesSessionState
}

public final class HermesInProcessBackend: HermesAgentBackend, @unchecked Sendable {
    private let runtime: HermesAgentRuntime

    public init(
        runtime: HermesAgentRuntime = HermesAgentRuntime(),
        shellEnvironment: (any AgentKitShellEnvironment)? = nil,
        modelProvider: (any AgentKitModelProvider)? = nil
    ) {
        self.runtime = runtime

        if let shellEnvironment {
            runtime.setShellEnvironment(shellEnvironment)
        }
        if let modelProvider {
            runtime.setModelProvider(modelProvider)
        }
    }

    public func prepare(sourceURL: URL) throws -> String {
        try runtime.prepareHermes(hermesSourcePath: sourceURL)
    }

    public func probe(sourceURL: URL) throws -> HermesProbeResult {
        try runtime.probe(hermesSourcePath: sourceURL)
    }

    public func toolProbe(sourceURL: URL) throws -> String {
        try runtime.toolProbe(hermesSourcePath: sourceURL)
    }

    public func send(
        _ message: String,
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) throws -> String {
        configuration.applyRuntimeEnvironment()
        return try runtime.chat(
            message: message,
            configuration: configuration.runtimeConfiguration,
            hermesSourcePath: sourceURL,
            onEvent: onEvent
        )
    }

    public func sessionState(sourceURL: URL) throws -> HermesSessionState {
        try runtime.sessionState(hermesSourcePath: sourceURL)
    }

    public func loadSession(_ sessionID: String, sourceURL: URL) throws -> HermesSessionState {
        try runtime.loadSession(sessionID, hermesSourcePath: sourceURL)
    }

    public func newSession(sourceURL: URL) throws -> HermesSessionState {
        try runtime.newSession(hermesSourcePath: sourceURL)
    }
}

public enum HermesAgentExecutionMode: Sendable {
    case automatic
    case inProcess
    case extensionProcess
}

public final class HermesExtensionProcessBackend: HermesAgentBackend, @unchecked Sendable {
    public init() {}

    public func prepare(sourceURL: URL) throws -> String {
        throw unavailable()
    }

    public func probe(sourceURL: URL) throws -> HermesProbeResult {
        throw unavailable()
    }

    public func toolProbe(sourceURL: URL) throws -> String {
        throw unavailable()
    }

    public func send(
        _ message: String,
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) throws -> String {
        throw unavailable()
    }

    public func sessionState(sourceURL: URL) throws -> HermesSessionState {
        throw unavailable()
    }

    public func loadSession(_ sessionID: String, sourceURL: URL) throws -> HermesSessionState {
        throw unavailable()
    }

    public func newSession(sourceURL: URL) throws -> HermesSessionState {
        throw unavailable()
    }

    private func unavailable() -> HermesAgentError {
        HermesAgentError.python(
            "The ExtensionFoundation/XPC Hermes backend is not implemented yet. Use .inProcess for the current POC."
        )
    }
}
