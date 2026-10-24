import SwiftUI

struct CreateArchiveView: View {
    @Environment(\.dismiss) private var dismiss
    let vm: ArchiveListViewModel

    @State private var title = ""
    @State private var description = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Title", text: $title)
                TextField("Description (optional)", text: $description)
            }
            .navigationTitle("New Archive")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        try? vm.createArchive(
                            title: title,
                            description: description.isEmpty ? nil : description
                        )
                        dismiss()
                    }
                    .disabled(title.isEmpty)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
