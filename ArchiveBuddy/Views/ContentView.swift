import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            ArchiveListView()
                .tabItem { Label("Archives", systemImage: "archivebox") }
            ChatListView()
                .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right") }
        }
    }
}

#Preview("Empty") {
    let db = DatabaseManager.preview()
    let llm = LLM(db: db)
    let archiveQueryService = ArchiveQueryService(db: db)
    let ocrPipeline = OCRPipeline()
    
    ContentView()
        .environment(db)
        .environment(llm)
        .environment(archiveQueryService)
        .environment(ocrPipeline)
}

#Preview("Sample Data") {
    SampleDataPreviewWrapper()
}

#if DEBUG
private struct SampleDataPreviewWrapper: View {
    @State private var isReady = false

    private let db: DatabaseManager
    private let llm: LLM
    private let archiveQueryService: ArchiveQueryService
    private let ocrPipeline = OCRPipeline()

    init() {
        let db = DatabaseManager()
        self.db = db
        self.llm = LLM(db: db)
        self.archiveQueryService = ArchiveQueryService(db: db)
    }

    var body: some View {
        if isReady {
            ContentView()
                .environment(db)
                .environment(llm)
                .environment(archiveQueryService)
                .environment(ocrPipeline)
        } else {
            ProgressView("Seeding sample data...")
                .task {
                    await SampleData.seedIfNeeded(db: db)
                    isReady = true
                }
        }
    }
}
#endif
