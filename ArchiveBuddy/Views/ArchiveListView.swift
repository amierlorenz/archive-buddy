import SwiftUI

private extension View {
    @ViewBuilder
    func searchableIfNeeded(
        _ condition: Bool,
        text: Binding<String>,
        prompt: LocalizedStringKey
    ) -> some View {
        if condition {
            self.searchable(text: text, prompt: prompt)
        } else {
            self
        }
    }
}

struct ArchiveListView: View {
    @Environment(DatabaseManager.self) private var db
    @State private var vm: ArchiveListViewModel?
    @State private var showCreate = false
    @State private var searchText = ""

    private var hasArchives: Bool {
        vm?.archives.isEmpty == false
    }

    private var filteredArchives: [Archive] {
        guard let archives = vm?.archives else { return [] }
        if searchText.isEmpty { return archives }
        return archives.filter { archive in
            archive.title.localizedCaseInsensitiveContains(searchText)
                || (archive.description?.localizedCaseInsensitiveContains(
                    searchText
                ) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(filteredArchives) { archive in
                    NavigationLink {
                        ArchiveDetailView(archive: archive)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(archive.title)
                            if let desc = archive.description {
                                Text(desc).font(.caption).foregroundStyle(
                                    .secondary
                                )
                            }
                        }
                    }
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let archive = filteredArchives[index]
                        vm?.deleteArchive(archive)
                    }
                }
            }
            .scrollDisabled(!hasArchives)
            .searchableIfNeeded(hasArchives, text: $searchText, prompt: "Search archives")
            .onChange(of: hasArchives) {
                if !hasArchives { searchText = "" }
            }
            .overlay {
                if let vm, vm.archives.isEmpty {
                    ContentUnavailableView(
                        "No Archives",
                        systemImage: "book.closed",
                        description: Text("Tap New Archive to get started.")
                    )
                } else if !searchText.isEmpty, filteredArchives.isEmpty {
                    ContentUnavailableView.search(text: searchText)
                }
            }
            .navigationTitle("Archives")
            .toolbar {
                Button("New Archive") { showCreate = true }
            }
            .sheet(isPresented: $showCreate) {
                if let vm {
                    CreateArchiveView(vm: vm)
                }
            }
        }
        .task {
            guard vm == nil else { return }
            let v = ArchiveListViewModel(db: db)
            v.loadArchives()
            vm = v
        }
    }
}
