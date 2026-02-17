//
//  ContentView.swift
//  ArchiveBuddy
//
//  Created by Amier Davis on 2/17/26.
//

import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    var body: some View {
        // Instantiate ScanViewModel here.
        // For a more complex app, consider using dependency injection.
        ScanView(viewModel: ScanViewModel(modelContext: modelContext))
    }
}

#Preview {
    // For previews, provide an in-memory ModelContainer for JournalEntry
    ContentView()
        .modelContainer(for: JournalEntry.self, inMemory: true)
}

