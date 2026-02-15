//
//  ChatAPI.swift
//  MeBoard
//

import Foundation

// MARK: - Response Models

struct PersonalizedMessageResponse: Decodable {
    let ok: Bool
    let personalized: Bool?
    let title: String?
    let body: String?
    let suggestion: String?
    let error: String?
}

struct ChatPromptResponse: Decodable {
    let ok: Bool
    let prompt: String?
    let error: String?
}

struct ChatStartResponse: Decodable {
    let ok: Bool
    let conversationId: String?
    let reply: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case conversationId = "conversation_id"
        case reply
        case error
    }
}

struct ChatReplyResponse: Decodable {
    let ok: Bool
    let conversationId: String?
    let reply: String?
    let error: String?

    enum CodingKeys: String, CodingKey {
        case ok
        case conversationId = "conversation_id"
        case reply
        case error
    }
}

struct ChatHistoryResponse: Decodable {
    let ok: Bool
    let messages: [ChatMessageDTO]?
    let error: String?
}

struct ChatMessageDTO: Decodable, Identifiable {
    let id: String
    let role: String
    let content: String
    let createdAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case role
        case content
        case createdAt = "created_at"
    }
}

// MARK: - Chat API Client

final class ChatAPI {
    static let shared = ChatAPI()

    private let functionURL = URL(
        string: "https://upkozoxjukgofgkidbyq.supabase.co/functions/v1/chat-journal"
    )!

    private let apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InVwa296b3hqdWtnb2Zna2lkYnlxIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NzEwOTk4NzMsImV4cCI6MjA4NjY3NTg3M30.xmzK9_5SIp8xoRDCxeOnqSS7bWNJus3Ofp2C0GynQoY"

    // MARK: - Fetch personalized dashboard message from today's keyboard events

    func fetchPersonalizedMessage(
        deviceId: String? = nil
    ) async throws -> PersonalizedMessageResponse {
        var body: [String: Any] = ["action": "personalize"]
        if let deviceId = deviceId {
            body["device_id"] = deviceId
        }
        return try await request(body: body)
    }

    // MARK: - Generate a prompt question (no conversation created yet)

    func generatePrompt(
        title: String?,
        content: String
    ) async throws -> ChatPromptResponse {
        let body: [String: Any] = [
            "action": "prompt",
            "journal_title": title ?? "",
            "journal_content": content
        ]
        return try await request(body: body)
    }

    // MARK: - Start a conversation from a journal entry

    func startConversation(
        title: String?,
        content: String
    ) async throws -> ChatStartResponse {
        let body: [String: Any] = [
            "action": "start",
            "journal_title": title ?? "",
            "journal_content": content
        ]
        return try await request(body: body)
    }

    // MARK: - Send a follow-up message

    func sendReply(
        conversationId: String,
        message: String
    ) async throws -> ChatReplyResponse {
        let body: [String: Any] = [
            "action": "reply",
            "conversation_id": conversationId,
            "message": message
        ]
        return try await request(body: body)
    }

    // MARK: - Fetch conversation history

    func fetchHistory(
        conversationId: String
    ) async throws -> ChatHistoryResponse {
        let body: [String: Any] = [
            "action": "history",
            "conversation_id": conversationId
        ]
        return try await request(body: body)
    }

    // MARK: - Private

    private func request<T: Decodable>(body: [String: Any]) async throws -> T {
        var req = URLRequest(url: functionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: req)

        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        if !(200...299).contains(http.statusCode) {
            let errorBody = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(
                domain: "ChatAPI",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(errorBody)"]
            )
        }

        return try JSONDecoder().decode(T.self, from: data)
    }
}
