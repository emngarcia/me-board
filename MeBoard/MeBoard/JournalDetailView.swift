//
//  JournalDetailView.swift
//  MeBoard
//
//  Created by Pranav Somani on 2/14/26.
//

import SwiftUI
import SwiftData

struct JournalDetailView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var showingEdit = false
    @State private var showingDeleteConfirm = false
    @State private var showingChat = false

    let entry: JournalEntry

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                    .font(.title2).bold()
                    .foregroundStyle(Color.earthBark)

                Text(entry.createdAt, format: .dateTime.month().day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(Color.earthSage)

                Divider()
                    .overlay(Color.earthSage.opacity(0.4))

                Text(entry.content)
                    .font(.body)
                    .foregroundStyle(Color.earthAccent)
                    .textSelection(.enabled)

                // Chat access button
                if entry.conversationId != nil {
                    // Previous conversation exists — reopen it
                    Button {
                        showingChat = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "bubble.left.and.bubble.right.fill")
                                .font(.subheadline)
                            Text("Continue conversation")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(Color.earthAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.earthAccent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.top, 8)
                } else {
                    // No conversation yet — offer to start one
                    Button {
                        showingChat = true
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: "leaf.fill")
                                .font(.subheadline)
                            Text("Reflect on this entry")
                                .font(.subheadline.weight(.medium))
                        }
                        .foregroundStyle(Color.earthAccent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.earthAccent.opacity(0.1))
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .padding(.top, 8)
                }
            }
            .padding()
        }
        .background(Color.earthSand)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Entry")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { showingEdit = true }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button(role: .destructive) {
                    showingDeleteConfirm = true
                } label: {
                    Image(systemName: "trash")
                }
            }
        }
        .confirmationDialog("Delete this entry?", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                modelContext.delete(entry)
                try? modelContext.save()
                dismiss()
            }
        }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                JournalEditorView(mode: .edit(entry))
            }
        }
        .fullScreenCover(isPresented: $showingChat) {
            NavigationStack {
                if let convoId = entry.conversationId {
                    // Resume existing conversation
                    JournalChatView(
                        journalTitle: entry.title,
                        journalContent: entry.content,
                        existingConversationId: convoId,
                        entry: entry
                    )
                } else {
                    // Start new conversation via the post-save flow
                    JournalPostSaveView(
                        entry: entry,
                        title: entry.title,
                        content: entry.content
                    )
                }
            }
        }
    }
}
