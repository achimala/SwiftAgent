import SwiftUI

struct ChatRow: View {
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
        .background(background, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
        case .tool, .reasoning:
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
        case .reasoning:
            Color(uiColor: .tertiarySystemBackground)
        }
    }

    private var foreground: Color {
        entry.kind == .error ? .red : .primary
    }

    private var textFont: Font {
        switch entry.kind {
        case .reasoning:
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
