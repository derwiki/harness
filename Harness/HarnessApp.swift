//
//  HarnessApp.swift
//  Harness
//
//  Created by Adam Derewecki on 10/3/26.
//

import SwiftUI
import SwiftData

@main
struct HarnessApp: App {
    @State private var sessionStore = SessionStore()

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Conversation.self,
            Message.self,
            TurnRecord.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(sessionStore)
        }
        .modelContainer(sharedModelContainer)
    }
}
