//
//  JournalListView.swift
//  MeBoard
//
//  Created by Pranav Somani on 2/14/26.
//

import SwiftUI
import SwiftData

struct JournalListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \JournalEntry.createdAt, order: .reverse) private var entries: [JournalEntry]

    @State private var searchText: String = ""
    @State private var showingNewEntry = false

    private var filtered: [JournalEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(q) ||
            $0.content.localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if filtered.isEmpty {
                    ContentUnavailableView("No entries",
                                          systemImage: "book",
                                          description: Text("Tap + to write your first journal entry."))
                        .foregroundStyle(Color.earthAccent)
                        .listRowBackground(Color.earthSand)
                } else {
                    ForEach(filtered) { entry in
                        NavigationLink {
                            JournalDetailView(entry: entry)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(entry.title.isEmpty ? "Untitled" : entry.title)
                                    .font(.headline)
                                    .foregroundStyle(Color.earthBark)
                                    .lineLimit(1)

                                Text(entry.content)
                                    .font(.subheadline)
                                    .foregroundStyle(Color.earthStone)
                                    .lineLimit(2)

                                Text(entry.createdAt, format: .dateTime.month().day().year())
                                    .font(.caption)
                                    .foregroundStyle(Color.earthSage)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                    .onDelete(perform: delete)
                    .listRowBackground(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.earthCard)
                            .padding(.vertical, 2)
                    )
                }
            }
            .scrollContentBackground(.hidden)
            .background(Color.earthSand)
            .navigationTitle("Journal")
            .foregroundStyle(Color.earthAccent)
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingNewEntry = true
                    } label: {
                        Image(systemName: "plus")
                            .foregroundStyle(Color.earthAccent)
                    }
                    .buttonStyle(.plain)
                }
            }
            .sheet(isPresented: $showingNewEntry) {
                NavigationStack {
                    JournalEditorView(mode: .create)
                }
            }
        }
    }

    private func delete(_ offsets: IndexSet) {
        for idx in offsets {
            let entry = filtered[idx]
            modelContext.delete(entry)
        }
        try? modelContext.save()
    }
}
