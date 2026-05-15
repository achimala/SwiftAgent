import AgentKit
import AgentKitCore
import Foundation
import HuggingFace
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

extension ChatSession: @unchecked @retroactive Sendable {}

public enum AgentKitLocalMLXModels {
    public static let qwen35_2BOptiQ4Bit = "mlx-community/Qwen3.5-2B-OptiQ-4bit"
}

extension HermesAgentConfiguration {
    public static func localMLX(
        model: String = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit,
        maxTokens: Int = 128,
        temperature: Double = 0.2,
        enableSoul: Bool = true,
        enableContext: Bool = true,
        enableMemory: Bool = true
    ) -> HermesAgentConfiguration {
        HermesAgentConfiguration(
            baseURL: "hermes-local-mlx://chat",
            apiKey: "local-mlx",
            model: model,
            enableSoul: enableSoul,
            enableContext: enableContext,
            enableMemory: enableMemory,
            localMLXMaxTokens: maxTokens,
            localMLXTemperature: temperature
        )
    }
}

public struct AgentKitLocalLLMConfiguration: Sendable {
    public var modelID: String
    public var maxTokens: Int
    public var temperature: Float

    public init(
        modelID: String = AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit,
        maxTokens: Int = 128,
        temperature: Float = 0.2
    ) {
        self.modelID = modelID
        self.maxTokens = maxTokens
        self.temperature = temperature
    }
}

public actor AgentKitMLXModelProvider: AgentKitModelProvider {
    private var sessions: [String: ChatSession] = [:]
    private var didConfigureMemory = false

    public init() {}

    public func complete(
        request: AgentKitModelRequest,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) async throws -> String {
        let requestData = Data(request.rawJSON.utf8)
        let object = try JSONSerialization.jsonObject(with: requestData)
        guard let requestObject = object as? [String: Any] else {
            return Self.errorPayload("Local MLX request was not a JSON object.")
        }

        let model = (requestObject["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let messages = requestObject["messages"] as? [[String: Any]] ?? []
        let maxTokens = requestObject["max_tokens"] as? Int ?? requestObject["max_completion_tokens"] as? Int ?? 256
        let temperature: Float
        if let value = requestObject["temperature"] as? Float {
            temperature = value
        } else if let value = requestObject["temperature"] as? Double {
            temperature = Float(value)
        } else {
            temperature = 0.2
        }

        let configuration = AgentKitLocalLLMConfiguration(
            modelID: (model?.isEmpty == false ? model! : AgentKitLocalMLXModels.qwen35_2BOptiQ4Bit),
            maxTokens: maxTokens,
            temperature: temperature
        )
        let tools = (requestObject["tools"] as? [[String: Any]] ?? [])
            .compactMap(Self.toolSpec(from:))

        return try await chat(
            message: Self.prompt(from: messages),
            configuration: configuration,
            tools: tools,
            onEvent: onEvent
        )
    }

    public func chat(
        message: String,
        configuration: AgentKitLocalLLMConfiguration,
        tools: [ToolSpec] = [],
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) async throws -> String {
        let started = Date()
        onEvent(.init(kind: "timing", payload: timingPayload("mlx_chat_start", elapsedFrom: started, detail: configuration.modelID)))

        #if targetEnvironment(simulator)
            throw LocalMLXError.simulatorUnsupported
        #else
            let session = try await session(for: configuration, onEvent: onEvent, started: started)
            session.generateParameters = GenerateParameters(
                maxTokens: configuration.maxTokens,
                temperature: configuration.temperature
            )
            session.tools = tools.isEmpty ? nil : tools
            await session.clear()
            Memory.clearCache()
            var response = ""
            var toolCalls: [[String: Any]] = []

            do {
                let stream = session.streamDetails(to: message, images: [], videos: [])
                for try await generation in stream {
                    switch generation {
                    case .chunk(let chunk):
                        response += chunk
                        onEvent(.init(kind: "delta", payload: chunk))
                    case .toolCall(let toolCall):
                        toolCalls.append(Self.openAIToolCallPayload(toolCall))
                    case .info:
                        break
                    }
                }
            } catch {
                await session.clear()
                await session.synchronize()
                Memory.clearCache()
                throw error
            }

            await session.clear()
            await session.synchronize()
            let memoryBeforeClear = Memory.snapshot()
            Memory.clearCache()
            onEvent(.init(kind: "timing", payload: timingPayload("mlx_memory_after_turn", elapsedFrom: started, detail: memoryDetail(memoryBeforeClear))))
            onEvent(.init(kind: "timing", payload: timingPayload("mlx_chat_done", elapsedFrom: started, detail: configuration.modelID)))
            onEvent(.init(kind: "done", payload: ""))

            let payload: [String: Any] = [
                "final_response": response,
                "tool_calls": toolCalls,
                "last_reasoning": "",
                "reasoning_tokens": 0,
            ]
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self)
        #endif
    }

    public func clear(modelID: String? = nil) async {
        if let modelID {
            sessions.removeValue(forKey: modelID)
        } else {
            sessions.removeAll()
        }
    }

    private func session(
        for configuration: AgentKitLocalLLMConfiguration,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void,
        started: Date
    ) async throws -> ChatSession {
        configureMemoryIfNeeded(onEvent: onEvent, started: started)
        if let session = sessions[configuration.modelID] {
            return session
        }

        onEvent(.init(kind: "timing", payload: timingPayload("mlx_model_load_start", elapsedFrom: started, detail: configuration.modelID)))

        let modelConfiguration = ModelConfiguration(id: configuration.modelID)
        let model = try await LLMModelFactory.shared.loadContainer(
            from: HubDownloader(),
            using: TransformersTokenizerLoader(),
            configuration: modelConfiguration
        ) { progress in
            let detail: String
            if progress.totalUnitCount > 0 {
                let percent = Double(progress.completedUnitCount) / Double(progress.totalUnitCount) * 100
                detail = "\(configuration.modelID) \(String(format: "%.0f", percent))%"
            } else {
                detail = configuration.modelID
            }
            onEvent(.init(kind: "timing", payload: self.timingPayload("mlx_model_download", elapsedFrom: started, detail: detail)))
        }

        let parameters = GenerateParameters(
            maxTokens: configuration.maxTokens,
            temperature: configuration.temperature
        )
        let session = ChatSession(model, generateParameters: parameters)
        sessions[configuration.modelID] = session

        onEvent(.init(kind: "timing", payload: timingPayload("mlx_model_ready", elapsedFrom: started, detail: configuration.modelID)))
        return session
    }

    private func configureMemoryIfNeeded(
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void,
        started: Date
    ) {
        guard !didConfigureMemory else { return }
        didConfigureMemory = true
        Memory.cacheLimit = 32 * 1024 * 1024
        Memory.clearCache()
        onEvent(.init(kind: "timing", payload: timingPayload("mlx_memory_configured", elapsedFrom: started, detail: memoryDetail(Memory.snapshot()))))
    }

    private nonisolated func memoryDetail(_ snapshot: Memory.Snapshot) -> String {
        "active=\(snapshot.activeMemory) cache=\(snapshot.cacheMemory) peak=\(snapshot.peakMemory)"
    }

    private nonisolated static func openAIToolCallPayload(_ toolCall: ToolCall) -> [String: Any] {
        [
            "id": "call_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(24))",
            "type": "function",
            "function": [
                "name": toolCall.function.name,
                "arguments": jsonString(from: toolCall.function.arguments.mapValues(\.anyValue)),
            ],
        ]
    }

    private nonisolated static func jsonString(from value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8)
        else {
            return "{}"
        }
        return text
    }

    private nonisolated static func prompt(from messages: [[String: Any]]) -> String {
        var lines: [String] = [
            "You are running as an embedded model backend on iOS.",
            "Respond naturally to the current conversation.",
        ]
        for message in messages {
            let role = (message["role"] as? String) ?? "message"
            let content = contentText(message["content"])
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            lines.append("\(role.capitalized): \(content)")
        }
        lines.append("Assistant:")
        return lines.joined(separator: "\n\n")
    }

    private nonisolated static func contentText(_ value: Any?) -> String {
        if let text = value as? String {
            return text
        }
        if let parts = value as? [[String: Any]] {
            return parts.compactMap { part in
                if let text = part["text"] as? String {
                    return text
                }
                if let type = part["type"] as? String, type.contains("image") {
                    return "[image]"
                }
                return nil
            }.joined(separator: "\n")
        }
        guard let value else {
            return ""
        }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8)
        {
            return text
        }
        return String(describing: value)
    }

    private nonisolated static func toolSpec(from object: [String: Any]) -> ToolSpec? {
        sendableObject(object)
    }

    private nonisolated static func sendableObject(_ object: [String: Any]) -> [String: any Sendable] {
        var result: [String: any Sendable] = [:]
        for (key, value) in object {
            result[key] = sendableValue(value)
        }
        return result
    }

    private nonisolated static func sendableArray(_ array: [Any]) -> [any Sendable] {
        array.map { sendableValue($0) }
    }

    private nonisolated static func sendableValue(_ value: Any) -> any Sendable {
        switch value {
        case let text as String:
            return text
        case let bool as Bool:
            return bool
        case let int as Int:
            return int
        case let double as Double:
            return double
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return number.boolValue
            }
            let double = number.doubleValue
            return double.rounded() == double ? number.intValue : double
        case let object as [String: Any]:
            return sendableObject(object)
        case let array as [Any]:
            return sendableArray(array)
        case is NSNull:
            return ""
        default:
            return String(describing: value)
        }
    }

    private nonisolated static func errorPayload(_ message: String) -> String {
        let payload = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{\"error\":\"Local model request failed.\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private nonisolated func timingPayload(_ label: String, elapsedFrom started: Date, detail: String?) -> String {
        let elapsed = Date().timeIntervalSince(started) * 1000
        let payload: [String: Any] = [
            "label": label,
            "elapsed_ms": elapsed,
            "detail": detail as Any,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}


private struct HubDownloader: MLXLMCommon.Downloader {
    private let upstream: HuggingFace.HubClient

    init(_ upstream: HuggingFace.HubClient = HuggingFace.HubClient()) {
        self.upstream = upstream
    }

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repoID = HuggingFace.Repo.ID(rawValue: id) else {
            throw LocalMLXError.invalidRepositoryID(id)
        }
        return try await upstream.downloadSnapshot(
            of: repoID,
            revision: revision ?? "main",
            matching: patterns,
            progressHandler: { @MainActor progress in
                progressHandler(progress)
            }
        )
    }
}

private struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        let tokenizer = try await Tokenizers.AutoTokenizer.from(modelFolder: directory)
        return TransformersTokenizer(tokenizer)
    }
}

private struct TransformersTokenizer: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(
                messages: messages,
                tools: tools,
                additionalContext: additionalContext
            )
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}

private enum LocalMLXError: LocalizedError {
    case invalidRepositoryID(String)
    case simulatorUnsupported

    var errorDescription: String? {
        switch self {
        case .invalidRepositoryID(let id):
            "Invalid Hugging Face repository ID: \(id)"
        case .simulatorUnsupported:
            "Offline MLX is not available in the iOS Simulator. MLX initializes a Metal device during startup, so this path needs a physical iPhone build."
        }
    }
}
