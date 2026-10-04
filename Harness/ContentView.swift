//
//  ContentView.swift
//  Harness
//
//  Created by Adam Derewecki on 10/3/26.
//

import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(SessionStore.self) private var sessionStore
    @Query(sort: \Conversation.updatedAt, order: .reverse) private var conversations: [Conversation]
    @Query private var turns: [TurnRecord]
    @State private var selection: Conversation?
    @State private var showingSettings = false
    @AppStorage(AppSettings.modelIDKey) private var defaultModelID = AppSettings.defaultModelID

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(conversations) { conversation in
                    NavigationLink(value: conversation) {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(conversation.title)
                                    .lineLimit(1)
                                HStack(spacing: 4) {
                                    Text(conversation.modelOption.name)
                                    Text(verbatim: "·")
                                    Text(conversation.updatedAt, format: .relative(presentation: .named))
                                }
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Covers the whole turn: waiting, streaming, and running tools.
                            if sessionStore.isRunning(conversation) {
                                ProgressView()
                                    .accessibilityLabel("Responding")
                            }
                        }
                    }
                }
                .onDelete(perform: deleteConversations)
            }
            .overlay {
                if conversations.isEmpty {
                    ContentUnavailableView("No Conversations", systemImage: "bubble.left.and.bubble.right",
                                           description: Text("Tap the compose button to start a chat."))
                }
            }
            .navigationTitle("Harness")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Settings", systemImage: "gear") { showingSettings = true }
                }
                // Gear · "Harness" · weekly cost · New Chat, left to right.
                ToolbarItem(placement: .principal) {
                    HStack(spacing: 8) {
                        Text("Harness")
                            .font(.headline)
                        Text("\(Conversation.formatCost(lastWeekCost)) last week")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    newChatMenu
                }
            }
        } detail: {
            if let selection {
                ChatView(conversation: selection)
                    .id(selection.uuid)
            } else {
                ContentUnavailableView("No Conversation Selected", systemImage: "bubble.left")
            }
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
        }
    }

    /// Picks the model for the new chat. The Settings model ID shows as an extra option if it is not a preset.
    private var newChatMenu: some View {
        Menu {
            Section("New Chat") {
                ForEach(ModelCatalog.presets) { option in
                    Button(option.name) { newConversation(modelID: option.id) }
                }
            }
            let custom = defaultModelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty, ModelCatalog.preset(for: custom) == nil {
                Section("From Settings") {
                    Button(custom) { newConversation(modelID: custom) }
                }
            }
        } label: {
            Label("New Chat", systemImage: "square.and.pencil")
        }
    }

    /// OpenRouter cost of all turns that started in the last 7 days.
    /// Turns of deleted conversations are deleted with them, so they no longer count.
    private var lastWeekCost: Double {
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        return turns.filter { $0.startedAt >= cutoff }.reduce(0) { $0 + $1.totalCost }
    }

    private func newConversation(modelID: String) {
        let conversation = Conversation(modelID: modelID)
        modelContext.insert(conversation)
        selection = conversation
    }

    private func deleteConversations(offsets: IndexSet) {
        for index in offsets {
            let conversation = conversations[index]
            if selection == conversation { selection = nil }
            sessionStore.discard(conversation)
            modelContext.delete(conversation)
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [Conversation.self, Message.self, TurnRecord.self], inMemory: true)
        .environment(SessionStore())
}
