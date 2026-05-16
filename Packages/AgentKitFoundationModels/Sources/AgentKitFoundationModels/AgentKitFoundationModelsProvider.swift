import AgentKit
import AgentKitCore
import Foundation
import FoundationModels

private enum FoundationModelsProviderError: Error {
    case timedOut
}

private final class FoundationModelsCompletionGate: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete(_ action: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !completed else { return }
        completed = true
        action()
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum AgentKitFoundationModels {
    public static let modelIdentifier = "apple-foundation-models"
    public static let hermesContextLength = 64_000
    public static let maximumPromptCharacters = 700
    public static let maximumResponseTokens = 128
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public extension HermesAgentConfiguration {
    static func foundationModels(
        maxTokens: Int = 256,
        temperature: Double = 0.2,
        enableSoul: Bool = true,
        enableContext: Bool = true,
        enableMemory: Bool = true
    ) -> HermesAgentConfiguration {
        HermesAgentConfiguration(
            baseURL: "hermes-foundation-models://chat",
            apiKey: "foundation-models",
            model: AgentKitFoundationModels.modelIdentifier,
            contextLength: AgentKitFoundationModels.hermesContextLength,
            enableSoul: enableSoul,
            enableContext: enableContext,
            enableMemory: enableMemory,
            localMLXMaxTokens: maxTokens,
            localMLXTemperature: temperature
        )
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public actor AgentKitFoundationModelsProvider: AgentKitModelProvider {
    public init() {}

    public func complete(
        request: AgentKitModelRequest,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) async throws -> String {
        let started = Date()
        onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_start", started: started)))

        let object = try JSONSerialization.jsonObject(with: Data(request.rawJSON.utf8))
        guard let requestObject = object as? [String: Any] else {
            return Self.errorPayload("Foundation Models request was not a JSON object.")
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            return Self.errorPayload("Apple Foundation Models is unavailable: \(availabilityDescription(model.availability)).")
        }

        let messages = requestObject["messages"] as? [[String: Any]] ?? []
        let requestedTools = requestObject["tools"] as? [[String: Any]] ?? []
        let tools = messagesContainToolResults(messages) || !Self.shouldEnableTools(for: messages)
            ? []
            : requestedTools
        let options = generationOptions(from: requestObject)
        let prompt = promptText(messages: messages, tools: tools)
        onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_prompt_ready", started: started)))

        if tools.isEmpty {
            do {
                let session = LanguageModelSession(
                    model: model,
                    instructions: instructionsText(hasTools: false)
                )
                onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_session_created", started: started)))
                let text = try await respondContentWithTimeout(
                    session: session,
                    prompt: prompt,
                    options: options,
                    seconds: 20
                )
                onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_response_ready", started: started)))
                onEvent(.init(kind: "delta", payload: text))
                onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_done", started: started)))
                onEvent(.init(kind: "done", payload: ""))
                return try Self.responsePayload(finalResponse: text, toolCalls: [])
            } catch {
                return try Self.responsePayload(finalResponse: Self.rejectionMessage(for: error), toolCalls: [])
            }
        }

        let recorder = FoundationToolCallRecorder()
        let foundationTools = tools.filter(Self.isSupportedFoundationTool).compactMap { tool in
            try? Self.foundationTool(from: tool, recorder: recorder)
        }
        onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_tools_ready", started: started)))
        let toolSession = LanguageModelSession(
            model: model,
            tools: foundationTools,
            instructions: instructionsText(hasTools: true)
        )
        onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_tool_session_created", started: started)))
        let responseContent: String
        do {
            responseContent = try await respondContentWithTimeout(
                session: toolSession,
                prompt: prompt,
                options: options,
                seconds: 20
            )
            onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_tool_response_ready", started: started)))
        } catch {
            return try Self.responsePayload(finalResponse: Self.rejectionMessage(for: error), toolCalls: [])
        }
        let toolCalls = await recorder.toolCalls()
            .enumerated()
            .map { index, call in
                call.openAIToolCall(index: index)
            }
        if toolCalls.isEmpty {
            onEvent(.init(kind: "delta", payload: responseContent))
        }
        onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_done", started: started)))
        onEvent(.init(kind: "done", payload: ""))
        return try Self.responsePayload(
            finalResponse: toolCalls.isEmpty ? responseContent : "",
            toolCalls: toolCalls
        )
    }

    private func streamText(
        prompt: String,
        session: LanguageModelSession,
        started: Date,
        options: GenerationOptions,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) async throws -> String {
        let stream = session.streamResponse(to: prompt, options: options)
        var previous = ""
        var emittedFirstDelta = false

        for try await snapshot in stream {
            let current = snapshot.content
            if current.count > previous.count {
                let delta = String(current.dropFirst(previous.count))
                if !delta.isEmpty {
                    if !emittedFirstDelta {
                        emittedFirstDelta = true
                        onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_first_delta", started: started)))
                    }
                    onEvent(.init(kind: "delta", payload: delta))
                }
            }
            previous = current
        }

        return previous
    }

    private func promptText(messages: [[String: Any]], tools: [[String: Any]]) -> String {
        var sections: [String] = []
        sections.append("Conversation:")
        for message in messages.suffix(8) {
            let role = message["role"] as? String ?? "user"
            guard role != "system", role != "developer" else { continue }
            let content = Self.contentText(message["content"])
            guard !content.isEmpty else { continue }
            sections.append("\(role): \(content)")
        }

        if !tools.isEmpty {
            let toolNames = tools.compactMap { tool -> String? in
                let function = tool["function"] as? [String: Any]
                return function?["name"] as? String
            }.joined(separator: ", ")
            sections.append(
                """
                Available tools: \(toolNames)
                Use a tool when the user asks you to read, write, inspect, search, or run commands. Do not claim a tool action is complete until a tool has been called.
                """
            )
        }

        return Self.truncatePrompt(sections.joined(separator: "\n\n"))
    }

    private func messagesContainToolResults(_ messages: [[String: Any]]) -> Bool {
        messages.contains { message in
            (message["role"] as? String) == "tool"
                || message["tool_name"] != nil
                || message["tool_call_id"] != nil
        }
    }

    private func instructionsText(hasTools: Bool) -> String {
        if hasTools {
            return """
            You are an on-device model provider for an iOS agent. Return a structured response that either answers directly or requests tool calls. Use only the provided tools. Keep tool arguments valid JSON strings.
            """
        }

        return "You are an on-device model provider for an iOS agent. Answer clearly and concisely."
    }

    private func generationOptions(from requestObject: [String: Any]) -> GenerationOptions {
        let maxTokens = requestObject["max_tokens"] as? Int
            ?? requestObject["max_completion_tokens"] as? Int
        let temperature: Double?
        if let value = requestObject["temperature"] as? Double {
            temperature = value
        } else if let value = requestObject["temperature"] as? Float {
            temperature = Double(value)
        } else {
            temperature = nil
        }
        return GenerationOptions(
            sampling: temperature == 0 ? .greedy : nil,
            temperature: temperature,
            maximumResponseTokens: min(maxTokens ?? AgentKitFoundationModels.maximumResponseTokens, AgentKitFoundationModels.maximumResponseTokens)
        )
    }

    private static func truncatePrompt(_ prompt: String) -> String {
        guard prompt.count > AgentKitFoundationModels.maximumPromptCharacters else {
            return prompt
        }

        let suffix = prompt.suffix(AgentKitFoundationModels.maximumPromptCharacters)
        return "[Earlier conversation omitted for the on-device model window.]\n\n\(suffix)"
    }

    private static func contentText(_ content: Any?) -> String {
        if let string = content as? String {
            return string
        }
        if let parts = content as? [[String: Any]] {
            return parts.compactMap { part in
                part["text"] as? String
            }.joined(separator: "\n")
        }
        return ""
    }

    private static func responsePayload(finalResponse: String, toolCalls: [[String: Any]]) throws -> String {
        let payload: [String: Any] = [
            "final_response": finalResponse,
            "tool_calls": toolCalls,
            "last_reasoning": "",
            "reasoning_tokens": 0,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func rejectionMessage(for error: Error) -> String {
        if let providerError = error as? FoundationModelsProviderError, providerError == .timedOut {
            return "Apple Foundation Models did not return in time. Try a shorter request or use a cloud model for heavier work."
        }
        let message = String(describing: error)
        if message.localizedCaseInsensitiveContains("context")
            || message.localizedCaseInsensitiveContains("token")
        {
            return "Apple Foundation Models rejected this turn because the prompt is too large for the on-device model window. Try a new chat or a shorter request."
        }
        return "Apple Foundation Models could not answer this turn: \(message)"
    }

    private static func foundationTool(
        from tool: [String: Any],
        recorder: FoundationToolCallRecorder
    ) throws -> OpenAIFoundationTool {
        let function = tool["function"] as? [String: Any] ?? [:]
        let name = function["name"] as? String ?? "tool"
        let description = function["description"] as? String ?? ""
        let parameters = try compactSchema(for: name)
        return OpenAIFoundationTool(
            name: name,
            description: description,
            parameters: parameters,
            recorder: recorder
        )
    }

    private static func isSupportedFoundationTool(_ tool: [String: Any]) -> Bool {
        let function = tool["function"] as? [String: Any] ?? [:]
        let name = function["name"] as? String ?? ""
        return ["read_file", "write_file", "terminal"].contains(name)
    }

    private static func shouldEnableTools(for messages: [[String: Any]]) -> Bool {
        guard let lastUserMessage = messages.reversed().first(where: { ($0["role"] as? String) == "user" }) else {
            return false
        }
        let text = contentText(lastUserMessage["content"]).lowercased()
        let words = Set(
            text.split { !$0.isLetter && !$0.isNumber }
                .map(String.init)
        )
        let toolHints: Set<String> = [
            "read",
            "write",
            "file",
            "create",
            "save",
            "search",
            "inspect",
            "run",
            "command",
            "terminal",
            "shell",
        ]
        return !words.isDisjoint(with: toolHints)
    }

    private func respondContentWithTimeout(
        session: LanguageModelSession,
        prompt: String,
        options: GenerationOptions,
        seconds: Double
    ) async throws -> String {
        let responseTask = Task {
            try await session.respond(to: prompt, options: options).content
        }
        let gate = FoundationModelsCompletionGate()

        return try await withCheckedThrowingContinuation { continuation in
            Task {
                do {
                    let response = try await responseTask.value
                    gate.complete {
                        continuation.resume(returning: response)
                    }
                } catch {
                    gate.complete {
                        continuation.resume(throwing: error)
                    }
                }
            }

            Task {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    gate.complete {
                        responseTask.cancel()
                        continuation.resume(throwing: FoundationModelsProviderError.timedOut)
                    }
                } catch {
                    // The timeout task was cancelled because the model returned first.
                }
            }
        }
    }

    private static func compactSchema(for toolName: String) throws -> GenerationSchema {
        let properties: [DynamicGenerationSchema.Property]
        switch toolName {
        case "write_file":
            properties = [
                .init(name: "path", description: "Workspace-relative file path", schema: .init(type: String.self)),
                .init(name: "content", description: "Text content to write", schema: .init(type: String.self)),
            ]
        case "read_file":
            properties = [
                .init(name: "path", description: "Workspace-relative file path", schema: .init(type: String.self)),
            ]
        case "terminal":
            properties = [
                .init(name: "command", description: "Shell command to run in the workspace", schema: .init(type: String.self)),
            ]
        default:
            properties = []
        }
        let root = DynamicGenerationSchema(
            name: "\(toolName)_Arguments",
            description: "Arguments for \(toolName)",
            properties: properties
        )
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func errorPayload(_ message: String) -> String {
        let payload = ["error": message]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]) else {
            return "{\"error\":\"Foundation Models request failed.\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func timingPayload(_ label: String, started: Date) -> String {
        let payload: [String: Any] = [
            "label": label,
            "elapsed_ms": Date().timeIntervalSince(started) * 1000,
        ]
        let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? label
    }

    private func availabilityDescription(_ availability: SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "available"
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled"
            case .deviceNotEligible:
                return "device is not eligible"
            case .modelNotReady:
                return "model is not ready"
            @unknown default:
                return "unknown unavailable reason"
            }
        @unknown default:
            return "unknown availability"
        }
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private actor FoundationToolCallRecorder {
    private var calls: [RecordedFoundationToolCall] = []

    func record(name: String, arguments: GeneratedContent) {
        calls.append(
            RecordedFoundationToolCall(
                id: "call_foundation_models_\(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16))",
                name: name,
                arguments: arguments.jsonString
            )
        )
    }

    func toolCalls() -> [RecordedFoundationToolCall] {
        calls
    }
}

private struct RecordedFoundationToolCall: Sendable {
    var id: String
    var name: String
    var arguments: String

    func openAIToolCall(index: Int) -> [String: Any] {
        [
            "id": id,
            "index": index,
            "type": "function",
            "function": [
                "name": name,
                "arguments": arguments,
            ],
        ]
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private struct OpenAIFoundationTool: Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let recorder: FoundationToolCallRecorder

    var includesSchemaInInstructions: Bool { true }

    func call(arguments: GeneratedContent) async throws -> String {
        await recorder.record(name: name, arguments: arguments)
        return "Tool call recorded for host execution."
    }
}
