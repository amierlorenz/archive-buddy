import Foundation
import CoreGraphics

/// Manages the multi-step batch page ingestion flow:
/// photo selection → OCR → user review/edit → confirm → embed.
@MainActor
@Observable
final class PageIngestionViewModel {

    // MARK: - Review state (transient — never persisted)

    /// One entry per selected photo, populated after OCR completes.
    var draftPages: [DraftPage] = []
    var isProcessing: Bool = false
    var processingProgress: Int = 0  // number of pages OCR'd so far

    // MARK: - Dependencies

    private let archive: Archive
    private let db: DatabaseManager
    private let ocrPipeline: OCRPipeline
    private let ragModel: RAGModel

    init(archive: Archive, db: DatabaseManager, ocrPipeline: OCRPipeline) {
        self.archive = archive
        self.db = db
        self.ocrPipeline = ocrPipeline
        self.ragModel = RAGModel(collectionName: archive.svdbCollectionName)
    }

    // MARK: - Stage 1: OCR

    /// Runs OCR on each image sequentially, appending a DraftPage as each completes
    /// so the review UI can display results progressively.
    func processImages(_ images: [CGImage], defaultDate: Date = Date()) async {
        isProcessing = true
        processingProgress = 0
        draftPages = []

        for image in images {
            let result = (try? await ocrPipeline.process(image: image))
                ?? OCRResult(cleanedText: "", wordConfidenceMap: [:])

            draftPages.append(DraftPage(
                image: image,
                finalText: result.cleanedText,
                userDefinedDate: defaultDate,
                wordConfidenceMap: result.wordConfidenceMap
            ))
            processingProgress += 1
        }

        isProcessing = false
    }

    // MARK: - Stage 2: User edits (called by review UI)

    func updateText(id: UUID, text: String) {
        guard let index = draftPages.firstIndex(where: { $0.id == id }) else { return }
        draftPages[index].finalText = text
    }

    func updateDate(id: UUID, date: Date) {
        guard let index = draftPages.firstIndex(where: { $0.id == id }) else { return }
        draftPages[index].userDefinedDate = date
    }

    // MARK: - Stage 3: Confirm ingestion

    /// Commits all draft pages to the database and SVDB collection.
    /// For each page:
    ///  1. Insert page record (assigns pageNumber atomically)
    ///  2. Chunk text
    ///  3. For each chunk: add to SVDB + insert chunk record
    ///  4. Mark page as embedded
    func confirmIngestion() async throws {
        isProcessing = true
        await ragModel.loadCollection()

        for draft in draftPages {
            // Step 1: persist page
            let pageDraft = PageDraft(
                archiveId: archive.id,
                userDefinedDate: draft.userDefinedDate,
                finalText: draft.finalText
            )
            let page = try db.insertPage(pageDraft)

            // Step 2: chunk
            let chunks = DocumentProcessor.chunkText(page.finalText)

            // Step 3: embed each chunk
            for (index, chunkText) in chunks.enumerated() {
                let metadata = ChunkMetadata(
                    pageId: page.id,
                    archiveId: archive.id,
                    archiveTitle: archive.title,
                    pageNumber: page.pageNumber,
                    userDefinedDate: page.userDefinedDate
                )
                await ragModel.addEntry(chunkText: chunkText, metadata: metadata)

                let chunkId = try db.insertPageChunk(
                    pageId: page.id,
                    archiveId: archive.id,
                    chunkText: chunkText,
                    chunkIndex: index
                )
                try db.markChunkAsEmbedded(chunkId)
            }

            // Step 4: mark page embedded
            try db.markPageAsEmbedded(page.id)
        }

        draftPages = []
        isProcessing = false
    }

    // MARK: - Reset

    func reset() {
        draftPages = []
        isProcessing = false
        processingProgress = 0
    }
}

// MARK: - DraftPage

/// Transient review item. Exists only in memory during the ingestion flow.
/// Photos are never written to disk.
struct DraftPage: Identifiable {
    let id: UUID = UUID()
    let image: CGImage
    var finalText: String
    var userDefinedDate: Date
    /// Per-word OCR confidence scores for highlighting low-confidence words in the review UI.
    let wordConfidenceMap: [String: Float]
}
