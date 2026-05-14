import CHermesPython
import Foundation

public enum HermesAgentKitError: Error, CustomStringConvertible {
    case missingPythonHome(URL)
    case missingPythonResources
    case python(String)

    public var description: String {
        switch self {
        case .missingPythonHome(let url):
            "Python home was not found at \(url.path)"
        case .missingPythonResources:
            "HermesAgentKit Python resources were not found"
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

    public init(
        baseURL: String = "https://api.openai.com/v1",
        apiKey: String = "",
        model: String = "dummy-model"
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
    }
}

public struct HermesChatEvent: Sendable {
    public let kind: String
    public let payload: String
}

private final class HermesStreamCallbackBox {
    let callback: @Sendable (HermesChatEvent) -> Void

    init(callback: @escaping @Sendable (HermesChatEvent) -> Void) {
        self.callback = callback
    }
}

public final class HermesAgentRuntime: @unchecked Sendable {
    public static let shared = HermesAgentRuntime()

    private let lock = NSRecursiveLock()
    private var initialized = false

    public init() {}

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
            throw HermesAgentKitError.missingPythonHome(home)
        }

        guard let resources = Bundle.module.url(forResource: "Python", withExtension: nil) else {
            throw HermesAgentKitError.missingPythonResources
        }

        let appPython = Bundle.main.resourceURL!.appendingPathComponent("PythonApp")
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
            throw HermesAgentKitError.python(String(cString: error))
        }
        initialized = true
    }

    public func evaluate(_ expression: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        try ensureInitialized()
        var error = [CChar](repeating: 0, count: 32_768)
        guard let result = HermesPython_Evaluate(expression, &error, Int32(error.count)) else {
            throw HermesAgentKitError.python(String(cString: error))
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
            throw HermesAgentKitError.python(String(cString: error))
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

    public func prepareHermes(hermesSourcePath: URL) throws -> String {
        try initialize(extraPythonPaths: [hermesSourcePath])
        return try evaluate("__import__('agentkit_bootstrap').hermes_prepare(\(Self.pythonLiteral(hermesSourcePath.path)))")
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
            &error,
            Int32(error.count)
        ) else {
            throw HermesAgentKitError.python(String(cString: error))
        }
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    public func chat(
        message: String,
        configuration: HermesChatConfiguration,
        hermesSourcePath: URL,
        onEvent: @escaping @Sendable (HermesChatEvent) -> Void
    ) throws -> String {
        lock.lock()
        defer { lock.unlock() }

        _ = try prepareHermes(hermesSourcePath: hermesSourcePath)
        _ = try configureHermes(configuration)

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
                    HermesChatEvent(
                        kind: event.map(String.init(cString:)) ?? "",
                        payload: payload.map(String.init(cString:)) ?? ""
                    )
                )
            },
            opaqueBox,
            &error,
            Int32(error.count)
        ) else {
            throw HermesAgentKitError.python(String(cString: error))
        }
        defer { HermesPython_FreeCString(result) }
        return String(cString: result)
    }

    private func ensureInitialized() throws {
        if initialized || HermesPython_IsInitialized() != 0 {
            return
        }
        try initialize()
    }

    private static func pythonLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        return "'\(escaped)'"
    }
}
