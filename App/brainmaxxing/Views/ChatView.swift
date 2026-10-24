import DigestCore
import SwiftUI

/// The chat inspector: one conversation per open digest plus "General".
struct ChatView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let chat = app.chat
        VStack(spacing: 0) {
            ChatHeader(chat: chat)
            Divider()
            ChatTranscript(chat: chat)
            if let error = chat.currentError {
                ChatErrorBanner(message: error) { chat.dismissError() }
            }
            Divider()
            ChatComposer(chat: chat)
        }
    }
}

private struct ChatHeader: View {
    @Bindable var chat: ChatModel

    var body: some View {
        HStack(spacing: 8) {
            Picker("Conversation", selection: Binding(get: { chat.scope }, set: { scope in Task { await chat.show(scope) } })) {
                if let date = chat.digestDate {
                    Text("Digest \(date)").tag(ChatScope.digest(date))
                }
                Text("General").tag(ChatScope.general)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .fixedSize()
            Spacer(minLength: 0)
            Picker("Model", selection: Binding(get: { chat.model }, set: { chat.modelOverride = $0 })) {
                ForEach(ChatModel.modelChoices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .help("Model for this chat (the default is set in Settings)")
        }
        .padding(10)
    }
}

private struct ChatTranscript: View {
    let chat: ChatModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if chat.transcript.isEmpty && chat.currentPending == nil {
                        Text("Ask about this digest, or select text in it and click \"Ask about this\" (⌘⇧L) to quote it.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(chat.transcript) { message in
                        switch message.role {
                        case .user: UserMessageView(text: message.content, quotes: message.quotes)
                        default:
                            AssistantMessageView(text: message.content,
                                                 tools: message.toolCalls.enumerated().map { ToolCallRow($1, id: $0) },
                                                 model: message.model, streaming: false)
                        }
                    }
                    if let turn = chat.currentPending {
                        UserMessageView(text: turn.text, quotes: turn.quotes)
                        AssistantMessageView(text: turn.answer, tools: turn.tools, model: nil, streaming: true)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
                .textSelection(.enabled)
            }
            .onChange(of: chat.currentPending?.answer) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onChange(of: chat.messages.count) { proxy.scrollTo("bottom", anchor: .bottom) }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
    }
}

private struct UserMessageView: View {
    let text: String
    let quotes: [Quote]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(quotes.enumerated()), id: \.offset) { _, quote in
                QuoteBlock(quote: quote, onRemove: nil)
            }
            if !text.isEmpty { Text(text) }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct AssistantMessageView: View {
    let text: String
    let tools: [ToolCallRow]
    let model: String?
    let streaming: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(tools) { ToolCallView(row: $0) }
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                switch block {
                case let .prose(prose):
                    Text(ChatMarkdown.attributed(prose))
                case let .code(code):
                    ScrollView(.horizontal) {
                        Text(code).font(.system(.callout, design: .monospaced)).padding(8)
                    }
                    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            if streaming && text.isEmpty && tools.allSatisfy({ $0.summary != nil }) {
                ProgressView().controlSize(.small)
            }
            if let model {
                Text(model).font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Collapsed "searched arXiv: ..."; expands to the one-line result summary.
private struct ToolCallView: View {
    let row: ToolCallRow
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            Text(row.summary ?? "running...")
                .font(.caption.monospaced())
                .foregroundStyle(row.isError ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            HStack(spacing: 6) {
                if row.summary == nil {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: row.isError ? "exclamationmark.triangle" : "wrench.and.screwdriver")
                        .foregroundStyle(row.isError ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                Text(row.label).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }
}

private struct ChatErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.callout).textSelection(.enabled)
                if APIKeyMessage.offersSettings(message) {
                    SettingsLink { Text("Open Settings...") }.controlSize(.small)
                }
            }
            Spacer(minLength: 0)
            Button("Dismiss", systemImage: "xmark", action: onDismiss)
                .labelStyle(.iconOnly).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.orange.opacity(0.12))
    }
}

private struct ChatComposer: View {
    @Bindable var chat: ChatModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(chat.quotes.enumerated()), id: \.offset) { index, quote in
                QuoteBlock(quote: quote) { chat.removeQuote(at: index) }
            }
            HStack(alignment: .bottom, spacing: 8) {
                TextField(chat.quotes.isEmpty ? "Ask..." : "Ask about the quotes...", text: $chat.draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(1...8)
                    .onSubmit { chat.send() }
                Button("Send", systemImage: "arrow.up.circle.fill") { chat.send() }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title2)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(!chat.canSend)
            }
        }
        .padding(10)
    }
}

/// A quoted fragment: paper title, arXiv id, text. Removable in the composer, fixed in sent messages.
struct QuoteBlock: View {
    let quote: Quote
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(.tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 4) {
                Text(quote.title).font(.caption.bold()).lineLimit(2)
                if !quote.paperID.isEmpty { Text(quote.paperID).font(.caption2.monospaced()).foregroundStyle(.secondary) }
                Text(quote.text).font(.callout).lineLimit(8).textSelection(.enabled)
            }
            Spacer(minLength: 0)
            if let onRemove {
                Button("Remove quote", systemImage: "xmark.circle.fill", action: onRemove)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}
