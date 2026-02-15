//
//  JournalEditorView.swift
//  MeBoard
//
//  Created by Pranav Somani on 2/14/26.
//

import SwiftUI
import SwiftData

struct JournalEditorView: View {
    enum Mode {
        case create
        case edit(JournalEntry)
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    let mode: Mode

    @State private var title: String = ""
    @State private var content: String = ""
    @State private var savedEntry: JournalEntry? = nil

    private static func defaultTitle() -> String {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        let dateStr = formatter.string(from: now)

        let hour = Calendar.current.component(.hour, from: now)
        let timeOfDay: String
        switch hour {
        case 5..<12: timeOfDay = "☕"
        case 12..<17: timeOfDay = "☀️"
        case 17..<21: timeOfDay = "🌤️"
        default: timeOfDay = "🌙"
        }

        return "\(dateStr) \(timeOfDay)"
    }

    var body: some View {
        Form {
            Section("Title") {
                TextField("Optional", text: $title)
                    .textInputAutocapitalization(.sentences)
            }

            Section("Entry") {
                TextEditor(text: $content)
                    .frame(minHeight: 240)
                    .textInputAutocapitalization(.sentences)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color.earthSand)
        .navigationTitle(modeTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .onAppear { loadIfNeeded() }
        .fullScreenCover(item: $savedEntry) { entry in
            JournalPostSaveView(
                entry: entry,
                title: entry.title,
                content: entry.content
            )
        }
        // When the post-save flow dismisses, also dismiss the editor
        .onChange(of: savedEntry) { oldValue, newValue in
            if oldValue != nil && newValue == nil {
                dismiss()
            }
        }
    }

    private var modeTitle: String {
        switch mode {
        case .create: return "New Entry"
        case .edit: return "Edit Entry"
        }
    }

    private func loadIfNeeded() {
        switch mode {
        case .create:
            if title.isEmpty {
                title = Self.defaultTitle()
            }
        case .edit(let entry):
            title = entry.title
            content = entry.content
        }
    }

    private func save() {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        switch mode {
        case .create:
            let e = JournalEntry(title: cleanTitle, content: cleanContent)
            modelContext.insert(e)
            try? modelContext.save()

            // Show the post-save prompt
            savedEntry = e

        case .edit(let entry):
            entry.title = cleanTitle
            entry.content = cleanContent
            entry.touch()
            try? modelContext.save()
            dismiss()
        }
    }
}
