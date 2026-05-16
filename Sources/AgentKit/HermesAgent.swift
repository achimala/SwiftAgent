import AgentKitCore
import Foundation
import Darwin

public struct HermesAgentConfiguration: Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var contextLength: Int?
    public var enableSoul: Bool
    public var enableContext: Bool
    public var enableMemory: Bool
    public var localMLXMaxTokens: Int?
    public var localMLXTemperature: Double?

    public init(
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String,
        model: String,
        contextLength: Int? = nil,
        enableSoul: Bool = true,
        enableContext: Bool = true,
        enableMemory: Bool = true,
        localMLXMaxTokens: Int? = nil,
        localMLXTemperature: Double? = nil
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.contextLength = contextLength
        self.enableSoul = enableSoul
        self.enableContext = enableContext
        self.enableMemory = enableMemory
        self.localMLXMaxTokens = localMLXMaxTokens
        self.localMLXTemperature = localMLXTemperature
    }

    public static func openAI(
        apiKey: String,
        model: String = "gpt-4.1-mini",
        baseURL: String = "https://api.openai.com/v1",
        contextLength: Int? = nil,
        enableSoul: Bool = true,
        enableContext: Bool = true,
        enableMemory: Bool = true
    ) -> HermesAgentConfiguration {
        HermesAgentConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            contextLength: contextLength,
            enableSoul: enableSoul,
            enableContext: enableContext,
            enableMemory: enableMemory
        )
    }

    var runtimeConfiguration: HermesChatConfiguration {
        HermesChatConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            contextLength: contextLength,
            enableSoul: enableSoul,
            enableContext: enableContext,
            enableMemory: enableMemory
        )
    }

    func applyRuntimeEnvironment() {
        guard baseURL == "hermes-local-mlx://chat" else { return }

        if let localMLXMaxTokens {
            setenv("HERMES_LOCAL_MLX_MAX_TOKENS", String(localMLXMaxTokens), 1)
        }
        if let localMLXTemperature {
            setenv("HERMES_LOCAL_MLX_TEMPERATURE", String(localMLXTemperature), 1)
        }
    }
}

public final class HermesAgent: @unchecked Sendable {
    public let sourceURL: URL
    public var configuration: HermesAgentConfiguration

    private let backend: any HermesAgentBackend

    public init(
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        backend: any HermesAgentBackend
    ) {
        self.configuration = configuration
        self.sourceURL = sourceURL
        self.backend = backend
    }

    public convenience init(
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        executionMode: HermesAgentExecutionMode,
        runtime: HermesAgentRuntime = HermesAgentRuntime(),
        shellEnvironment: (any AgentKitShellEnvironment)? = nil,
        modelProvider: (any AgentKitModelProvider)? = nil
    ) {
        switch executionMode {
        case .automatic, .inProcess:
            self.init(
                configuration: configuration,
                sourceURL: sourceURL,
                runtime: runtime,
                shellEnvironment: shellEnvironment,
                modelProvider: modelProvider
            )
        case .extensionProcess:
            self.init(
                configuration: configuration,
                sourceURL: sourceURL,
                backend: HermesExtensionProcessBackend()
            )
        }
    }

    public convenience init(
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        runtime: HermesAgentRuntime = HermesAgentRuntime(),
        shellEnvironment: (any AgentKitShellEnvironment)? = nil,
        modelProvider: (any AgentKitModelProvider)? = nil
    ) {
        self.init(
            configuration: configuration,
            sourceURL: sourceURL,
            backend: HermesInProcessBackend(
                runtime: runtime,
                shellEnvironment: shellEnvironment,
                modelProvider: modelProvider
            )
        )
    }

    public convenience init(
        configuration: HermesAgentConfiguration,
        bundle: Bundle = .main,
        bundledSourcePath: String = "PythonApp/hermes",
        executionMode: HermesAgentExecutionMode = .automatic,
        runtime: HermesAgentRuntime = HermesAgentRuntime(),
        shellEnvironment: (any AgentKitShellEnvironment)? = nil,
        modelProvider: (any AgentKitModelProvider)? = nil
    ) throws {
        try self.init(
            configuration: configuration,
            sourceURL: Self.bundledSourceURL(in: bundle, path: bundledSourcePath),
            executionMode: executionMode,
            runtime: runtime,
            shellEnvironment: shellEnvironment,
            modelProvider: modelProvider
        )
    }

    public static func bundledSourceURL(
        in bundle: Bundle = .main,
        path: String = "PythonApp/hermes"
    ) throws -> URL {
        guard let resourceURL = bundle.resourceURL else {
            throw HermesAgentError.python("Bundle resources are not available.")
        }

        let url = path
            .split(separator: "/")
            .reduce(resourceURL) { partial, component in
                partial.appendingPathComponent(String(component), isDirectory: true)
            }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw HermesAgentError.missingHermesSource(url)
        }
        return url
    }

    public static func defaultHome() throws -> URL {
        try HermesAgentRuntime.defaultHermesHome()
    }

    public static func defaultWorkspace() throws -> URL {
        try HermesAgentRuntime.defaultWorkspace()
    }

    public func prepare() throws -> String {
        try backend.prepare(sourceURL: sourceURL)
    }

    public func probe() throws -> HermesProbeResult {
        try backend.probe(sourceURL: sourceURL)
    }

    public func toolProbe() throws -> String {
        try backend.toolProbe(sourceURL: sourceURL)
    }

    public func send(
        _ message: String,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void = { _ in }
    ) throws -> String {
        try backend.send(
            message,
            configuration: configuration,
            sourceURL: sourceURL,
            onEvent: onEvent
        )
    }

    public func sessionState() throws -> HermesSessionState {
        try backend.sessionState(sourceURL: sourceURL)
    }

    public func loadSession(_ sessionID: String) throws -> HermesSessionState {
        try backend.loadSession(sessionID, sourceURL: sourceURL)
    }

    public func newSession() throws -> HermesSessionState {
        try backend.newSession(sourceURL: sourceURL)
    }
}
