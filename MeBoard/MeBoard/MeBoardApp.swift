//
//  MeBoardApp.swift
//  MeBoard
//
//  Created by Pranav Somani on 2/13/26.
//

import SwiftUI
import SwiftData

@main
struct MeBoardApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(.earthAccent)
        }
        .modelContainer(for: [JournalEntry.self])
    }
}
