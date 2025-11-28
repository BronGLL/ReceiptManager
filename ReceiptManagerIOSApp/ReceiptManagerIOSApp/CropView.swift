import SwiftUI
import UIKit
import CropViewController

// Screen that hosts the cropper
struct CropView: View {
    // Creating the image, cancel/skip crop callbacks, cropped image
    let image: UIImage
    var onCancel: () -> Void
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

// MARK: - Multi-Image Crop View
struct MultiCropView: View {
    @Binding var images: [UIImage]
    @Binding var croppedImages: [UIImage]
    
    let onCancel: () -> Void
    let onDone: () -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var currentIndex: Int = 0
    @State private var backgroundOpacity: Double = 0.0 // <-- fade state
    
    var body: some View {
        ZStack {
            // Black background with animated opacity
            Color.black
                .ignoresSafeArea()
                .opacity(backgroundOpacity)
                .animation(.easeInOut(duration: 0.25), value: backgroundOpacity)
            
            VStack(spacing: 0) {
                if !images.isEmpty {
                    TabView(selection: $currentIndex) {
                        ForEach(images.indices, id: \.self) { index in
                            let displayImage = (croppedImages.count > index ? croppedImages[index] : images[index])
                            CropView(
                                image: displayImage,
                                onCancel: {
                                    onCancel()
                                    dismiss()
                                },
                                onCropped: { cropped in
                                    saveCropped(cropped, at: index)
                                    nextImage()
                                }
                            )
                            .tag(index)
                            .onAppear {
                                // Fade in black background when crop view appears
                                backgroundOpacity = 1.0
                            }
                        }
                    }
                    .tabViewStyle(PageTabViewStyle(indexDisplayMode: .never))
                    .animation(.easeInOut, value: currentIndex)
                }
                
//                // Thumbnails strip
//                ZStack {
//                    RoundedRectangle(cornerRadius: 16, style: .continuous)
//                        .fill(.ultraThinMaterial)
//                        .shadow(radius: 5, y: -2)
//                        .ignoresSafeArea(edges: .bottom)
//                        .frame(height: 80, alignment: .bottom)
//
//                    ScrollView(.horizontal, showsIndicators: false) {
//                        HStack(spacing: 8) {
//                            ForEach(images.indices, id: \.self) { index in
//                                let thumbnail = (croppedImages.count > index ? croppedImages[index] : images[index])
//                                Image(uiImage: thumbnail)
//                                    .resizable()
//                                    .scaledToFill()
//                                    .frame(width: 60, height: 60)
//                                    .clipped()
//                                    .cornerRadius(8)
//                                    .overlay(
//                                        RoundedRectangle(cornerRadius: 8)
//                                            .stroke(index == currentIndex ? Color.accentColor : Color.clear, lineWidth: 2)
//                                    )
//                                    .onTapGesture { currentIndex = index }
//                            }
//                        }
//                        .padding(.horizontal)
//                        .padding(.vertical, 8)
//                    }
//                    .padding(.bottom, 12)
//                }
//                .frame(height: 100)
//                .frame(maxWidth: .infinity, alignment: .bottom)
                
                Text("Image \(currentIndex + 1) of \(images.count)")
                    .foregroundColor(.white)
                    .padding(.bottom, 8)
            }
        }
        .statusBarHidden(true)
        .onAppear {
            // Fade in background on first appear
            backgroundOpacity = 1.0
        }
    }
    
    private func saveCropped(_ image: UIImage, at index: Int) {
        if croppedImages.count > index {
            croppedImages[index] = image
        } else {
            croppedImages.append(image)
        }
    }
    
    private func nextImage() {
        if currentIndex + 1 < images.count {
            currentIndex += 1
        } else {
            onDone()
            dismiss()
        }
    }
}
