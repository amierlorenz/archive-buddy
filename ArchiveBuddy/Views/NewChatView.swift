import SwiftUI

struct NewChatView: View {
    @Environment(\.dismiss) private var dismiss
    let chatListVM: ChatListViewModel

    @State private var archives: [Archive] = []
    @State private var selectedIds: Set<UUID> = []
    @Environment(DatabaseManager.self) private var db

    var body: some View {
        NavigationStack {
            List(archives, selection: $selectedIds) { archive in
                VStack(alignment: .leading) {
                    Text(archive.title)
                    if let desc = archive.description {
                        Text(desc).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Select Archives")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Start Chat") {
                        _ = try? chatListVM.createSession(selectedArchiveIds: Array(selectedIds))
                        dismiss()
                    }
                    .disabled(selectedIds.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            archives = (try? db.fetchAllArchives()) ?? []
        }
    }
}
