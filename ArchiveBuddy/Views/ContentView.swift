//
//  ContentView.swift
//  ArchiveBuddy
//
//  Created by Amier Davis on 2/17/26.
//

import SwiftData
import SwiftUI
import NaturalLanguage // For EmbeddingService

struct ContentView: View {
    @Environment(\.modelContext) var modelContext
    // Initialize EmbeddingService once and pass it down as a shared dependency.
    @State private var embeddingService: EmbeddingService

    init() {
        // Use a State property wrapper for the EmbeddingService to ensure it's
        // initialized once and retained for the lifetime of ContentView.
        _embeddingService = State(initialValue: EmbeddingService())
    }

    var body: some View {
        TabView {
            // First tab: ScanView
            ScanView(
                viewModel: ScanViewModel(
                    modelContext: modelContext,
                    visionService: VisionService(), // Assuming VisionService exists
                    imageStorageService: ImageStorageService(), // Assuming ImageStorageService exists
                    embeddingService: embeddingService // Pass the shared EmbeddingService
                )
            )
            .tabItem {
                Label("Scan", systemImage: "camera.fill")
            }
        }
    }
}

#Preview {
    // For previews, provide an in-memory ModelContainer for JournalEntry
    ContentView()
        .modelContainer(for: JournalEntry.self, inMemory: true)
}

