//
//  JournalEntry.swift
//  MeBoard
//
//  Created by Pranav Somani on 2/14/26.
//

import Foundation
import SwiftData

@Model
final class JournalEntry {
    var id: UUID
    var createdAt: Date
    var updatedAt: Date
    var title: String
    var content: String

    /// Supabase conversation ID, set once the user starts a chat about this entry
    var conversationId: String?

    init(title: String = "", content: String = "") {
        self.id = UUID()
        self.createdAt = Date()
        self.updatedAt = Date()
        self.title = title
        self.content = content
        self.conversationId = nil
    }

    func touch() {
        updatedAt = Date()
    }
}
