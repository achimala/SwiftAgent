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
        case reasoning
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

private struct TimingEvent: Decodable {
    let label: String
    let elapsedMs: Double
    let detail: String?

    enum CodingKeys: String, CodingKey {
        case label
        case elapsedMs = "elapsed_ms"
        case detail
    }
}

private struct HermesChatResult: Decodable {
    let finalResponse: String?
    let lastReasoning: String?
    let error: String?
    let reasoningTokens: Int?

    enum CodingKeys: String, CodingKey {
        case finalResponse = "final_response"
        case lastReasoning = "last_reasoning"
        case error
        case reasoningTokens = "reasoning_tokens"
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
    @AppStorage("hermes.enableSoul") private var enableSoul = true
    @AppStorage("hermes.enableContext") private var enableContext = true
    @AppStorage("hermes.enableMemory") private var enableMemory = true

    @State private var draft = "Create a file named hello.txt that says hello from Hermes, then read it back."
    @State private var entries: [ChatEntry] = Self.welcomeEntries()
    @State private var isRunning = false
    @State private var showingSettings = false
    @State private var showingSessions = false
    @State private var sessions: [HermesSessionSummary] = []
    @State private var currentSessionID: String?
    @State private var timingEvents: [UUID: [TimingEvent]] = [:]
    @State private var activeReasoningEntries: [UUID: UUID] = [:]
    @State private var assistantIDsWithReasoning: Set<UUID> = []
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
                        refreshSessions()
                        showingSessions = true
                    } label: {
                        Image(systemName: "sidebar.left")
                    }
                    .disabled(isRunning)
                    .accessibilityLabel("Sessions")
                }

                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 14) {
                        Button {
                            createNewSession()
                        } label: {
                            Image(systemName: "plus")
                        }
                        .disabled(isRunning)
                        .accessibilityLabel("New chat")

                        Button {
                            showingSettings = true
                        } label: {
                            Image(systemName: "gearshape")
                        }
                        .accessibilityLabel("Settings")
                    }
                }
            }
            .task {
                loadCurrentSession()
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView(
                    baseURL: $baseURL,
                    apiKey: $apiKey,
                    model: $model,
                    enableSoul: $enableSoul,
                    enableContext: $enableContext,
                    enableMemory: $enableMemory,
                    isRunning: isRunning,
                    onShellProbe: runShellProbe,
                    onHermesProbe: runProbe
                )
            }
            .sheet(isPresented: $showingSessions) {
                SessionsView(
                    sessions: sessions,
                    currentSessionID: currentSessionID,
                    isRunning: isRunning,
                    onRefresh: refreshSessions,
                    onNewSession: {
                        showingSessions = false
                        createNewSession()
                    },
                    onSelect: { session in
                        showingSessions = false
                        loadSession(session.id)
                    }
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
        HermesChatConfiguration(
            baseURL: baseURL,
            apiKey: apiKey,
            model: model,
            enableSoul: enableSoul,
            enableContext: enableContext,
            enableMemory: enableMemory
        )
    }

    private var hermesPath: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("PythonApp", isDirectory: true)
            .appendingPathComponent("hermes", isDirectory: true)
    }

    private static func welcomeEntries() -> [ChatEntry] {
        [
            ChatEntry(
                kind: .assistant,
                title: "Hermes",
                body: "Ready. Configure a model and API key in settings, then send a message.",
                isStreaming: false
            ),
        ]
    }

    private func loadCurrentSession() {
        guard let hermesPath else { return }
        Task.detached {
            do {
                let state = try HermesAgentRuntime.shared.sessionState(hermesSourcePath: hermesPath)
                await MainActor.run {
                    applySessionState(state, renderTranscript: true)
                }
            } catch {
                await MainActor.run {
                    _ = append(.error, title: "Session Error", body: String(describing: error))
                }
            }
        }
    }

    private func refreshSessions() {
        guard let hermesPath else { return }
        Task.detached {
            do {
                let state = try HermesAgentRuntime.shared.sessionState(hermesSourcePath: hermesPath)
                await MainActor.run {
                    applySessionState(state, renderTranscript: false)
                }
            } catch {
                await MainActor.run {
                    _ = append(.error, title: "Session Error", body: String(describing: error))
                }
            }
        }
    }

    private func loadSession(_ sessionID: String) {
        guard let hermesPath else { return }
        isRunning = true
        Task.detached {
            do {
                let state = try HermesAgentRuntime.shared.loadSession(sessionID, hermesSourcePath: hermesPath)
                await MainActor.run {
                    applySessionState(state, renderTranscript: true)
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    append(.error, title: "Session Error", body: String(describing: error))
                    isRunning = false
                }
            }
        }
    }

    private func createNewSession() {
        guard let hermesPath else { return }
        isRunning = true
        Task.detached {
            do {
                let state = try HermesAgentRuntime.shared.newSession(hermesSourcePath: hermesPath)
                await MainActor.run {
                    applySessionState(state, renderTranscript: true)
                    draft = ""
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    append(.error, title: "Session Error", body: String(describing: error))
                    isRunning = false
                }
            }
        }
    }

    @MainActor
    private func applySessionState(_ state: HermesSessionState, renderTranscript: Bool) {
        currentSessionID = state.currentSessionID
        sessions = state.sessions
        guard renderTranscript else { return }

        entries = entries(from: state.currentSession)
        timingEvents.removeAll()
        activeReasoningEntries.removeAll()
        assistantIDsWithReasoning.removeAll()
    }

    private func entries(from session: HermesSessionDetail?) -> [ChatEntry] {
        guard let session, !session.messages.isEmpty else {
            return Self.welcomeEntries()
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

        return rendered.isEmpty ? Self.welcomeEntries() : rendered
    }

    private func decodeToolArguments(_ text: String?) -> [String: JSONValue]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode([String: JSONValue].self, from: data)
    }

    private func persistedToolResultIsError(_ text: String) -> Bool {
        guard let value = decodeJSONValue(text), let object = value.objectValue else {
            return text.lowercased().contains("error")
        }
        if object["status"]?.stringValue == "error" {
            return true
        }
        if let success = object["success"], case .bool(false) = success {
            return true
        }
        return object["error"] != nil
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
                append(.debug, title: "Probe Output", body: Self.displayPreview(text))
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
                append(.debug, title: "Shell Output", body: Self.displayPreview(text))
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
        timingEvents[assistantID] = []
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
                    let result = chatResult(from: final)
                    finishAssistant(assistantID, fallback: finalResponse(from: result, raw: final))
                    appendFinalReasoning(result?.lastReasoning, assistantID: assistantID)
                    stopReasoningSpinner(for: assistantID)
                    appendTimingSummary(for: assistantID)
                    Self.writeProbeOutput(transcriptText)
                    isRunning = false
                }
            } catch {
                await MainActor.run {
                    finishAssistant(assistantID, fallback: "")
                    stopReasoningSpinner(for: assistantID)
                    append(.error, title: "Error", body: String(describing: error))
                    appendTimingSummary(for: assistantID)
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
            endActiveReasoningChunk(for: assistantID)
            appendToAssistant(assistantID, text: event.payload)
        case "interim":
            endActiveReasoningChunk(for: assistantID)
            append(.assistant, title: "Hermes", body: event.payload)
        case "reasoning_delta":
            appendReasoning(event.payload, assistantID: assistantID)
        case "tool_gen":
            endActiveReasoningChunk(for: assistantID)
        case "tool_start":
            endActiveReasoningChunk(for: assistantID)
            if let tool = decodeToolEvent(event.payload) {
                appendToolStart(tool)
            } else {
                append(.tool, title: "Running tool", body: event.payload)
            }
            moveEmptyAssistantToEnd(assistantID)
        case "tool_complete":
            endActiveReasoningChunk(for: assistantID)
            if let tool = decodeToolEvent(event.payload) {
                finishTool(tool)
            } else {
                append(.tool, title: "Tool finished", body: event.payload)
            }
            moveEmptyAssistantToEnd(assistantID)
        case "tool_progress":
            endActiveReasoningChunk(for: assistantID)
        case "timing":
            recordTiming(event.payload, assistantID: assistantID)
        case "done":
            stopAssistantSpinner(assistantID)
            stopReasoningSpinner(for: assistantID)
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

    private func recordTiming(_ payload: String, assistantID: UUID) {
        guard let data = payload.data(using: .utf8),
              let timing = try? JSONDecoder().decode(TimingEvent.self, from: data)
        else { return }
        timingEvents[assistantID, default: []].append(timing)
    }

    private func appendTimingSummary(for assistantID: UUID) {
        guard let timings = timingEvents.removeValue(forKey: assistantID), !timings.isEmpty else { return }
        let body = timings
            .map { timing in
                let detail = timing.detail.map { " \($0)" } ?? ""
                return "\(formatTimingLabel(timing.label)) \(formatElapsed(timing.elapsedMs))\(detail)"
            }
            .joined(separator: "\n")
        append(.debug, title: "Timing", body: body)
    }

    private func formatTimingLabel(_ label: String) -> String {
        label.replacingOccurrences(of: "_", with: " ")
    }

    private func formatElapsed(_ ms: Double) -> String {
        if ms >= 1000 {
            return String(format: "%.2fs", ms / 1000)
        }
        return "\(Int(ms.rounded()))ms"
    }

    private func appendToAssistant(_ id: UUID, text: String) {
        guard !text.isEmpty, let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].body += text
    }

    private func appendReasoning(_ text: String, assistantID: UUID) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        assistantIDsWithReasoning.insert(assistantID)

        if let reasoningID = activeReasoningEntries[assistantID],
           let index = entries.firstIndex(where: { $0.id == reasoningID }) {
            entries[index].body += text
            entries[index].isStreaming = true
            return
        }

        let reasoningID = append(
            .reasoning,
            title: "Reasoning summary",
            body: text.trimmingCharacters(in: .whitespacesAndNewlines),
            isStreaming: true
        )
        activeReasoningEntries[assistantID] = reasoningID
        moveEmptyAssistantToEnd(assistantID)
    }

    private func appendFinalReasoning(_ text: String?, assistantID: UUID) {
        let cleaned = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleaned.isEmpty, !assistantIDsWithReasoning.contains(assistantID) else { return }

        if let reasoningID = activeReasoningEntries[assistantID],
           let index = entries.firstIndex(where: { $0.id == reasoningID }) {
            entries[index].body = cleaned
            entries[index].isStreaming = false
            return
        }

        let entry = ChatEntry(
            kind: .reasoning,
            title: "Reasoning summary",
            body: cleaned,
            isStreaming: false
        )
        if let assistantIndex = entries.firstIndex(where: { $0.id == assistantID }) {
            entries.insert(entry, at: assistantIndex)
        } else {
            entries.append(entry)
        }
        activeReasoningEntries[assistantID] = entry.id
        assistantIDsWithReasoning.insert(assistantID)
    }

    private func stopReasoningSpinner(for assistantID: UUID) {
        guard let reasoningID = activeReasoningEntries[assistantID],
              let index = entries.firstIndex(where: { $0.id == reasoningID })
        else { return }
        entries[index].isStreaming = false
        activeReasoningEntries.removeValue(forKey: assistantID)
    }

    private func endActiveReasoningChunk(for assistantID: UUID) {
        stopReasoningSpinner(for: assistantID)
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

    private func chatResult(from raw: String) -> HermesChatResult? {
        guard let data = raw.data(using: .utf8),
              let result = try? JSONDecoder().decode(HermesChatResult.self, from: data)
        else { return nil }
        return result
    }

    private func finalResponse(from result: HermesChatResult?, raw: String) -> String {
        if let response = result?.finalResponse {
            return response.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let error = result?.error, !error.isEmpty {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var transcriptText: String {
        entries.map { entry in
            var parts = ["\(entry.title)\n\(entry.body)"]
            if let input = entry.toolInput, !input.isEmpty {
                parts.append("Input\n\(input)")
            }
            if let output = entry.toolOutput, !output.isEmpty {
                parts.append("Output\n\(output)")
            }
            return parts.joined(separator: "\n\n")
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

    nonisolated private static func displayPreview(_ text: String, limit: Int = 20_000) -> String {
        guard text.count > limit else { return text }
        let index = text.index(text.startIndex, offsetBy: limit)
        return String(text[..<index]) + "\n\n... truncated in UI; full output was written to hermes-probe-output.txt"
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
        case .tool, .debug, .reasoning:
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
        case .reasoning:
            Color(uiColor: .tertiarySystemBackground)
        }
    }

    private var foreground: Color {
        entry.kind == .error ? .red : .primary
    }

    private var textFont: Font {
        switch entry.kind {
        case .debug, .reasoning:
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
        case .reasoning:
            "brain.head.profile"
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
    @Binding var enableSoul: Bool
    @Binding var enableContext: Bool
    @Binding var enableMemory: Bool
    let isRunning: Bool
    let onShellProbe: () -> Void
    let onHermesProbe: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var hermesHome: URL? {
        try? HermesAgentRuntime.defaultHermesHome()
    }

    private var workspace: URL? {
        try? HermesAgentRuntime.defaultWorkspace()
    }

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

                Section("Agent State") {
                    Toggle("Soul", isOn: $enableSoul)
                    Toggle("Workspace context", isOn: $enableContext)
                    Toggle("Persistent memory", isOn: $enableMemory)
                }

                Section("Files") {
                    if let hermesHome {
                        NavigationLink {
                            FileEditorView(
                                title: "SOUL.md",
                                url: hermesHome.appendingPathComponent("SOUL.md"),
                                placeholder: "Describe the agent identity and style Hermes should use."
                            )
                        } label: {
                            Label("Edit SOUL.md", systemImage: "person.text.rectangle")
                        }

                        NavigationLink {
                            FileEditorView(
                                title: "MEMORY.md",
                                url: hermesHome
                                    .appendingPathComponent("memories", isDirectory: true)
                                    .appendingPathComponent("MEMORY.md"),
                                placeholder: "Durable agent notes, separated by a line containing §."
                            )
                        } label: {
                            Label("Edit MEMORY.md", systemImage: "brain.head.profile")
                        }

                        NavigationLink {
                            FileEditorView(
                                title: "USER.md",
                                url: hermesHome
                                    .appendingPathComponent("memories", isDirectory: true)
                                    .appendingPathComponent("USER.md"),
                                placeholder: "Durable user profile entries, separated by a line containing §."
                            )
                        } label: {
                            Label("Edit USER.md", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }

                    if let workspace {
                        NavigationLink {
                            FileEditorView(
                                title: "AGENTS.md",
                                url: workspace.appendingPathComponent("AGENTS.md"),
                                placeholder: "Workspace-specific instructions Hermes should follow in this iOS sandbox."
                            )
                        } label: {
                            Label("Edit AGENTS.md", systemImage: "doc.text")
                        }
                    }
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

private struct SessionsView: View {
    let sessions: [HermesSessionSummary]
    let currentSessionID: String?
    let isRunning: Bool
    let onRefresh: () -> Void
    let onNewSession: () -> Void
    let onSelect: (HermesSessionSummary) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        onNewSession()
                    } label: {
                        Label("New Chat", systemImage: "plus.circle")
                    }
                    .disabled(isRunning)
                }

                Section("Past Sessions") {
                    if sessions.isEmpty {
                        ContentUnavailableView(
                            "No Sessions",
                            systemImage: "bubble.left.and.bubble.right",
                            description: Text("Chats will appear here after Hermes stores them.")
                        )
                    } else {
                        ForEach(sessions) { session in
                            Button {
                                onSelect(session)
                            } label: {
                                SessionRow(
                                    session: session,
                                    isCurrent: session.id == currentSessionID
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(isRunning)
                        }
                    }
                }
            }
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable {
                onRefresh()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        onRefresh()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(isRunning)
                    .accessibilityLabel("Refresh sessions")
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: HermesSessionSummary
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isCurrent ? "checkmark.circle.fill" : "bubble.left")
                .font(.title3)
                .foregroundStyle(isCurrent ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.headline)
                        .lineLimit(1)

                    if session.endedAt != nil {
                        Text("Ended")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(uiColor: .tertiarySystemBackground))
                            .clipShape(Capsule())
                            .foregroundStyle(.secondary)
                    }
                }

                if !session.preview.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(session.preview)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                HStack(spacing: 8) {
                    Text("\(session.messageCount) messages")
                    if !session.model.isEmpty {
                        Text(session.model)
                    }
                    if let updated = session.lastActive ?? session.startedAt {
                        Text(shortTimestamp(updated))
                    }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private var title: String {
        let explicit = session.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !explicit.isEmpty {
            return explicit
        }
        let preview = session.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if !preview.isEmpty {
            return preview
        }
        return "Untitled Chat"
    }

    private func shortTimestamp(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = Double(trimmed) {
            let date = Date(timeIntervalSince1970: seconds)
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        if let date = Self.isoFormatter.date(from: trimmed) ?? Self.isoFormatterWithoutFractions.date(from: trimmed) {
            return Self.relativeFormatter.localizedString(for: date, relativeTo: Date())
        }
        guard trimmed.count > 19 else { return trimmed }
        return String(trimmed.prefix(19)).replacingOccurrences(of: "T", with: " ")
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatterWithoutFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()
}

private struct FileEditorView: View {
    let title: String
    let url: URL
    let placeholder: String

    @State private var text = ""
    @State private var status = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .overlay(alignment: .topLeading) {
                    if text.isEmpty {
                        Text(placeholder)
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 10)
                            .allowsHitTesting(false)
                    }
                }

            if !status.isEmpty {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") {
                    save()
                }
            }
        }
        .onAppear(perform: load)
    }

    private func load() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: url.path) {
                text = try String(contentsOf: url, encoding: .utf8)
            }
            status = url.path
        } catch {
            status = String(describing: error)
        }
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try text.write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(url.lastPathComponent)"
        } catch {
            status = String(describing: error)
        }
    }
}
