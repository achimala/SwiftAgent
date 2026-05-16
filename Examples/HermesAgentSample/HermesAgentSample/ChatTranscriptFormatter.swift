import SwiftAgent
import Foundation

enum ChatTranscriptFormatter {
    static func entries(from session: HermesSessionDetail?) -> [ChatEntry] {
        guard let session, !session.messages.isEmpty else {
            return welcomeEntries()
        }

        var rendered: [ChatEntry] = []
        var pendingTools: [String: (name: String, input: String)] = [:]

        for message in session.messages {
            switch message.role {
            case "user":
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    rendered.append(ChatEntry(kind: .user, title: "You", body: content))
                }

            case "assistant":
                let content = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty {
                    rendered.append(ChatEntry(kind: .assistant, title: "Hermes", body: content))
                }
                for call in message.toolCalls ?? [] {
                    guard let id = call.id else { continue }
                    let name = call.function?.name ?? "tool"
                    let args = decodeToolArguments(call.function?.arguments)
                    let input = formatToolInput(
                        ToolEvent(
                            id: id,
                            name: name,
                            args: args,
                            ok: nil,
                            resultPreview: nil,
                            status: nil,
                            preview: nil,
                            duration: nil,
                            isError: nil
                        )
                    )
                    pendingTools[id] = (name, input)
                }

            case "tool":
                let callID = message.toolCallID ?? UUID().uuidString
                let pending = pendingTools.removeValue(forKey: callID)
                let name = message.toolName ?? pending?.name ?? "tool"
                let result = formatToolResult(
                    ToolEvent(
                        id: callID,
                        name: name,
                        args: nil,
                        ok: !persistedToolResultIsError(message.content),
                        resultPreview: message.content,
                        status: nil,
                        preview: nil,
                        duration: nil,
                        isError: nil
                    )
                )
                rendered.append(
                    ChatEntry(
                        kind: .tool,
                        title: displayToolName(name),
                        body: "",
                        isStreaming: false,
                        toolCallID: callID,
                        toolName: name,
                        toolInput: pending?.input,
                        toolOutput: result,
                        toolSucceeded: !persistedToolResultIsError(message.content)
                    )
                )

            default:
                break
            }
        }

        return rendered.isEmpty ? welcomeEntries() : rendered
    }

    static func welcomeEntries() -> [ChatEntry] {
        []
    }

    static func decodeToolEvent(_ payload: String) -> ToolEvent? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolEvent.self, from: data)
    }

    static func chatResult(from raw: String) -> HermesChatResult? {
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(HermesChatResult.self, from: data)
        else { return nil }
        return result
    }

    static func finalResponse(from result: HermesChatResult?, raw: String) -> String {
        if let response = result?.finalResponse {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = result?.error, !error.isEmpty {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func formatToolInput(_ tool: ToolEvent) -> String {
        guard let args = tool.args, !args.isEmpty else { return "" }

        switch tool.name {
        case "write_file":
            var parts: [String] = []
            if let path = args["path"]?.stringValue {
                parts.append("Path: \(displayPath(path))")
            }
            if let content = args["content"]?.stringValue, !content.isEmpty {
                parts.append("Content:\n\(content)")
            }
            return parts.isEmpty ? formatArgs(args) : parts.joined(separator: "\n\n")

        case "read_file":
            if let path = args["path"]?.stringValue {
                return "Path: \(displayPath(path))"
            }
            return formatArgs(args)

        case "terminal":
            if let command = args["command"]?.stringValue {
                return "$ \(command)"
            }
            return formatArgs(args)

        case "memory":
            var parts: [String] = []
            if let action = args["action"]?.stringValue {
                parts.append("Action: \(action)")
            }
            if let target = args["target"]?.stringValue {
                parts.append("Target: \(target)")
            }
            if let oldText = args["old_text"]?.stringValue, !oldText.isEmpty {
                parts.append("Match: \(oldText)")
            }
            if let content = args["content"]?.stringValue, !content.isEmpty {
                parts.append("Content:\n\(content)")
            }
            return parts.isEmpty ? formatArgs(args) : parts.joined(separator: "\n\n")

        default:
            return formatArgs(args)
        }
    }

    static func formatToolResult(_ tool: ToolEvent) -> String {
        guard let preview = tool.resultPreview, !preview.isEmpty else { return "" }
        guard let value = decodeJSONValue(preview), let object = value.objectValue else {
            return preview
        }

        switch tool.name {
        case "write_file":
            let bytes = object["bytes_written"]?.intValue
            var parts = [bytes.map { "Wrote \($0) bytes" }].compactMap(\.self)
            if let lint = object["lint"]?.objectValue,
               let message = lint["message"]?.stringValue,
               !message.isEmpty {
                parts.append(message)
            }
            return parts.isEmpty ? "File written" : parts.joined(separator: "\n")

        case "read_file":
            if let content = object["content"]?.stringValue {
                return cleanReadFileContent(content)
            }
            return preview

        case "terminal":
            var parts: [String] = []
            if let exitCode = object["exit_code"]?.intValue {
                parts.append("Exit code \(exitCode)")
            }
            if let output = object["output"]?.stringValue, !output.isEmpty {
                parts.append(output.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if let stdout = object["stdout"]?.stringValue, !stdout.isEmpty {
                parts.append(stdout)
            }
            if let stderr = object["stderr"]?.stringValue, !stderr.isEmpty {
                parts.append(stderr)
            }
            if let error = object["error"]?.stringValue, !error.isEmpty {
                parts.append(error)
            }
            return parts.isEmpty ? "Command finished" : parts.joined(separator: "\n\n")

        case "memory":
            var parts: [String] = []
            if let message = object["message"]?.stringValue {
                parts.append(message)
            }
            if let usage = object["usage"]?.stringValue {
                parts.append("Usage: \(usage)")
            }
            if let count = object["entry_count"]?.intValue {
                parts.append("Entries: \(count)")
            }
            if let error = object["error"]?.stringValue {
                parts.append(error)
            }
            return parts.isEmpty ? preview : parts.joined(separator: "\n")

        default:
            return object.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        }
    }

    static func toolResultIsError(_ tool: ToolEvent) -> Bool {
        if tool.isError == true || tool.ok == false {
            return true
        }
        guard let preview = tool.resultPreview else {
            return false
        }
        return persistedToolResultIsError(preview)
    }

    static func displayToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    private static func decodeToolArguments(_ text: String?) -> [String: JSONValue]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private static func persistedToolResultIsError(_ text: String) -> Bool {
        guard let value = decodeJSONValue(text), let object = value.objectValue else {
            return text.lowercased().contains("error")
        }
        if object["status"]?.stringValue == "error" {
            return true
        }
        if let success = object["success"], case .bool(false) = success {
            return true
        }
        if let error = object["error"] {
            switch error {
            case .null:
                return false
            case .string(let message):
                return !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            default:
                return true
            }
        }
        return false
    }

    private static func decodeJSONValue(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private static func formatArgs(_ args: [String: JSONValue]?) -> String {
        guard let args, !args.isEmpty else { return "" }
        if let command = args["command"] {
            return "$ \(command)"
        }
        if let path = args["path"] {
            return String(describing: path)
        }
        return args.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }

    private static func displayPath(_ path: String) -> String {
        if path.contains("/Containers/Data/Application/") {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return path
    }

    private static func cleanReadFileContent(_ content: String) -> String {
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let cleaned = lines.map { line in
            let text = String(line)
            guard let separator = text.firstIndex(of: "|") else { return text }
            let prefix = text[..<separator]
            guard prefix.trimmingCharacters(in: .whitespaces).allSatisfy(\.isNumber) else { return text }
            return String(text[text.index(after: separator)...])
        }
        return cleaned.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
