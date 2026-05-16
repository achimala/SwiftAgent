import SwiftAgentCore
import Foundation

@objc(SwiftAgentHermesXPCEventSinkProtocol)
public protocol SwiftAgentHermesXPCEventSinkProtocol: AnyObject {
    func swiftAgentHermesDidEmitEvent(
        kind: String,
        payload: String
    )
}

@objc(SwiftAgentHermesXPCServiceProtocol)
public protocol SwiftAgentHermesXPCServiceProtocol {
    func prepare(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    )

    func probe(
        sourcePath: String,
        withReply reply: @escaping (NSDictionary?, String?) -> Void
    )

    func toolProbe(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    )

    func send(
        message: String,
        configuration: NSDictionary,
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    )

    func sessionState(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    )

    func loadSession(
        _ sessionID: String,
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    )

    func newSession(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    )
}

public enum SwiftAgentHermesXPC {
    public static func serviceInterface() -> NSXPCInterface {
        NSXPCInterface(with: SwiftAgentHermesXPCServiceProtocol.self)
    }

    public static func eventSinkInterface() -> NSXPCInterface {
        NSXPCInterface(with: SwiftAgentHermesXPCEventSinkProtocol.self)
    }
}

public final class SwiftAgentHermesXPCService: NSObject, SwiftAgentHermesXPCServiceProtocol {
    public typealias ModelProviderResolver = @Sendable (HermesAgentConfiguration) -> (any SwiftAgentModelProvider)?

    private let runtime: HermesAgentRuntime
    private let modelProviderResolver: ModelProviderResolver

    public init(
        runtime: HermesAgentRuntime = HermesAgentRuntime(),
        modelProviderResolver: @escaping ModelProviderResolver = { _ in nil }
    ) {
        self.runtime = runtime
        self.modelProviderResolver = modelProviderResolver
    }

    public func prepare(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        replyWithString(reply) {
            try runtime.prepareHermes(hermesSourcePath: hermesSourceURL(from: sourcePath))
        }
    }

    public func probe(
        sourcePath: String,
        withReply reply: @escaping (NSDictionary?, String?) -> Void
    ) {
        do {
            let result = try runtime.probe(hermesSourcePath: hermesSourceURL(from: sourcePath))
            reply(
                [
                    "python": result.python,
                    "hermes": result.hermes,
                ],
                nil
            )
        } catch {
            reply(nil, displayText(for: error))
        }
    }

    public func toolProbe(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        replyWithString(reply) {
            try runtime.toolProbe(hermesSourcePath: hermesSourceURL(from: sourcePath))
        }
    }

    public func send(
        message: String,
        configuration: NSDictionary,
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        replyWithString(reply) {
            let agentConfiguration = try HermesAgentConfiguration(xpcDictionary: configuration)
            agentConfiguration.applyRuntimeEnvironment()
            if let modelProvider = modelProviderResolver(agentConfiguration) {
                runtime.setModelProvider(modelProvider)
            }
            let eventSink = NSXPCConnection.current()?.remoteObjectProxyWithErrorHandler { error in
                NSLog("SwiftAgent Hermes XPC event sink error: %@", String(describing: error))
            } as? SwiftAgentHermesXPCEventSinkProtocol
            let eventSinkBox = SwiftAgentHermesXPCEventSinkBox(eventSink)

            return try runtime.chat(
                message: message,
                configuration: agentConfiguration.runtimeConfiguration,
                hermesSourcePath: hermesSourceURL(from: sourcePath),
                onEvent: { event in
                    eventSinkBox.eventSink?.swiftAgentHermesDidEmitEvent(
                        kind: event.kind,
                        payload: event.payload
                    )
                }
            )
        }
    }

    public func sessionState(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        replyWithString(reply) {
            let state = try runtime.sessionState(hermesSourcePath: hermesSourceURL(from: sourcePath))
            return try encode(state)
        }
    }

    public func loadSession(
        _ sessionID: String,
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        replyWithString(reply) {
            let state = try runtime.loadSession(sessionID, hermesSourcePath: hermesSourceURL(from: sourcePath))
            return try encode(state)
        }
    }

    public func newSession(
        sourcePath: String,
        withReply reply: @escaping (String?, String?) -> Void
    ) {
        replyWithString(reply) {
            let state = try runtime.newSession(hermesSourcePath: hermesSourceURL(from: sourcePath))
            return try encode(state)
        }
    }

    private func replyWithString(
        _ reply: @escaping (String?, String?) -> Void,
        operation: () throws -> String
    ) {
        do {
            reply(try operation(), nil)
        } catch {
            reply(nil, displayText(for: error))
        }
    }

    private func hermesSourceURL(from requestedPath: String) throws -> URL {
        let requested = URL(fileURLWithPath: requestedPath, isDirectory: true)
        if FileManager.default.fileExists(atPath: requested.path) {
            return requested
        }

        guard let resourceURL = Bundle.main.resourceURL else {
            throw HermesAgentError.python("Extension bundle resources are not available.")
        }
        let bundled = resourceURL
            .appendingPathComponent("PythonApp", isDirectory: true)
            .appendingPathComponent("hermes", isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundled.path) else {
            throw HermesAgentError.missingHermesSource(bundled)
        }
        return bundled
    }

    private func encode<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private func displayText(for error: Error) -> String {
        if let description = (error as? LocalizedError)?.errorDescription, !description.isEmpty {
            return description
        }
        return String(describing: error)
    }
}

private final class SwiftAgentHermesXPCEventSinkBox: @unchecked Sendable {
    let eventSink: SwiftAgentHermesXPCEventSinkProtocol?

    init(_ eventSink: SwiftAgentHermesXPCEventSinkProtocol?) {
        self.eventSink = eventSink
    }
}

extension HermesAgentConfiguration {
    var xpcDictionary: NSDictionary {
        var dictionary: [String: Any] = [
            "baseURL": baseURL,
            "apiKey": apiKey,
            "model": model,
            "enableSoul": enableSoul,
            "enableContext": enableContext,
            "enableMemory": enableMemory,
        ]
        if let localMLXMaxTokens {
            dictionary["localMLXMaxTokens"] = localMLXMaxTokens
        }
        if let localMLXTemperature {
            dictionary["localMLXTemperature"] = localMLXTemperature
        }
        if let contextLength {
            dictionary["contextLength"] = contextLength
        }
        return dictionary as NSDictionary
    }

    init(xpcDictionary dictionary: NSDictionary) throws {
        guard let baseURL = dictionary["baseURL"] as? String,
              let apiKey = dictionary["apiKey"] as? String,
              let model = dictionary["model"] as? String
        else {
            throw HermesAgentError.python("Invalid Hermes XPC configuration payload.")
        }

        self.init(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            contextLength: dictionary["contextLength"] as? Int,
            enableSoul: dictionary["enableSoul"] as? Bool ?? true,
            enableContext: dictionary["enableContext"] as? Bool ?? true,
            enableMemory: dictionary["enableMemory"] as? Bool ?? true,
            localMLXMaxTokens: dictionary["localMLXMaxTokens"] as? Int,
            localMLXTemperature: dictionary["localMLXTemperature"] as? Double
        )
    }
}
