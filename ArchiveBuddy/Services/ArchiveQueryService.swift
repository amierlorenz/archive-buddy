import Foundation

/// Coordinates multi-archive RAG retrieval. Knows nothing about LLM generation —
/// it returns a fully-formed augmented prompt and structured citations for the caller.
final class ArchiveQueryService {

    // TUNE: number of top results kept after merging all archives
    static let topKTotal: Int = 5

    private let db: DatabaseManager
    /// One RAGModel per archive, created lazily and reused across queries.
    private var ragModels: [UUID: RAGModel] = [:]

    init(db: DatabaseManager) {
        self.db = db
    }

    // MARK: - Public interface

    /// Fans out semantic search across all selected archives, merges and re-ranks results,
    /// builds an augmented prompt, and returns it alongside structured citations.
    func query(_ text: String, archiveIds: [UUID]) async -> ArchiveQueryResult {
        guard !archiveIds.isEmpty else {
            return ArchiveQueryResult(augmentedPrompt: text, citations: [])
        }

        // Step 1 & 2: load RAGModels, fan out search concurrently
        let rawResults: [(text: String, score: Double)] = await withTaskGroup(
            of: [(text: String, score: Double)].self
        ) { group in
            for archiveId in archiveIds {
                group.addTask {
                    let rag = await self.ragModel(for: archiveId)
                    await rag.loadCollection()
                    return await rag.findLLMNeighbors(for: text)
                }
            }
            var merged: [(text: String, score: Double)] = []
            for await results in group {
                merged.append(contentsOf: results)
            }
            return merged
        }

        // Step 3: sort by score descending, take top-K total
        let topResults = rawResults
            .sorted { $0.score > $1.score }
            .prefix(Self.topKTotal)

        // Step 4: parse __META__ headers, strip them for the LLM, build citations
        var citations: [PageCitation] = []
        var contextBlocks: [String] = []

        for result in topResults {
            let parsed = parseMetaHeader(result.text)
            if let metadata = parsed.metadata {
                let citation = PageCitation(
                    pageId: metadata.pageId,
                    archiveId: metadata.archiveId,
                    archiveTitle: metadata.archiveTitle,
                    pageNumber: metadata.pageNumber,
                    userDefinedDate: metadata.userDefinedDate
                )
                // Deduplicate citations by pageId
                if !citations.contains(where: { $0.pageId == citation.pageId }) {
                    citations.append(citation)
                }
                contextBlocks.append("""
                    [Source: \(metadata.archiveTitle), Page \(metadata.pageNumber)]
                    \(parsed.content)
                    """)
            } else {
                // No metadata header — include raw content without citation
                contextBlocks.append(parsed.content)
            }
        }

        // Step 5: build augmented prompt
        let context = contextBlocks.joined(separator: "\n\n---\n\n")
        let augmentedPrompt = """
            You are a helpful assistant answering questions about physical journal archives. \
            Answer based on the context excerpts below. \
            If the context does not contain enough information to answer, say so clearly. \
            Do not invent details not present in the context.

            Context:
            \(context)

            Question: \(text)

            Answer:
            """

        return ArchiveQueryResult(augmentedPrompt: augmentedPrompt, citations: citations)
    }

    // MARK: - RAGModel cache

    private func ragModel(for archiveId: UUID) -> RAGModel {
        if let existing = ragModels[archiveId] { return existing }
        let rag = RAGModel(collectionName: archiveId.uuidString)
        ragModels[archiveId] = rag
        return rag
    }

    // MARK: - __META__ header parsing

    private struct ParsedChunk {
        let metadata: ChunkMetadata?
        let content: String
    }

    /// Splits the stored SVDB text string into its metadata and clean content parts.
    ///
    /// Expected format:
    /// ```
    /// __META__{...json...}
    /// __CONTENT__
    /// chunk text…
    /// ```
    private func parseMetaHeader(_ stored: String) -> ParsedChunk {
        let metaPrefix = "__META__"
        let contentSeparator = "\n__CONTENT__\n"

        guard stored.hasPrefix(metaPrefix),
              let separatorRange = stored.range(of: contentSeparator) else {
            return ParsedChunk(metadata: nil, content: stored)
        }

        let jsonStart = stored.index(stored.startIndex, offsetBy: metaPrefix.count)
        let jsonString = String(stored[jsonStart..<separatorRange.lowerBound])
        let content = String(stored[separatorRange.upperBound...])

        guard let jsonData = jsonString.data(using: .utf8) else {
            return ParsedChunk(metadata: nil, content: content)
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try? decoder.decode(ChunkMetadata.self, from: jsonData)
        return ParsedChunk(metadata: metadata, content: content)
    }
}

// MARK: - ArchiveQueryResult

struct ArchiveQueryResult {
    /// Fully-formed prompt with injected context, ready to pass to LLM.streamResponse(to:).
    let augmentedPrompt: String
    /// Structured citations for the UI to render below the assistant response.
    let citations: [PageCitation]
}
