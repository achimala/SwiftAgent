import SwiftAgentCore
import CHermesPython
import Darwin
import Foundation

private final class HermesStreamCallbackBox {
    let callback: @Sendable (SwiftAgentEvent) -> Void

    init(callback: @escaping @Sendable (SwiftAgentEvent) -> Void) {
        self.callback = callback
    }
}

private actor UnavailableLocalModelProvider: SwiftAgentModelProvider {
    func complete(
        request: SwiftAgentModelRequest,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
    ) async throws -> String {
        HermesAgentRuntime.localLLMError(
            "No local model provider is installed. Add the SwiftAgentMLX product and pass SwiftAgentMLXModelProvider() to HermesAgent for offline MLX."
        )
    }
}

public final class HermesAgentRuntime: SwiftAgentAgentImplementation, @unchecked Sendable {
    private static let pythonLock = NSRecursiveLock()

    private let lock = NSRecursiveLock()
    private var initialized = false
    private var shellEnvironment: any SwiftAgentShellEnvironment = SwiftAgentISHShellEnvironment()
    private var modelProvider: any SwiftAgentModelProvider = UnavailableLocalModelProvider()
    private var activeEventCallback: (@Sendable (SwiftAgentEvent) -> Void)?

    public init() {}

    public func setShellEnvironment(_ environment: any SwiftAgentShellEnvironment) {
        lock.lock()
        defer { lock.unlock() }
        shellEnvironment = environment
    }

    public func setModelProvider(_ provider: any SwiftAgentModelProvider) {
        lock.lock()
        defer { lock.unlock() }
        modelProvider = provider
    }

    public func initialize(
        pythonHome: URL? = nil,
        extraPythonPaths: [URL] = []
    ) throws {
        Self.pythonLock.lock()
        defer { Self.pythonLock.unlock() }

        lock.lock()
        defer { lock.unlock() }

        if initialized || HermesPython_IsInitialized() != 0 {
            initialized = true
            registerCallbacks()
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
            throw HermesAgentError.python(Self.string(fromCStringBuffer: error))
        }
        registerCallbacks()
        initialized = true
    }

    public static func defaultHermesHome() throws -> URL {
        try SwiftAgentPaths.defaultAgentHome()
    }

    public static func defaultWorkspace() throws -> URL {
        try SwiftAgentPaths.defaultShellWorkspace()
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
        setenv("PYTHONDONTWRITEBYTECODE", "1", 1)
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
        Self.pythonLock.lock()
        defer { Self.pythonLock.unlock() }

        lock.lock()
        defer { lock.unlock() }

        try ensureInitialized()
        var error = [CChar](repeating: 0, count: 32_768)
        guard let result = HermesPython_Evaluate(expression, &error, Int32(error.count)) else {
            throw HermesAgentError.python(Self.string(fromCStringBuffer: error))
        }
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    public func runScript(_ script: String) throws {
        Self.pythonLock.lock()
        defer { Self.pythonLock.unlock() }

        lock.lock()
        defer { lock.unlock() }

        try ensureInitialized()
        var error = [CChar](repeating: 0, count: 32_768)
        guard let result = HermesPython_RunScript(script, &error, Int32(error.count)) else {
            throw HermesAgentError.python(Self.string(fromCStringBuffer: error))
        }
        HermesPython_FreeCString(result)
    }

    public func probe(hermesSourcePath: URL? = nil) throws -> HermesProbeResult {
        try initialize(extraPythonPaths: hermesSourcePath.map { [$0] } ?? [])

        let python = try evaluate("__import__('swiftagent_bootstrap').python_probe()")
        let hermesExpression: String
        if let hermesSourcePath {
            hermesExpression = "__import__('swiftagent_bootstrap').hermes_probe(\(Self.pythonLiteral(hermesSourcePath.path)))"
        } else {
            hermesExpression = "__import__('swiftagent_bootstrap').hermes_probe(None)"
        }
        let hermes = try evaluate(hermesExpression)
        return HermesProbeResult(python: python, hermes: hermes)
    }

    public func toolProbe(hermesSourcePath: URL? = nil) throws -> String {
        try initialize(extraPythonPaths: hermesSourcePath.map { [$0] } ?? [])

        if let hermesSourcePath {
            return try evaluate("__import__('swiftagent_bootstrap').hermes_tool_probe(\(Self.pythonLiteral(hermesSourcePath.path)))")
        }
        return try evaluate("__import__('swiftagent_bootstrap').hermes_tool_probe(None)")
    }

    public func prepareHermes(hermesSourcePath: URL) throws -> String {
        try initialize(extraPythonPaths: [hermesSourcePath])
        return try evaluate("__import__('swiftagent_bootstrap').hermes_prepare(\(Self.pythonLiteral(hermesSourcePath.path)))")
    }

    public func sessionState(hermesSourcePath: URL) throws -> HermesSessionState {
        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        return try decodeSessionState(
            try evaluate("__import__('swiftagent_bootstrap').hermes_session_state()")
        )
    }

    public func loadSession(_ sessionID: String, hermesSourcePath: URL) throws -> HermesSessionState {
        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        let raw = try evaluate("__import__('swiftagent_bootstrap').hermes_load_session(\(Self.pythonLiteral(sessionID)))")
        return try decodeSessionState(raw)
    }

    public func newSession(hermesSourcePath: URL) throws -> HermesSessionState {
        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        let raw = try evaluate("__import__('swiftagent_bootstrap').hermes_new_session()")
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
        Self.pythonLock.lock()
        defer { Self.pythonLock.unlock() }

        lock.lock()
        defer { lock.unlock() }

        try ensureInitialized()
        var error = [CChar](repeating: 0, count: 32_768)
        guard let result = HermesPython_ConfigureHermes(
            configuration.baseURL,
            configuration.apiKey,
            configuration.model,
            Int32(configuration.contextLength ?? 0),
            configuration.enableSoul ? 1 : 0,
            configuration.enableContext ? 1 : 0,
            configuration.enableMemory ? 1 : 0,
            &error,
            Int32(error.count)
        ) else {
            throw HermesAgentError.python(Self.string(fromCStringBuffer: error))
        }
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    public func chat(
        message: String,
        configuration: HermesChatConfiguration,
        hermesSourcePath: URL,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
    ) throws -> String {
        Self.pythonLock.lock()
        defer { Self.pythonLock.unlock() }

        // Do not hold `lock` across HermesPython_Chat. Hermes may call the
        // native model provider from a Python worker thread during the turn.
        let start = Date()
        func emitTiming(_ label: String, detail: String? = nil) {
            onEvent(
                SwiftAgentEvent(
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
        setActiveEventCallback(onEvent)
        defer {
            setActiveEventCallback(nil)
            Unmanaged<HermesStreamCallbackBox>.fromOpaque(opaqueBox).release()
        }

        var error = [CChar](repeating: 0, count: 131_072)
        guard let result = HermesPython_Chat(
            message,
            { event, payload, context in
                guard let context else { return }
                let box = Unmanaged<HermesStreamCallbackBox>.fromOpaque(context).takeUnretainedValue()
                box.callback(
                    SwiftAgentEvent(
                        kind: event.map(String.init(cString:)) ?? "",
                        payload: payload.map(String.init(cString:)) ?? ""
                    )
                )
            },
            opaqueBox,
            &error,
            Int32(error.count)
        ) else {
            throw HermesAgentError.python(Self.string(fromCStringBuffer: error))
        }
        emitTiming("swift_python_chat_returned")
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    public func chat(
        message: String,
        configuration: HermesChatConfiguration,
        agentSourcePath: URL,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
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
            registerCallbacks()
            return
        }
        try initialize()
    }

    private func registerCallbacks() {
        let context = Unmanaged.passUnretained(self).toOpaque()
        HermesPython_RegisterShellCallback(Self.shellCallback, context)
        HermesPython_RegisterLocalLLMCallback(Self.localLLMCallback, context)
    }

    private func currentShellEnvironment() -> any SwiftAgentShellEnvironment {
        lock.lock()
        defer { lock.unlock() }
        return shellEnvironment
    }

    private func currentModelProvider() -> any SwiftAgentModelProvider {
        lock.lock()
        defer { lock.unlock() }
        return modelProvider
    }

    private func setActiveEventCallback(_ callback: (@Sendable (SwiftAgentEvent) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        activeEventCallback = callback
    }

    private func emitActiveEvent(_ event: SwiftAgentEvent) {
        lock.lock()
        let callback = activeEventCallback
        lock.unlock()
        callback?(event)
    }

    private static func pythonLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }

    private static func string(fromCStringBuffer buffer: [CChar]) -> String {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static let shellCallback: HermesPython_ShellCallback = { command, cwd, timeout, status, context in
        guard let context else {
            status?.pointee = -1
            return strdup("No SwiftAgent runtime is registered for shell execution.")
        }
        let runtime = Unmanaged<HermesAgentRuntime>.fromOpaque(context).takeUnretainedValue()
        let commandText = command.map(String.init(cString:)) ?? ""
        let cwdURL = cwd
            .map(String.init(cString:))
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }

        do {
            let result = try runtime.currentShellEnvironment().run(
                commandText,
                cwd: cwdURL,
                environment: [
                    "SWIFTAGENT_SHELL_TIMEOUT": String(timeout),
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

    private static let localLLMCallback: HermesPython_LocalLLMCallback = { requestJSON, context in
        guard let context else {
            return strdup(HermesAgentRuntime.localLLMError("No SwiftAgent runtime is registered for local model completion."))
        }
        let requestText = requestJSON.map(String.init(cString:)) ?? "{}"
        let runtime = Unmanaged<HermesAgentRuntime>.fromOpaque(context).takeUnretainedValue()
        let provider = runtime.currentModelProvider()
        let start = Date()
        runtime.emitActiveEvent(
            SwiftAgentEvent(kind: "timing", payload: HermesAgentRuntime.timingPayload(label: "local_llm_request_start", start: start))
        )
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var value: String?
        }
        let result = Box()

        Task.detached {
            do {
                result.value = try await provider.complete(
                    request: SwiftAgentModelRequest(rawJSON: requestText),
                    onEvent: { event in
                        runtime.emitActiveEvent(event)
                    }
                )
                runtime.emitActiveEvent(
                    SwiftAgentEvent(kind: "timing", payload: HermesAgentRuntime.timingPayload(label: "local_llm_request_done", start: start))
                )
            } catch {
                runtime.emitActiveEvent(
                    SwiftAgentEvent(kind: "timing", payload: HermesAgentRuntime.timingPayload(label: "local_llm_request_error", start: start, detail: String(describing: error)))
                )
                result.value = HermesAgentRuntime.localLLMError(String(describing: error))
            }
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + 300) == .timedOut {
            runtime.emitActiveEvent(
                SwiftAgentEvent(kind: "timing", payload: HermesAgentRuntime.timingPayload(label: "local_llm_request_timeout", start: start))
            )
            return strdup(HermesAgentRuntime.localLLMError("Local model request timed out."))
        }
        return strdup(result.value ?? HermesAgentRuntime.localLLMError("Local model request returned no result."))
    }

    fileprivate static func localLLMError(_ message: String) -> String {
        let payload = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{\"error\":\"Local MLX request failed.\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}
