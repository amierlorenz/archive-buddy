import SwiftUI

@main
struct ArchiveBuddyApp: App {

    let db: DatabaseManager
    let llm: LLM
    let archiveQueryService: ArchiveQueryService
    let ocrPipeline: OCRPipeline

    init() {
        let db = DatabaseManager()
        self.db = db
        self.llm = LLM(db: db)
        self.archiveQueryService = ArchiveQueryService(db: db)
        self.ocrPipeline = OCRPipeline()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(db)
                .environment(llm)
                .environment(archiveQueryService)
                .environment(ocrPipeline)
        }
    }
}
