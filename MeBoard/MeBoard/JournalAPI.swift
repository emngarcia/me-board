//
//  JournalAPI.swift
//  MeBoard
//
//  Created by Pranav Somani on 2/14/26.
//

import Foundation

struct SaveJournalResponse: Decodable {
    struct Entry: Decodable {
        let id: String
        let created_at: String
    }

    let ok: Bool
    let entry: Entry?
    let error: String?
}

final class JournalAPI {

    static let shared = JournalAPI()

    private let functionURL = URL(
        string: "https://upkozoxjukgofgkidbyq.supabase.co/functions/v1/save-journal-entry"
    )!

    func saveEntry(
        title: String?,
        content: String,
        accessToken: String
    ) async throws -> SaveJournalResponse {

        var req = URLRequest(url: functionURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = [
            "title": title ?? "",
            "content": content
        ]

        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await URLSession.shared.data(for: req)

        guard let http = resp as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        let decoded = try JSONDecoder().decode(SaveJournalResponse.self, from: data)

        if !(200...299).contains(http.statusCode) {
            throw NSError(
                domain: "JournalAPI",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: decoded.error ?? "Request failed"]
            )
        }

        return decoded
    }
}
