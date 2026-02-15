//
//  RootView.swift
//  MeBoard
//
//  Created by Pranav Somani on 2/14/26.
//

import SwiftUI

struct RootView: View {
    var body: some View {
        TabView {
            JournalListView()
                .tabItem { Label("Journal", systemImage: "book") }

            MentalHealthDashboardView()
                .tabItem { Label("Home", systemImage: "house") }
        }
    }
}
