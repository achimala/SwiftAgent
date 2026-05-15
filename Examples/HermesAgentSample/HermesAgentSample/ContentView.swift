import HermesAgentKit
import SwiftUI

private struct ChatEntry: Identifiable, Equatable {
    enum Kind: String {
        case assistant
        case user
        case tool
        case status
        case error
        case debug
    }

    let id = UUID()
    var kind: Kind
    var title: String
    var body: String
    var isStreaming = false
    var toolCallID: String?
    var toolName: String?
    var toolInput: String?
    var toolOutput: String?
    var toolSucceeded: Bool?
}

private struct ToolEvent: Decodable {
    let id: String?
    let name: String?
    let args: [String: JSONValue]?
    let ok: Bool?
    let resultPreview: String?
    let status: String?
    let preview: String?
    let duration: Double?
    let isError: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case args
        case ok
        case resultPreview = "result_preview"
        case status
        case preview
        case duration
        case isError = "is_error"
    }
}

private enum JSONValue: Decodable, Equatable, CustomStringConvertible {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            self = .array(try container.decode([JSONValue].self))
        }
    }

    var stringValue: String? {
        if case .string(let value) = self {
            return value
        }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let value) = self {
            return value
        }
        return nil
    }

    var intValue: Int? {
        if case .number(let value) = self {
            return Int(value)
        }
        return nil
    }

    var description: String {
        switch self {
        case .string(let value):
            value
        case .number(let value):
            value.rounded() == value ? String(Int(value)) : String(value)
        case .bool(let value):
            String(value)
        case .object(let value):
            value.map { "\($0.key): \($0.value)" }.sorted().joined(separator: ", ")
        case .array(let value):
            value.map(\.description).joined(separator: ", ")
        case .null:
            "null"
        }
    }
}

struct ContentView: View {
    @AppStorage("hermes.baseURL") private var baseURL = "https://api.openai.com/v1"
    @AppStorage("hermes.apiKey") private var apiKey = ""
    @AppStorage("hermes.model") private var model = "gpt-4.1-mini"

    @State private var draft = "Create a file named hello.txt that says hello from Hermes, then read it back."
    @State private var entries: [ChatEntry] = [
        ChatEntry(
            kind: .assistant,
            title: "Hermes",
            body: "Ready. Configure a model and API key in settings, then send a message.",
            isStreaming: false
        ),
    ]
    @State private var isRunning = false
    @State private var showingSettings = false
    @FocusState private var draftFocused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                transcript
                composer
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle("Hermes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        runProbe()
                    } label: {
                        Image(systemName: "bolt.circle")
                    }
                    .disabled(isRunning)
                    .accessibilityLabel("Run probe")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    baseURL: $baseURL,
                    apiKey: $apiKey,
                    model: $model,
                    isRunning: isRunning,
                    onShellProbe: runShellProbe,
                    onHermesProbe: runProbe
                )
            }
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(entries) { entry in
                        ChatRow(entry: entry)
                            .id(entry.id)
                    }
                    Color.clear
                        .frame(height: 1)
                        .id("bottom")
                }
                .padding(.top, 28)
                .padding(.bottom, 12)
            }
            .onChange(of: entries) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Message Hermes", text: $draft, axis: .vertical)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .focused($draftFocused)
                    .disabled(isRunning)

                Button {
                    sendMessage()
                } label: {
                    Image(systemName: isRunning ? "stop.circle.fill" : "arrow.up.circle.fill")
                        .font(.system(size: 32, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                }
                .disabled(isRunning || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)
        }
        .background(.bar)
    }

    private var configuration: HermesChatConfiguration {
        HermesChatConfiguration(baseURL: baseURL, apiKey: apiKey, model: model)
    }

    private var hermesPath: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("PythonApp", isDirectory: true)
            .appendingPathComponent("hermes", isDirectory: true)
    }

    private func runProbe() {
        let path = hermesPath
        isRunning = true
        append(.status, title: "Probe", body: "Starting embedded Python and Hermes...")

        Task.detached {
            let text: String
            do {
                let result = try HermesAgentRuntime.shared.probe(hermesSourcePath: path)
                let toolProbe = try HermesAgentRuntime.shared.toolProbe(hermesSourcePath: path)
                text = """
                PYTHON
                \(result.python)

                HERMES
                \(result.hermes)

                HERMES TOOL DISPATCH
                \(toolProbe)
                """
            } catch {
                text = String(describing: error)
            }

            Self.writeProbeOutput(text)

            await MainActor.run {
                append(.debug, title: "Probe Output", body: text)
                isRunning = false
            }
        }
    }

    private func runShellProbe() {
        isRunning = true
        append(.status, title: "Shell", body: "Running embedded shell smoke test...")

        Task.detached {
            let text: String
            do {
                text = try HermesShellRuntime.shared.smokeTest()
            } catch {
                text = String(describing: error)
            }

            Self.writeProbeOutput(text)

            await MainActor.run {
                append(.debug, title: "Shell Output", body: text)
                isRunning = false
            }
        }
    }

    private func sendMessage() {
        guard let hermesPath else {
            append(.error, title: "Missing Hermes", body: "Bundled Hermes source was not found.")
            return
        }

        let userMessage = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userMessage.isEmpty else { return }

        draft = ""
        draftFocused = false
        append(.user, title: "You", body: userMessage)
        let assistantID = append(.assistant, title: "Hermes", body: "", isStreaming: true)
        let config = configuration
        isRunning = true

        Task.detached {
            do {
                let final = try HermesAgentRuntime.shared.chat(
                    message: userMessage,
                    configuration: config,
                    hermesSourcePath: hermesPath
                ) { event in
                    Task { @MainActor in
                        handle(event: event, assistantID: assistantID)
                    }
                }

                await MainActor.run {
                    finishAssistant(assistantID, fallback: finalResponse(from: final))
                    Self.writeProbeOutput(transcriptText)
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    finishAssistant(assistantID, fallback: "")
                    append(.error, title: "Error", body: String(describing: error))
                    Self.writeProbeOutput(transcriptText)
                    isRunning = false
                }
            }
        }
    }

    @discardableResult
    private func append(
        _ kind: ChatEntry.Kind,
        title: String,
        body: String,
        isStreaming: Bool = false
    ) -> UUID {
        let entry = ChatEntry(kind: kind, title: title, body: body, isStreaming: isStreaming)
        entries.append(entry)
        return entry.id
    }

    @MainActor
    private func handle(event: HermesChatEvent, assistantID: UUID) {
        switch event.kind {
        case "delta":
            appendToAssistant(assistantID, text: event.payload)
        case "interim":
            append(.assistant, title: "Hermes", body: event.payload)
        case "tool_gen":
            break
        case "tool_start":
            if let tool = decodeToolEvent(event.payload) {
                appendToolStart(tool)
            } else {
                append(.tool, title: "Running tool", body: event.payload)
            }
            moveEmptyAssistantToEnd(assistantID)
        case "tool_complete":
            if let tool = decodeToolEvent(event.payload) {
                finishTool(tool)
            } else {
                append(.tool, title: "Tool finished", body: event.payload)
            }
            moveEmptyAssistantToEnd(assistantID)
        case "tool_progress":
            break
        case "done":
            stopAssistantSpinner(assistantID)
        case "error":
            append(.error, title: "Hermes Error", body: event.payload)
        default:
            append(.status, title: event.kind, body: event.payload)
        }
    }

    private func moveEmptyAssistantToEnd(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let body = entries[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard entries[index].isStreaming, body.isEmpty, index != entries.index(before: entries.endIndex) else { return }
        let entry = entries.remove(at: index)
        entries.append(entry)
    }

    private func appendToolStart(_ tool: ToolEvent) {
        let name = tool.name ?? "tool"
        let input = formatToolInput(tool)
        let entry = ChatEntry(
            kind: .tool,
            title: displayToolName(name),
            body: "",
            isStreaming: true,
            toolCallID: tool.id,
            toolName: name,
            toolInput: input.isEmpty ? nil : input,
            toolOutput: nil,
            toolSucceeded: nil
        )
        entries.append(entry)
    }

    private func finishTool(_ tool: ToolEvent) {
        let name = tool.name ?? "tool"
        let output = formatToolResult(tool)
        let ok = tool.ok ?? true
        if let id = tool.id, let index = entries.lastIndex(where: { $0.toolCallID == id }) {
            entries[index].title = displayToolName(name)
            entries[index].toolName = name
            entries[index].toolOutput = output
            entries[index].toolSucceeded = ok
            entries[index].isStreaming = false
            return
        }

        let entry = ChatEntry(
            kind: .tool,
            title: displayToolName(name),
            body: "",
            isStreaming: false,
            toolCallID: tool.id,
            toolName: name,
            toolInput: nil,
            toolOutput: output,
            toolSucceeded: ok
        )
        entries.append(entry)
    }

    private func appendToAssistant(_ id: UUID, text: String) {
        guard !text.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].body += text
    }

    private func finishAssistant(_ id: UUID, fallback: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        if entries[index].body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            entries[index].body = fallback.isEmpty ? "(no response text)" : fallback
        } else {
            entries[index].body = entries[index].body.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        entries[index].isStreaming = false
    }

    private func stopAssistantSpinner(_ id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isStreaming = false
    }

    private func decodeToolEvent(_ payload: String) -> ToolEvent? {
        guard let data = payload.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ToolEvent.self, from: data)
    }

    private func formatArgs(_ args: [String: JSONValue]?) -> String {
        guard let args, !args.isEmpty else { return "" }
        if let command = args["command"] {
            return "$ \(command)"
        }
        if let path = args["path"] {
            return String(describing: path)
        }
        return args.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
    }

    private func formatToolInput(_ tool: ToolEvent) -> String {
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

        default:
            return formatArgs(args)
        }
    }

    private func displayToolName(_ name: String) -> String {
        name.replacingOccurrences(of: "_", with: " ")
    }

    private func displayPath(_ path: String) -> String {
        if path.contains("/Containers/Data/Application/") {
            return URL(fileURLWithPath: path).lastPathComponent
        }
        return path
    }


    private func formatToolResult(_ tool: ToolEvent) -> String {
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
            if let stdout = object["stdout"]?.stringValue, !stdout.isEmpty {
                parts.append(stdout)
            }
            if let stderr = object["stderr"]?.stringValue, !stderr.isEmpty {
                parts.append(stderr)
            }
            return parts.isEmpty ? "Command finished" : parts.joined(separator: "\n\n")

        default:
            return object.map { "\($0.key): \($0.value)" }.sorted().joined(separator: "\n")
        }
    }

    private func decodeJSONValue(_ text: String) -> JSONValue? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    private func cleanReadFileContent(_ content: String) -> String {
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

    private func finalResponse(from raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return raw.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let response = object["final_response"] as? String {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = object["error"] as? String, !error.isEmpty {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcriptText: String {
        entries.map { entry in
            "\(entry.title)\n\(entry.body)"
        }
        .joined(separator: "\n\n")
    }

    nonisolated private static func writeProbeOutput(_ text: String) {
        do {
            let documents = try FileManager.default.url(
                for: .documentDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let url = documents.appendingPathComponent("hermes-probe-output.txt")
            try text.write(to: url, atomically: true, encoding: .utf8)
            NSLog("Hermes probe output written to %@", url.path)
        } catch {
            NSLog("Failed to write Hermes probe output: %@", String(describing: error))
        }
    }
}

private struct ChatRow: View {
    let entry: ChatEntry

    var body: some View {
        HStack(alignment: .top) {
            if entry.kind == .user {
                Spacer(minLength: 44)
                bubble
            } else {
                bubble
                Spacer(minLength: 44)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 8) {
            if entry.kind == .tool {
                toolContent
            } else {
                header
                Text(entry.body.isEmpty ? " " : entry.body)
                    .font(textFont)
                    .textSelection(.enabled)
                    .foregroundStyle(foreground)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .background(background)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .frame(maxWidth: maxWidth, alignment: entry.kind == .user ? .trailing : .leading)
    }

    @ViewBuilder
    private var header: some View {
        if entry.kind != .assistant, entry.kind != .user {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.caption)
                    .foregroundStyle(iconColor)
                Text(entry.title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if entry.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }
        } else if entry.isStreaming {
            ProgressView()
                .controlSize(.small)
        }
    }

    private var toolContent: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: toolIconName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(toolIconColor)
                Text(toolTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if entry.isStreaming {
                    ProgressView()
                        .controlSize(.mini)
                }
            }

            if let input = entry.toolInput, !input.isEmpty {
                toolSection("Input", text: input)
            }

            if let output = entry.toolOutput, !output.isEmpty {
                if entry.toolInput?.isEmpty == false {
                    Divider()
                }
                toolSection("Output", text: output)
            }
        }
    }

    private func toolSection(_ title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(text)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var maxWidth: CGFloat {
        switch entry.kind {
        case .user:
            330
        case .tool, .debug:
            520
        default:
            620
        }
    }

    private var background: Color {
        switch entry.kind {
        case .user:
            Color(uiColor: .secondarySystemBackground)
        case .assistant:
            Color.clear
        case .tool:
            Color(uiColor: .secondarySystemBackground)
        case .status:
            Color(uiColor: .secondarySystemBackground).opacity(0.7)
        case .error:
            Color.red.opacity(0.12)
        case .debug:
            Color(uiColor: .secondarySystemBackground)
        }
    }

    private var foreground: Color {
        entry.kind == .error ? .red : .primary
    }

    private var textFont: Font {
        switch entry.kind {
        case .debug:
            .system(.footnote, design: .monospaced)
        default:
            .body
        }
    }

    private var horizontalPadding: CGFloat {
        entry.kind == .assistant ? 0 : 13
    }

    private var verticalPadding: CGFloat {
        entry.kind == .assistant ? 3 : 11
    }

    private var cornerRadius: CGFloat {
        entry.kind == .tool ? 12 : 16
    }

    private var toolTitle: String {
        let verb: String
        if entry.isStreaming {
            verb = "Running"
        } else if entry.toolSucceeded == false {
            verb = "Failed"
        } else {
            verb = "Used"
        }
        return "\(verb) \(entry.title)"
    }

    private var toolIconName: String {
        entry.toolSucceeded == false ? "exclamationmark.triangle" : "terminal"
    }

    private var toolIconColor: Color {
        entry.toolSucceeded == false ? .red : .secondary
    }

    private var iconName: String {
        switch entry.kind {
        case .assistant:
            "sparkles"
        case .tool:
            "terminal"
        case .status:
            "circle.dotted"
        case .error:
            "exclamationmark.triangle"
        case .debug:
            "doc.text.magnifyingglass"
        case .user:
            "person"
        }
    }

    private var iconColor: Color {
        switch entry.kind {
        case .error:
            .red
        case .tool:
            .blue
        default:
            .secondary
        }
    }
}

private struct SettingsView: View {
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var model: String
    let isRunning: Bool
    let onShellProbe: () -> Void
    let onHermesProbe: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    TextField("Base URL", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)

                    SecureField("API key", text: $apiKey)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    TextField("Model", text: $model)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }

                Section("Diagnostics") {
                    Button {
                        dismiss()
                        onHermesProbe()
                    } label: {
                        Label("Probe Hermes", systemImage: "bolt.circle")
                    }
                    .disabled(isRunning)

                    Button {
                        dismiss()
                        onShellProbe()
                    } label: {
                        Label("Probe Shell", systemImage: "terminal")
                    }
                    .disabled(isRunning)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}
