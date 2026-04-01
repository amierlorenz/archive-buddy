import SwiftUI
import PhotosUI

struct AddPagesView: View {
    @Environment(\.dismiss) private var dismiss
    let archive: Archive
    let db: DatabaseManager
    let ocrPipeline: OCRPipeline
    let onComplete: () -> Void

    @State private var vm: PageIngestionViewModel?
    @State private var pickerItems: [PhotosPickerItem] = []

    var body: some View {
        NavigationStack {
            Group {
                if let vm {
                    if vm.isProcessing {
                        processingView(vm: vm)
                    } else if vm.draftPages.isEmpty {
                        pickerPrompt
                    } else {
                        reviewList(vm: vm)
                    }
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("Add Pages")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        vm?.reset()
                        dismiss()
                    }
                }
            }
        }
        .task {
            guard vm == nil else { return }
            vm = PageIngestionViewModel(archive: archive, db: db, ocrPipeline: ocrPipeline)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                var images: [UIImage] = []
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let img = UIImage(data: data) {
                        images.append(img)
                    }
                }
                await vm?.processImages(images)
            }
        }
    }

    private var pickerPrompt: some View {
        VStack(spacing: 16) {
            Text("Select photos from your camera roll to add as pages.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            PhotosPicker(
                "Select Photos",
                selection: $pickerItems,
                maxSelectionCount: 20,
                matching: .images
            )
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    private func processingView(vm: PageIngestionViewModel) -> some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Running OCR on \(vm.processingProgress) of \(vm.draftPages.count + 1) pages…")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func reviewList(vm: PageIngestionViewModel) -> some View {
        List {
            ForEach(vm.draftPages) { draft in
                VStack(alignment: .leading, spacing: 8) {
                    // Thumbnail
                    Image(uiImage: UIImage(cgImage: draft.image))
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .cornerRadius(6)

                    // Editable cleaned text
                    TextField(
                        "Extracted text",
                        text: Binding(
                            get: { draft.finalText },
                            set: { vm.updateText(id: draft.id, text: $0) }
                        ),
                        axis: .vertical
                    )
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(4...)

                    // Date picker
                    DatePicker(
                        "Date",
                        selection: Binding(
                            get: { draft.userDefinedDate },
                            set: { vm.updateDate(id: draft.id, date: $0) }
                        ),
                        displayedComponents: .date
                    )
                }
                .padding(.vertical, 4)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Confirm All") {
                    Task {
                        try? await vm.confirmIngestion()
                        onComplete()
                        dismiss()
                    }
                }
            }
        }
    }
}
