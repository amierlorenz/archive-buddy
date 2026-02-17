import SwiftUI

/// A view for reviewing the scanned image and the recognized text, allowing for manual corrections.
struct ReviewScreen: View {
    @Bindable var viewModel: ScanViewModel // Using @Bindable for observing @Observable class
    @State private var journalTitle: String = ""
    @Environment(\.dismiss) private var dismiss // To dismiss the sheet manually

    var body: some View {
        NavigationStack {
            VStack {
                if let image = viewModel.pickedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
//                        .frame(maxHeight: UIScreen.main.bounds.height * 0.4)
                        .padding(.bottom)
                }

                TextEditor(text: $viewModel.recognizedText)
                    .frame(height: 200) // Fixed height for the text editor
                    .border(Color.gray, width: 1)
                    .padding(.horizontal)

                TextField("Journal Entry Title (Optional)", text: $journalTitle)
                    .textFieldStyle(.roundedBorder)
                    .padding()

                // New: AI Refinement Buttons
                HStack {
                    Button("✨ Refine with AI") {
                        Task {
                            await viewModel.refineText()
                        }
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .disabled(viewModel.hasUsedAI || viewModel.isLoading) // Disable if AI already used or loading

                    // New: Undo AI button
                    if viewModel.hasUsedAI { // Only show Undo AI button if AI has been used
                        Button("Undo AI") {
                            viewModel.revertToOriginal()
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                        .disabled(viewModel.isLoading) // Disable while processing
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 5)


                if viewModel.isLoading {
                    ProgressView()
                } else if let errorMessage = viewModel.errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }

                HStack {
                    Button("Discard") {
                        viewModel.discardScan()
                        dismiss() // Dismiss the sheet
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)

                    Button("Save Entry") {
                        Task {
                            await viewModel.saveJournalEntry(title: journalTitle.isEmpty ? nil : journalTitle)
                            // The viewModel will reset its `showingReviewScreen` state
                            // which will cause this sheet to dismiss itself.
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(viewModel.recognizedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || viewModel.isLoading) // Disable if no text or loading
                }
                .padding()
            }
            .navigationTitle("Review & Correct")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.discardScan()
                        dismiss()
                    }
                }
            }
            .interactiveDismissDisabled(viewModel.isLoading) // Prevent dismissing while saving/processing
            .onChange(of: viewModel.showingReviewScreen) { oldValue, newValue in
                // If viewModel resets showingReviewScreen to false, dismiss this sheet.
                if !newValue {
                    dismiss()
                }
            }
        }
    }
}
