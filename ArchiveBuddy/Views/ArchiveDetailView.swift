import SwiftUI

struct ArchiveDetailView: View {
    @Environment(DatabaseManager.self) private var db
    @Environment(OCRPipeline.self) private var ocrPipeline
    let archive: Archive

    @State private var pages: [Page] = []
    @State private var showAddPages = false

    var body: some View {
        List {
            ForEach(pages) { page in
                VStack(alignment: .leading, spacing: 4) {
                    Text("Page \(page.pageNumber)").font(.headline)
                    Text(page.userDefinedDate, style: .date).font(.caption).foregroundStyle(.secondary)
                    Text(page.finalText).lineLimit(3).font(.body)
                }
                .padding(.vertical, 2)
            }
        }
        .scrollDisabled(pages.isEmpty)
        .overlay {
            if pages.isEmpty {
                ContentUnavailableView(
                    "No Pages",
                    systemImage: "doc.text",
                    description: Text("Tap Add Pages to get started.")
                )
            }
        }
        .navigationTitle(archive.title)
        .toolbar {
            Button("Add Pages") { showAddPages = true }
        }
        .sheet(isPresented: $showAddPages) {
            AddPagesView(archive: archive, db: db, ocrPipeline: ocrPipeline) {
                loadPages()
            }
        }
        .task { loadPages() }
    }

    private func loadPages() {
        pages = (try? db.fetchPages(archiveId: archive.id)) ?? []
    }
}
