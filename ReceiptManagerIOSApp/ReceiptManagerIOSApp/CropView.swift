import SwiftUI
import UIKit
import CropViewController

// Screen that hosts the cropper
struct CropView: View {
    // Creating the image, cancel/skip crop callbacks, cropped image
    let image: UIImage
    var onCancel: () -> Void
    var onSkip: () -> Void
    var onCropped: (UIImage) -> Void
    
    // Makes sure the cropper is shown
    @State private var showCropper = true

    var body: some View {
        // Stack the cropper behind the overlay buttons
        ZStack {
            if showCropper {
                SystemCropView(
                    image: image,
                    onComplete: { result in
                        // Called when the user taps "Crop"
                        showCropper = false
                        onCropped(result.image)
                    },
                    onCancel: {
                        // Called when user canscels the crop
                        showCropper = false
                        onCancel()
                    }
                )
                // Fullscreen
                .ignoresSafeArea()
            }
            
            // Top overlay that shows Cancel/Skip controls
            VStack {
                HStack {
                    Button("Cancel") {
                        // Dismiss the croper
                        showCropper = false
                        onCancel()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())

                    Spacer()

                    Button("Skip Crop") {
                        // Dismiss the croper
                        showCropper = false
                        onSkip()
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
                Spacer() // Pushes the buttons to the top
            }
        }
        .statusBarHidden(true)
        // Makes sure the cropper is presented right away
        .onAppear { showCropper = true }
    }
}


// Calling the swiftUI module
struct SystemCropView: UIViewControllerRepresentable {
    typealias UIViewControllerType = CropViewController
    
    // Presents the results
    struct Result { let image: UIImage; let cropRect: CGRect; let angle: Int }
    
    //Initlizes the image and the cropped output. Handles cancels
    let image: UIImage
    var onComplete: (Result) -> Void
    var onCancel: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    // Configure the UIKit crop controller
    func makeUIViewController(context: Context) -> CropViewController {
        
        let vc = CropViewController(image: image)
        vc.delegate = context.coordinator
        vc.doneButtonTitle = "Crop"
        vc.cancelButtonTitle = "Cancel"
        return vc
    }
    // No dynamic updates
    func updateUIViewController(_ uiViewController: CropViewController, context: Context) { }
    //UIKit handler
    final class Coordinator: NSObject, CropViewControllerDelegate {
        let parent: SystemCropView
        init(_ parent: SystemCropView) { self.parent = parent }
        // Called when a rectangular crop is finished, provides final image and metadata
        func cropViewController(_ cropViewController: CropViewController,
                                didCropToImage image: UIImage,
                                withRect cropRect: CGRect,
                                angle: Int) {
            parent.onComplete(.init(image: image, cropRect: cropRect, angle: angle))
        }
        // Called when a circular crop is finished
        func cropViewController(_ cropViewController: CropViewController,
                                didCropToCircularImage image: UIImage,
                                withRect cropRect: CGRect,
                                angle: Int) {
            parent.onComplete(.init(image: image, cropRect: cropRect, angle: angle))
        }
        // Called when user cancels the cropper
        func cropViewController(_ cropViewController: CropViewController,
                                didFinishCancelled cancelled: Bool) {
            parent.onCancel()
        }
    }
}

