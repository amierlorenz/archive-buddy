import SwiftUI
import AVFoundation // Required for AVCaptureDevice to request camera permissions

/// The main view for initiating the journal page scanning process.
struct ScanView: View {
    @State private var viewModel: ScanViewModel
    @State private var showingCameraPermissionsAlert = false

    /// Initializes ScanView with a `ScanViewModel`.
    /// - Parameter viewModel: An instance of `ScanViewModel` to manage the scan flow.
    init(viewModel: ScanViewModel) {
        _viewModel = State(initialValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            VStack {
                Spacer()

                Button("Scan New Page") {
                    // Request camera permissions before showing the picker
                    Task {
                        let status = await AVCaptureDevice.requestAccess(for: .video)
                        if status {
                            viewModel.showingImagePicker = true
                        } else {
                            showingCameraPermissionsAlert = true
                        }
                    }
                }
                .font(.title2)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.bottom, 50)

                if viewModel.isLoading {
                    ProgressView("Processing scan...")
                }

                if let errorMessage = viewModel.errorMessage {
                    Text("Error: \(errorMessage)")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                }

                Spacer()
            }
            .navigationTitle("Journal Scanner")
            .sheet(isPresented: $viewModel.showingImagePicker) {
                ImagePickerView(sourceType: .camera) { image in
                    Task {
                        if let image {
                            await viewModel.capturePhoto(image: image)
                        } else {
                            viewModel.errorMessage = "Image capture cancelled or failed."
                        }
                    }
                }
                .padding(.bottom, -20)
                .background(.black)
            }
            .sheet(isPresented: $viewModel.showingReviewScreen) {
                ReviewScreen(viewModel: viewModel)
            }
            .alert("Camera Access Required", isPresented: $showingCameraPermissionsAlert) {
                Button("Go to Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Please enable camera access in Settings to use this feature.")
            }
        }
    }
}
