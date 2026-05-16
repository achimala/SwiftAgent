import SwiftAgentCore
#if os(iOS)
import ExtensionFoundation
#endif
import Foundation

public protocol HermesAgentBackend: Sendable {
    func prepare(sourceURL: URL) throws -> String
    func probe(sourceURL: URL) throws -> HermesProbeResult
    func toolProbe(sourceURL: URL) throws -> String
    func send(
        _ message: String,
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
    ) throws -> String
    func sessionState(sourceURL: URL) throws -> HermesSessionState
    func loadSession(_ sessionID: String, sourceURL: URL) throws -> HermesSessionState
    func newSession(sourceURL: URL) throws -> HermesSessionState
}

public final class HermesInProcessBackend: HermesAgentBackend, @unchecked Sendable {
    private let runtime: HermesAgentRuntime

    public init(
        runtime: HermesAgentRuntime = HermesAgentRuntime(),
        shellEnvironment: (any SwiftAgentShellEnvironment)? = nil,
        modelProvider: (any SwiftAgentModelProvider)? = nil
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
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
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
    private let lock = NSRecursiveLock()
    private let client: (any HermesExtensionXPCClient)?

    public init() {
        self.client = nil
    }

    #if os(iOS)
    @available(iOS 26.0, *)
    public init(appExtensionPoint: AppExtensionPoint) {
        self.client = ExtensionFoundationHermesXPCClient(appExtensionPoint: appExtensionPoint)
    }
    #endif

    public func prepare(sourceURL: URL) throws -> String {
        try perform { service in
            try callString { reply in
                service.prepare(sourcePath: sourceURL.path, withReply: reply)
            }
        }
    }

    public func probe(sourceURL: URL) throws -> HermesProbeResult {
        try perform { service in
            let dictionary = try callDictionary { reply in
                service.probe(sourcePath: sourceURL.path, withReply: reply)
            }
            return HermesProbeResult(
                python: dictionary["python"] as? String ?? "",
                hermes: dictionary["hermes"] as? String ?? ""
            )
        }
    }

    public func toolProbe(sourceURL: URL) throws -> String {
        try perform { service in
            try callString { reply in
                service.toolProbe(sourcePath: sourceURL.path, withReply: reply)
            }
        }
    }

    public func send(
        _ message: String,
        configuration: HermesAgentConfiguration,
        sourceURL: URL,
        onEvent: @escaping @Sendable (SwiftAgentEvent) -> Void
    ) throws -> String {
        try perform(eventHandler: onEvent) { service in
            try callString(timeout: 600) { reply in
                service.send(
                    message: message,
                    configuration: configuration.xpcDictionary,
                    sourcePath: sourceURL.path,
                    withReply: reply
                )
            }
        }
    }

    public func sessionState(sourceURL: URL) throws -> HermesSessionState {
        try decodeSessionState(
            try perform { service in
                try callString { reply in
                    service.sessionState(sourcePath: sourceURL.path, withReply: reply)
                }
            }
        )
    }

    public func loadSession(_ sessionID: String, sourceURL: URL) throws -> HermesSessionState {
        try decodeSessionState(
            try perform { service in
                try callString { reply in
                    service.loadSession(sessionID, sourcePath: sourceURL.path, withReply: reply)
                }
            }
        )
    }

    public func newSession(sourceURL: URL) throws -> HermesSessionState {
        try decodeSessionState(
            try perform { service in
                try callString { reply in
                    service.newSession(sourcePath: sourceURL.path, withReply: reply)
                }
            }
        )
    }

    private func perform<T>(
        eventHandler: (@Sendable (SwiftAgentEvent) -> Void)? = nil,
        _ operation: (SwiftAgentHermesXPCServiceProtocol) throws -> T
    ) throws -> T {
        guard let client else {
            throw unavailable()
        }

        lock.lock()
        defer { lock.unlock() }
        return try operation(try client.service(eventHandler: eventHandler))
    }

    private func callString(
        timeout: TimeInterval = 120,
        _ invoke: (@escaping (String?, String?) -> Void) -> Void
    ) throws -> String {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var value: String?
            var error: String?
        }
        let box = Box()

        invoke { value, error in
            box.value = value
            box.error = error
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) != .timedOut else {
            throw HermesAgentError.python("Hermes extension request timed out.")
        }
        if let error = box.error {
            throw HermesAgentError.python(error)
        }
        return box.value ?? ""
    }

    private func callDictionary(
        timeout: TimeInterval = 120,
        _ invoke: (@escaping (NSDictionary?, String?) -> Void) -> Void
    ) throws -> NSDictionary {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var value: NSDictionary?
            var error: String?
        }
        let box = Box()

        invoke { value, error in
            box.value = value
            box.error = error
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + timeout) != .timedOut else {
            throw HermesAgentError.python("Hermes extension request timed out.")
        }
        if let error = box.error {
            throw HermesAgentError.python(error)
        }
        return box.value ?? [:]
    }

    private func decodeSessionState(_ raw: String) throws -> HermesSessionState {
        let state = try JSONDecoder().decode(HermesSessionState.self, from: Data(raw.utf8))
        if !state.ok {
            throw HermesAgentError.python(state.traceback ?? raw)
        }
        return state
    }

    private func unavailable() -> HermesAgentError {
        HermesAgentError.python(
            "Hermes extension backend requires an iOS 26 ExtensionFoundation app extension point."
        )
    }
}

private protocol HermesExtensionXPCClient: Sendable {
    func service(
        eventHandler: (@Sendable (SwiftAgentEvent) -> Void)?
    ) throws -> SwiftAgentHermesXPCServiceProtocol
}

private final class SwiftAgentHermesXPCEventSink: NSObject, SwiftAgentHermesXPCEventSinkProtocol {
    private let lock = NSLock()
    private var eventHandler: (@Sendable (SwiftAgentEvent) -> Void)?

    init(eventHandler: (@Sendable (SwiftAgentEvent) -> Void)?) {
        self.eventHandler = eventHandler
    }

    func update(eventHandler: (@Sendable (SwiftAgentEvent) -> Void)?) {
        lock.lock()
        self.eventHandler = eventHandler
        lock.unlock()
    }

    func swiftAgentHermesDidEmitEvent(kind: String, payload: String) {
        lock.lock()
        let eventHandler = eventHandler
        lock.unlock()
        eventHandler?(SwiftAgentEvent(kind: kind, payload: payload))
    }
}

#if os(iOS)
@available(iOS 26.0, *)
private final class ExtensionFoundationHermesXPCClient: HermesExtensionXPCClient, @unchecked Sendable {
    private let appExtensionPoint: AppExtensionPoint
    private var process: AppExtensionProcess?
    private var connection: NSXPCConnection?
    private var eventSink: SwiftAgentHermesXPCEventSink?

    init(appExtensionPoint: AppExtensionPoint) {
        self.appExtensionPoint = appExtensionPoint
    }

    func service(
        eventHandler: (@Sendable (SwiftAgentEvent) -> Void)?
    ) throws -> SwiftAgentHermesXPCServiceProtocol {
        let connection = try connection(eventHandler: eventHandler)
        guard let service = connection.remoteObjectProxyWithErrorHandler({ error in
            NSLog("SwiftAgent Hermes XPC service error: %@", String(describing: error))
        }) as? SwiftAgentHermesXPCServiceProtocol else {
            throw HermesAgentError.python("Unable to create Hermes extension XPC proxy.")
        }
        return service
    }

    private func connection(
        eventHandler: (@Sendable (SwiftAgentEvent) -> Void)?
    ) throws -> NSXPCConnection {
        if let connection {
            eventSink?.update(eventHandler: eventHandler)
            return connection
        }

        let identity = try discoverIdentity()
        let createdProcess = try AppExtensionProcess(
            configuration: AppExtensionProcess.Configuration(
                appExtensionIdentity: identity,
                onInterruption: {
                    NSLog("SwiftAgent Hermes extension process interrupted")
                }
            )
        )
        let createdConnection = try createdProcess.makeXPCConnection()
        eventSink = SwiftAgentHermesXPCEventSink(eventHandler: eventHandler)
        createdConnection.remoteObjectInterface = SwiftAgentHermesXPC.serviceInterface()
        createdConnection.exportedInterface = SwiftAgentHermesXPC.eventSinkInterface()
        createdConnection.exportedObject = eventSink
        createdConnection.resume()

        process = createdProcess
        connection = createdConnection
        return createdConnection
    }

    private func discoverIdentity() throws -> AppExtensionIdentity {
        let semaphore = DispatchSemaphore(value: 0)
        final class Box: @unchecked Sendable {
            var identity: AppExtensionIdentity?
            var error: Error?
        }
        let box = Box()

        Task {
            do {
                let monitor = try await AppExtensionPoint.Monitor(appExtensionPoint: appExtensionPoint)
                box.identity = monitor.identities.first
            } catch {
                box.error = error
            }
            semaphore.signal()
        }

        guard semaphore.wait(timeout: .now() + 10) != .timedOut else {
            throw HermesAgentError.python("Timed out discovering Hermes extension.")
        }
        if let error = box.error {
            throw error
        }
        guard let identity = box.identity else {
            throw HermesAgentError.python(
                "No Hermes extension is installed for the configured extension point. " +
                "Check that the worker extension is embedded in the host app and that its bound host bundle identifier matches the app bundle identifier."
            )
        }
        return identity
    }
}
#endif
