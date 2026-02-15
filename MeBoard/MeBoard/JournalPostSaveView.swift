//
//  JournalPostSaveView.swift
//  MeBoard
//

import SwiftUI
import SwiftData
import Combine

/// Shown after saving a journal entry. Generates a personalized prompt
/// and asks if the user wants to talk about what they wrote.
struct JournalPostSaveView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let entry: JournalEntry
    let title: String
    let content: String

    @State private var generatedPrompt: String? = nil
    @State private var isLoadingPrompt = true
    @State private var promptError: String? = nil
    @State private var showingChat = false
    @State private var declined = false
    @State private var conversationId: String? = nil

    var body: some View {
        ZStack {
            Color.earthSand.ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                // Leaf icon
                Image(systemName: "leaf.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Color.earthAccent)

                Text("Entry Saved")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Color.earthBark)

                if declined {
                    // User said "not right now"
                    declinedView
                } else if isLoadingPrompt {
                    // Loading the prompt
                    loadingView
                } else if let prompt = generatedPrompt {
                    // Show the generated question
                    promptView(prompt)
                } else if let error = promptError {
                    // Error generating prompt — still let them proceed
                    errorFallbackView(error)
                }

                Spacer()
            }
            .padding(32)
        }
        .task {
            await generatePrompt()
        }
        .fullScreenCover(isPresented: $showingChat) {
            // When chat dismisses, also dismiss this view
            dismiss()
        } content: {
            NavigationStack {
                JournalChatView(
                    journalTitle: title,
                    journalContent: content,
                    existingConversationId: conversationId,
                    entry: entry
                )
            }
        }
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .tint(.earthAccent)
            Text("Reading your entry…")
                .font(.subheadline)
                .foregroundStyle(Color.earthStone)
        }
    }

    // MARK: - Prompt View

    private func promptView(_ prompt: String) -> some View {
        VStack(spacing: 20) {
            Text(prompt)
                .font(.body)
                .foregroundStyle(Color.earthBark)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                Button {
                    showingChat = true
                } label: {
                    Text("Let's talk")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.earthAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        declined = true
                    }
                } label: {
                    Text("Not right now")
                        .font(.subheadline)
                        .foregroundStyle(Color.earthSage)
                }
            }
        }
    }

    // MARK: - Declined View

    private var declinedView: some View {
        VStack(spacing: 20) {
            Text("That's completely okay. Your thoughts are safe here, and I'm always around whenever you feel like talking.")
                .font(.subheadline)
                .foregroundStyle(Color.earthStone)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                dismiss()
            } label: {
                Text("Done")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.earthAccent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.earthAccent.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .transition(.opacity)
    }

    // MARK: - Error Fallback

    private func errorFallbackView(_ error: String) -> some View {
        VStack(spacing: 20) {
            Text("Would you like to reflect on what you just wrote?")
                .font(.body)
                .foregroundStyle(Color.earthBark)
                .multilineTextAlignment(.center)

            VStack(spacing: 10) {
                Button {
                    showingChat = true
                } label: {
                    Text("Let's talk")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Color.earthAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                Button {
                    dismiss()
                } label: {
                    Text("Maybe later")
                        .font(.subheadline)
                        .foregroundStyle(Color.earthSage)
                }
            }
        }
    }

    // MARK: - API Call

    private func generatePrompt() async {
        isLoadingPrompt = true
        do {
            let response = try await ChatAPI.shared.generatePrompt(title: title, content: content)
            if response.ok, let prompt = response.prompt {
                generatedPrompt = prompt
            } else {
                promptError = response.error ?? "Failed to generate prompt"
            }
        } catch {
            promptError = error.localizedDescription
        }
        isLoadingPrompt = false
    }
}
