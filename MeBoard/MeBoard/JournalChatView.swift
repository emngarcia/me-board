//
//  JournalChatView.swift
//  MeBoard
//

import SwiftUI
import SwiftData
import Combine

// MARK: - Chat Message Model (local)

struct ChatMessage: Identifiable, Equatable {
    let id: String
    let role: String
    let content: String

    var isUser: Bool { role == "user" }
}

// MARK: - Chat View Model

@MainActor
class JournalChatViewModel: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    private(set) var conversationId: String?

    private let api = ChatAPI.shared

    /// Start a new conversation from a journal entry
    func startConversation(title: String?, content: String) async {
        isLoading = true
        errorMessage = nil

        messages.append(ChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: content
        ))

        do {
            let response = try await api.startConversation(title: nil, content: content)

            if response.ok, let convoId = response.conversationId, let reply = response.reply {
                conversationId = convoId
                messages.append(ChatMessage(
                    id: UUID().uuidString,
                    role: "assistant",
                    content: reply
                ))
            } else {
                errorMessage = response.error ?? "Something went wrong"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Send a follow-up message
    func sendMessage(_ text: String) async {
        guard let convoId = conversationId else { return }

        isLoading = true
        errorMessage = nil

        messages.append(ChatMessage(
            id: UUID().uuidString,
            role: "user",
            content: text
        ))

        do {
            let response = try await api.sendReply(conversationId: convoId, message: text)

            if response.ok, let reply = response.reply {
                messages.append(ChatMessage(
                    id: UUID().uuidString,
                    role: "assistant",
                    content: reply
                ))
            } else {
                errorMessage = response.error ?? "Something went wrong"
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Load existing conversation history
    func loadHistory(conversationId: String) async {
        self.conversationId = conversationId
        isLoading = true

        do {
            let response = try await api.fetchHistory(conversationId: conversationId)

            if response.ok, let msgs = response.messages {
                messages = msgs
                    .filter { $0.role != "system" }
                    .map { ChatMessage(id: $0.id, role: $0.role, content: $0.content) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

// MARK: - Journal Chat View

struct JournalChatView: View {
    @StateObject private var viewModel = JournalChatViewModel()
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @FocusState private var inputFocused: Bool

    @State private var inputText = ""

    let journalTitle: String?
    let journalContent: String
    let existingConversationId: String?

    /// Optional: pass the JournalEntry so we can store the conversationId back
    var entry: JournalEntry?

    init(
        journalTitle: String?,
        journalContent: String,
        existingConversationId: String? = nil,
        entry: JournalEntry? = nil
    ) {
        self.journalTitle = journalTitle
        self.journalContent = journalContent
        self.existingConversationId = existingConversationId
        self.entry = entry
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            messageBubble(message)
                                .id(message.id)
                        }

                        if viewModel.isLoading {
                            typingIndicator
                                .id("typing")
                        }
                    }
                    .padding()
                }
                .onChange(of: viewModel.messages.count) { _, _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: viewModel.isLoading) { _, loading in
                    if loading { scrollToBottom(proxy) }
                }
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
                    .padding(.bottom, 4)
            }

            Divider().overlay(Color.earthSage.opacity(0.3))

            inputBar
        }
        .background(Color.earthSand)
        .navigationTitle("Reflect")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(Color.earthAccent)
            }
        }
        .task {
            if let convoId = existingConversationId {
                await viewModel.loadHistory(conversationId: convoId)
            } else {
                await viewModel.startConversation(title: journalTitle, content: journalContent)
                // Store the conversationId back to the JournalEntry
                if let convoId = viewModel.conversationId, let entry = entry {
                    entry.conversationId = convoId
                    try? modelContext.save()
                }
            }
        }
    }

    // MARK: - Scroll Helper

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        withAnimation {
            if let lastId = viewModel.messages.last?.id {
                proxy.scrollTo(lastId, anchor: .bottom)
            } else if viewModel.isLoading {
                proxy.scrollTo("typing", anchor: .bottom)
            }
        }
    }

    // MARK: - Message Bubble

    private func messageBubble(_ message: ChatMessage) -> some View {
        HStack {
            if message.isUser { Spacer(minLength: 48) }

            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                if !message.isUser {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.earthAccent)
                            .frame(width: 14, height: 14)
                        Text("Milo")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(Color.earthSage)
                    }
                }

                Text(message.content)
                    .font(.subheadline)
                    .foregroundStyle(message.isUser ? .white : Color.earthBark)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        message.isUser
                            ? Color.earthAccent
                            : Color.earthCard
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }

            if !message.isUser { Spacer(minLength: 48) }
        }
    }

    // MARK: - Typing Indicator

    private var typingIndicator: some View {
        HStack {
            HStack(spacing: 4) {
                ForEach(0..<3, id: \.self) { i in
                    Circle()
                        .fill(Color.earthSage)
                        .frame(width: 6, height: 6)
                        .opacity(0.6)
                        .animation(
                            .easeInOut(duration: 0.5)
                                .repeatForever()
                                .delay(Double(i) * 0.15),
                            value: viewModel.isLoading
                        )
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color.earthCard)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Spacer()
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Say something…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.subheadline)
                .lineLimit(1...5)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.earthCard)
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .focused($inputFocused)

            Button {
                let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return }
                inputText = ""
                Task { await viewModel.sendMessage(text) }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
                    .foregroundStyle(
                        inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.earthStone
                            : Color.earthAccent
                    )
            }
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.earthSand)
    }
}
