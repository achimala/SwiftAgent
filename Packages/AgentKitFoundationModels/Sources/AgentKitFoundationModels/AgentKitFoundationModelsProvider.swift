import AgentKit
import AgentKitCore
import Foundation
import FoundationModels

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
public enum AgentKitFoundationModels {
    public static let hermesCompatibilityModel = "gpt-4.1-mini"
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
            model: AgentKitFoundationModels.hermesCompatibilityModel,
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
        let tools = messagesContainToolResults(messages) ? [] : requestedTools
        let options = generationOptions(from: requestObject)
        let prompt = promptText(messages: messages, tools: tools)
        let session = LanguageModelSession(
            model: model,
            instructions: instructionsText(hasTools: !tools.isEmpty)
        )
        session.prewarm()

        if tools.isEmpty {
            let text = try await streamText(
                prompt: prompt,
                session: session,
                options: options,
                onEvent: onEvent
            )
            onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_done", started: started)))
            onEvent(.init(kind: "done", payload: ""))
            return try Self.responsePayload(finalResponse: text, toolCalls: [])
        }

        let recorder = FoundationToolCallRecorder()
        let foundationTools = tools.filter(Self.isSupportedFoundationTool).compactMap { tool in
            try? Self.foundationTool(from: tool, recorder: recorder)
        }
        let toolSession = LanguageModelSession(
            model: model,
            tools: foundationTools,
            instructions: instructionsText(hasTools: true)
        )
        let response = try await toolSession.respond(to: prompt, options: options)
        let toolCalls = await recorder.toolCalls()
            .enumerated()
            .map { index, call in
                call.openAIToolCall(index: index)
            }
        if toolCalls.isEmpty {
            onEvent(.init(kind: "delta", payload: response.content))
        }
        onEvent(.init(kind: "timing", payload: timingPayload("foundation_models_done", started: started)))
        onEvent(.init(kind: "done", payload: ""))
        return try Self.responsePayload(
            finalResponse: toolCalls.isEmpty ? response.content : "",
            toolCalls: toolCalls
        )
    }

    private func streamText(
        prompt: String,
        session: LanguageModelSession,
        options: GenerationOptions,
        onEvent: @escaping @Sendable (AgentKitEvent) -> Void
    ) async throws -> String {
        let stream = session.streamResponse(to: prompt, options: options)
        var previous = ""

        for try await snapshot in stream {
            let current = snapshot.content
            if current.count > previous.count {
                let delta = String(current.dropFirst(previous.count))
                if !delta.isEmpty {
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
        for message in messages {
            let role = message["role"] as? String ?? "user"
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

        return sections.joined(separator: "\n\n")
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
            maximumResponseTokens: maxTokens
        )
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

    private static func generationSchema(name: String, jsonSchema: [String: Any]) throws -> GenerationSchema {
        let root = dynamicSchema(name: name, jsonSchema: jsonSchema)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func dynamicSchema(name: String, jsonSchema: [String: Any]) -> DynamicGenerationSchema {
        let type = jsonSchema["type"] as? String
        if type == "object" || jsonSchema["properties"] is [String: Any] {
            let propertiesObject = jsonSchema["properties"] as? [String: Any] ?? [:]
            let required = Set(jsonSchema["required"] as? [String] ?? [])
            let properties = propertiesObject.keys.sorted().map { propertyName in
                let propertySchema = propertiesObject[propertyName] as? [String: Any] ?? [:]
                return DynamicGenerationSchema.Property(
                    name: propertyName,
                    description: propertySchema["description"] as? String,
                    schema: dynamicSchema(name: "\(name)_\(propertyName)", jsonSchema: propertySchema),
                    isOptional: !required.contains(propertyName)
                )
            }
            return DynamicGenerationSchema(
                name: name,
                description: jsonSchema["description"] as? String,
                properties: properties
            )
        }

        if type == "array" {
            let itemSchema = jsonSchema["items"] as? [String: Any] ?? ["type": "string"]
            return DynamicGenerationSchema(
                arrayOf: dynamicSchema(name: "\(name)_Item", jsonSchema: itemSchema)
            )
        }

        if let choices = jsonSchema["enum"] as? [String], !choices.isEmpty {
            return DynamicGenerationSchema(
                name: name,
                description: jsonSchema["description"] as? String,
                anyOf: choices
            )
        }

        switch type {
        case "boolean":
            return DynamicGenerationSchema(type: Bool.self)
        case "integer":
            return DynamicGenerationSchema(type: Int.self)
        case "number":
            return DynamicGenerationSchema(type: Double.self)
        default:
            return DynamicGenerationSchema(type: String.self)
        }
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
