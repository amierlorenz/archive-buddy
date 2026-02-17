import SwiftUI
import UIKit

/// A SwiftUI `UIViewControllerRepresentable` wrapper for `UIImagePickerController`
/// to allow camera capture within a SwiftUI view hierarchy.
struct ImagePickerView: UIViewControllerRepresentable {
    @Environment(\.dismiss) var dismiss // For dismissing the sheet
    var sourceType: UIImagePickerController.SourceType = .camera
    var onImagePicked: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.delegate = context.coordinator
        picker.sourceType = sourceType
        picker.allowsEditing = false // Set to true if you want to allow image editing
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {
        // No update needed
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        var parent: ImagePickerView

        init(_ parent: ImagePickerView) {
            self.parent = parent
        }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey : Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onImagePicked(image)
            } else {
                parent.onImagePicked(nil) // No image picked
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onImagePicked(nil) // User cancelled
            parent.dismiss()
        }
    }
}
