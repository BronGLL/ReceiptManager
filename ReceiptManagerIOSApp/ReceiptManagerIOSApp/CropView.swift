import SwiftUI
import UIKit
import CropViewController

// MARK: - Single Crop View
struct CropView: View {
    let image: UIImage
    var onCancel: () -> Void
    var onSkip: () -> Void
    var onCropped: (UIImage) -> Void
    
    @State private var showCropper = true
    @State private var isProcessing = false

    var body: some View {
        ZStack {
            // Black background for the entire screen
            Color.black.ignoresSafeArea()
            
            if showCropper {
                SystemCropView(
                    image: image,
                    onComplete: { result in
                        // showCropper = false
                        onCropped(result.image)
                    },
                    onCancel: {
                        showCropper = false
                        onCancel()
                    }
                )
                .ignoresSafeArea()
            }
            
            // Top overlay buttons
            VStack {
                HStack {
                    Button("Cancel") {
                        showCropper = false
                        onCancel()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    
                    Spacer()
                    
                    Button("Skip Crop") {
                        showCropper = false
                        onSkip()
                    }
                    .foregroundColor(.white)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                }
                .padding()
                Spacer()
            }
        }
        .statusBarHidden(true)
    }
}

// MARK: - UIKit Crop Controller Wrapper
struct SystemCropView: UIViewControllerRepresentable {
    typealias UIViewControllerType = CropViewController
    
    struct Result { let image: UIImage; let cropRect: CGRect; let angle: Int }
    
    let image: UIImage
    var onComplete: (Result) -> Void
    var onCancel: () -> Void
    
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    
    func makeUIViewController(context: Context) -> CropViewController {
        let vc = CropViewController(image: image)
        vc.delegate = context.coordinator
        vc.doneButtonTitle = "Crop"
        vc.cancelButtonTitle = "Cancel"
        
        // Force a full black background
        vc.view.backgroundColor = .black
        vc.cropView.backgroundColor = .black
        vc.toolbar.backgroundColor = .black
        vc.toolbar.tintColor = .white
        
        return vc
    }
    
    func updateUIViewController(_ uiViewController: CropViewController, context: Context) { }
    
    final class Coordinator: NSObject, CropViewControllerDelegate {
        let parent: SystemCropView
        init(_ parent: SystemCropView) { self.parent = parent }
        
        func cropViewController(_ cropViewController: CropViewController,
                                didCropToImage image: UIImage,
                                withRect cropRect: CGRect,
                                angle: Int) {
            parent.onComplete(.init(image: image, cropRect: cropRect, angle: angle))
            //cropViewController.dismiss(animated: true)
        }
        
        func cropViewController(_ cropViewController: CropViewController,
                                didCropToCircularImage image: UIImage,
                                withRect cropRect: CGRect,
                                angle: Int) {
            parent.onComplete(.init(image: image, cropRect: cropRect, angle: angle))
            //cropViewController.dismiss(animated: true)
        }
        
        func cropViewController(_ cropViewController: CropViewController,
                                didFinishCancelled cancelled: Bool) {
            cropViewController.dismiss(animated: true)
            
        }
    }
}

// MARK: - Multi-Image Crop View
struct MultiCropView: View {
    @Binding var images: [UIImage]
    @Binding var croppedImages: [UIImage]
    
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
                            CropView(
                                image: images[index],
                                onCancel: { dismiss() },
                                onSkip: { nextImage() },
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
                
                // Thumbnails strip
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.ultraThinMaterial)
                        .shadow(radius: 5, y: -2)
                        .ignoresSafeArea(edges: .bottom)
                        .frame(height: 80, alignment: .bottom)

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(images.indices, id: \.self) { index in
                                let thumbnail = (croppedImages.count > index ? croppedImages[index] : images[index])
                                Image(uiImage: thumbnail)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 60, height: 60)
                                    .clipped()
                                    .cornerRadius(8)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(index == currentIndex ? Color.accentColor : Color.clear, lineWidth: 2)
                                    )
                                    .onTapGesture { currentIndex = index }
                            }
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                    }
                    .padding(.bottom, 12)
                }
                .frame(height: 100)
                .frame(maxWidth: .infinity, alignment: .bottom)
                
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
            dismiss()
        }
    }
}
