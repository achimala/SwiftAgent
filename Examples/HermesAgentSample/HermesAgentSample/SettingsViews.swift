import SwiftAgent
import SwiftAgentFoundationModels
import SwiftAgentMLX
import SwiftUI

struct SettingsView: View {
    @Binding var provider: String
    @Binding var baseURL: String
    @Binding var apiKey: String
    @Binding var model: String
    @Binding var mlxModel: String
    @Binding var mlxMaxTokens: Int
    @Binding var mlxTemperature: Double
    @Binding var enableSoul: Bool
    @Binding var enableContext: Bool
    @Binding var enableMemory: Bool

    @Environment(\.dismiss) private var dismiss

    private var hermesHome: URL? {
        try? HermesAgent.defaultHome()
    }

    private var workspace: URL? {
        try? HermesAgent.defaultWorkspace()
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Provider") {
                    Picker("Provider", selection: $provider) {
                        Text("Hosted").tag("hermes")
                        Text("Offline MLX").tag("mlx")
                        Text("Apple").tag("foundation")
                    }
                    .pickerStyle(.segmented)
                }

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
                .disabled(provider != "hermes")

                if provider == "mlx" || provider == "foundation" {
                    Section(provider == "foundation" ? "Apple On-Device" : "Offline MLX") {
                        if provider == "mlx" {
                            TextField("Model ID", text: $mlxModel)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        } else {
                            LabeledContent("Model", value: "Foundation Models")
                        }

                        Stepper("Max tokens: \(mlxMaxTokens)", value: $mlxMaxTokens, in: 16...2048, step: 16)

                        HStack {
                            Text("Temperature")
                            Slider(value: $mlxTemperature, in: 0...1, step: 0.05)
                            Text(mlxTemperature, format: .number.precision(.fractionLength(2)))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
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
                                placeholder: "Describe the agent identity and style SwiftAgent should use."
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
                                placeholder: "Workspace-specific instructions SwiftAgent should follow in this iOS sandbox."
                            )
                        } label: {
                            Label("Edit AGENTS.md", systemImage: "doc.text")
                        }
                    }
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

struct SessionsView: View {
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
                            description: Text("Chats will appear here after SwiftAgent stores them.")
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
