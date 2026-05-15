import CHermesPython
import Darwin
import Foundation
import MLXLMCommon

public enum HermesAgentError: Error, CustomStringConvertible {
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
}

public struct HermesProbeResult: Sendable {
    public let python: String
    public let hermes: String
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

public struct HermesPersistedMessage: Decodable, Equatable, Sendable {
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

public struct HermesPersistedToolCall: Decodable, Equatable, Sendable {
    public let id: String?
    public let type: String?
    public let function: HermesPersistedToolFunction?
}

public struct HermesPersistedToolFunction: Decodable, Equatable, Sendable {
    public let name: String?
    public let arguments: String?
}

public struct HermesSessionDetail: Decodable, Equatable, Sendable {
    public let id: String
    public let title: String?
    public let messages: [HermesPersistedMessage]
}

public struct HermesSessionSummary: Decodable, Identifiable, Equatable, Sendable {
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

public struct HermesSessionState: Decodable, Sendable {
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

private final class HermesStreamCallbackBox {
    let callback: @Sendable (AgentKitEvent) -> Void

    init(callback: @escaping @Sendable (AgentKitEvent) -> Void) {
        self.callback = callback
    }
}

public final class HermesAgentRuntime: AgentKitAgentImplementation, @unchecked Sendable {
    public static let shared = HermesAgentRuntime()

    private let lock = NSRecursiveLock()
    private var initialized = false
    private var shellEnvironment: any AgentKitShellEnvironment = AgentKitISHShellEnvironment.shared
    private var modelProvider: any AgentKitModelProvider = AgentKitMLXModelProvider.shared

    public init() {}

    public func setShellEnvironment(_ environment: any AgentKitShellEnvironment) {
        lock.lock()
        defer { lock.unlock() }
        shellEnvironment = environment
    }

    public func setModelProvider(_ provider: any AgentKitModelProvider) {
        lock.lock()
        defer { lock.unlock() }
        modelProvider = provider
    }

    public func initialize(
        pythonHome: URL? = nil,
        extraPythonPaths: [URL] = []
    ) throws {
        lock.lock()
        defer { lock.unlock() }

        if initialized || HermesPython_IsInitialized() != 0 {
            initialized = true
            return
        }

        let home = pythonHome ?? Bundle.main.resourceURL!.appendingPathComponent("python")
        guard FileManager.default.fileExists(atPath: home.path) else {
            throw HermesAgentError.missingPythonHome(home)
        }

        guard let resources = Bundle.module.url(forResource: "Python", withExtension: nil) else {
            throw HermesAgentError.missingPythonResources
        }

        try configurePersistentEnvironment()
        let appPython = Bundle.main.resourceURL!.appendingPathComponent("PythonApp")
        configureCertificateEnvironment(appPython: appPython)
        let candidatePaths = [
            home.appendingPathComponent("lib/python3.14"),
            home.appendingPathComponent("lib/python3.14/lib-dynload"),
            resources,
            resources.appendingPathComponent("site-packages"),
            appPython,
            appPython.appendingPathComponent("site-packages"),
        ] + extraPythonPaths
        let paths = candidatePaths.filter { FileManager.default.fileExists(atPath: $0.path) }

        var error = [CChar](repeating: 0, count: 16_384)
        let status = HermesPython_Initialize(home.path, paths.map(\.path).joined(separator: ":"), &error, Int32(error.count))
        guard status == 0 else {
            throw HermesAgentError.python(String(cString: error))
        }
        HermesPython_RegisterShellCallback(Self.shellCallback, nil)
        HermesPython_RegisterLocalLLMCallback(Self.localLLMCallback, nil)
        initialized = true
    }

    public static func defaultHermesHome() throws -> URL {
        try AgentKitPaths.defaultAgentHome()
    }

    public static func defaultWorkspace() throws -> URL {
        try AgentKitPaths.defaultShellWorkspace()
    }

    private func configurePersistentEnvironment() throws {
        let hermesHome = try Self.defaultHermesHome()
        let workspace = try Self.defaultWorkspace()
        try FileManager.default.createDirectory(at: hermesHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        setenv("HERMES_HOME", hermesHome.path, 1)
        setenv("HERMES_IOS_WORKSPACE", workspace.path, 1)
        setenv("TERMINAL_CWD", workspace.path, 1)
        setenv("HERMES_SESSION_SOURCE", "ios", 1)
    }

    private func configureCertificateEnvironment(appPython: URL) {
        let candidates = [
            appPython.appendingPathComponent("site-packages/certifi/cacert.pem"),
        ]
        guard let certPath = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            return
        }

        setenv("SSL_CERT_FILE", certPath.path, 1)
        setenv("REQUESTS_CA_BUNDLE", certPath.path, 1)
    }

    public func evaluate(_ expression: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try ensureInitialized()
        var error = [CChar](repeating: 0, count: 32_768)
        guard let result = HermesPython_Evaluate(expression, &error, Int32(error.count)) else {
            throw HermesAgentError.python(String(cString: error))
        }
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    public func runScript(_ script: String) throws {
        lock.lock()
        defer { lock.unlock() }

        try ensureInitialized()
        var error = [CChar](repeating: 0, count: 32_768)
        guard let result = HermesPython_RunScript(script, &error, Int32(error.count)) else {
            throw HermesAgentError.python(String(cString: error))
        }
        HermesPython_FreeCString(result)
    }

    public func probe(hermesSourcePath: URL? = nil) throws -> HermesProbeResult {
        try initialize(extraPythonPaths: hermesSourcePath.map { [$0] } ?? [])

        let python = try evaluate("__import__('agentkit_bootstrap').python_probe()")
        let hermesExpression: String
        if let hermesSourcePath {
            hermesExpression = "__import__('agentkit_bootstrap').hermes_probe(\(Self.pythonLiteral(hermesSourcePath.path)))"
        } else {
            hermesExpression = "__import__('agentkit_bootstrap').hermes_probe(None)"
        }
        let hermes = try evaluate(hermesExpression)
        return HermesProbeResult(python: python, hermes: hermes)
    }

    public func toolProbe(hermesSourcePath: URL? = nil) throws -> String {
        try initialize(extraPythonPaths: hermesSourcePath.map { [$0] } ?? [])

        if let hermesSourcePath {
            return try evaluate("__import__('agentkit_bootstrap').hermes_tool_probe(\(Self.pythonLiteral(hermesSourcePath.path)))")
        }
        return try evaluate("__import__('agentkit_bootstrap').hermes_tool_probe(None)")
    }

    public func prepareHermes(hermesSourcePath: URL) throws -> String {
        try initialize(extraPythonPaths: [hermesSourcePath])
        return try evaluate("__import__('agentkit_bootstrap').hermes_prepare(\(Self.pythonLiteral(hermesSourcePath.path)))")
    }

    public func sessionState(hermesSourcePath: URL) throws -> HermesSessionState {
        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        return try decodeSessionState(
            try evaluate("__import__('agentkit_bootstrap').hermes_session_state()")
        )
    }

    public func loadSession(_ sessionID: String, hermesSourcePath: URL) throws -> HermesSessionState {
        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        let raw = try evaluate("__import__('agentkit_bootstrap').hermes_load_session(\(Self.pythonLiteral(sessionID)))")
        return try decodeSessionState(raw)
    }

    public func newSession(hermesSourcePath: URL) throws -> HermesSessionState {
        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        let raw = try evaluate("__import__('agentkit_bootstrap').hermes_new_session()")
        return try decodeSessionState(raw)
    }

    private func decodeSessionState(_ raw: String) throws -> HermesSessionState {
        let data = Data(raw.utf8)
        let state = try JSONDecoder().decode(HermesSessionState.self, from: data)
        if !state.ok {
            throw HermesAgentError.python(state.traceback ?? raw)
        }
        return state
    }

    public func configureHermes(_ configuration: HermesChatConfiguration) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try ensureInitialized()
        var error = [CChar](repeating: 0, count: 32_768)
        guard let result = HermesPython_ConfigureHermes(
            configuration.baseURL,
            configuration.apiKey,
            configuration.model,
            configuration.enableSoul ? 1 : 0,
            configuration.enableContext ? 1 : 0,
            configuration.enableMemory ? 1 : 0,
            &error,
            Int32(error.count)
        ) else {
            throw HermesAgentError.python(String(cString: error))
        }
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    public func chat(
        message: String,
        configuration: HermesChatConfiguration,
        hermesSourcePath: URL,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        let start = Date()
        func emitTiming(_ label: String, detail: String? = nil) {
            onEvent(
                AgentKitEvent(
                    kind: "timing",
                    payload: Self.timingPayload(label: label, start: start, detail: detail)
                )
            )
        }

        emitTiming("swift_chat_start", detail: configuration.model)
        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        emitTiming("swift_prepare_done")
        _ = try configureHermes(configuration)
        emitTiming("swift_configure_done")

        let box = HermesStreamCallbackBox(callback: onEvent)
        let opaqueBox = Unmanaged.passRetained(box).toOpaque()
        defer {
            Unmanaged<HermesStreamCallbackBox>.fromOpaque(opaqueBox).release()
        }

        var error = [CChar](repeating: 0, count: 131_072)
        guard let result = HermesPython_Chat(
            message,
            { event, payload, context in
                guard let context else { return }
                let box = Unmanaged<HermesStreamCallbackBox>.fromOpaque(context).takeUnretainedValue()
                box.callback(
                    AgentKitEvent(
                        kind: event.map(String.init(cString:)) ?? "",
                        payload: payload.map(String.init(cString:)) ?? ""
                    )
                )
            },
            opaqueBox,
            &error,
            Int32(error.count)
        ) else {
            throw HermesAgentError.python(String(cString: error))
        }
        emitTiming("swift_python_chat_returned")
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    public func chat(
        message: String,
        configuration: HermesChatConfiguration,
        agentSourcePath: URL,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) throws -> String {
        try chat(
            message: message,
            configuration: configuration,
            hermesSourcePath: agentSourcePath,
            onEvent: onEvent
        )
    }

    private static func timingPayload(label: String, start: Date, detail: String? = nil) -> String {
        var payload: [String: Any] = [
            "label": label,
            "elapsed_ms": Date().timeIntervalSince(start) * 1000,
        ]
        if let detail, !detail.isEmpty {
            payload["detail"] = detail
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{\"label\":\"\(label)\",\"elapsed_ms\":0}"
        }
        return text
    }

    private func ensureInitialized() throws {
        if initialized || HermesPython_IsInitialized() != 0 {
            return
        }
        try initialize()
    }

    private func currentShellEnvironment() -> any AgentKitShellEnvironment {
        lock.lock()
        defer { lock.unlock() }
        return shellEnvironment
    }

    private func currentModelProvider() -> any AgentKitModelProvider {
        lock.lock()
        defer { lock.unlock() }
        return modelProvider
    }

    private static func pythonLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private static let shellCallback: HermesPython_ShellCallback = { command, cwd, timeout, status, _ in
        let commandText = command.map(String.init(cString:)) ?? ""
        let cwdURL = cwd
            .map(String.init(cString:))
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        do {
            let result = try HermesAgentRuntime.shared.currentShellEnvironment().run(
                commandText,
                cwd: cwdURL,
                environment: [
                    "AGENTKIT_SHELL_TIMEOUT": String(timeout),
                    "HERMES_SHELL_TIMEOUT": String(timeout),
                ]
            )
            status?.pointee = result.status
            return strdup(result.output)
        } catch {
            status?.pointee = -1
            return strdup(String(describing: error))
        }
    }

    private static let localLLMCallback: HermesPython_LocalLLMCallback = { requestJSON, _ in
        let requestText = requestJSON.map(String.init(cString:)) ?? "{}"
        let provider = HermesAgentRuntime.shared.currentModelProvider()
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var value: String?
        }
        let result = Box()

        Task.detached {
            do {
                result.value = try await provider.complete(
                    request: AgentKitModelRequest(rawJSON: requestText),
                    onEvent: { _ in }
                )
            } catch {
                result.value = HermesAgentRuntime.localLLMError(String(describing: error))
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 300) == .timedOut {
            return strdup(HermesAgentRuntime.localLLMError("Local model request timed out."))
        }
        return strdup(result.value ?? HermesAgentRuntime.localLLMError("Local model request returned no result."))
    }

    private static func localLLMError(_ message: String) -> String {
        let payload = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{\"error\":\"Local MLX request failed.\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
