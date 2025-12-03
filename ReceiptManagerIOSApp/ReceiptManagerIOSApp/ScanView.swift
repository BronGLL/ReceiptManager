//
//  ScanView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit
import FirebaseAuth
import FirebaseStorage
import FirebaseFirestore

// Wrapper model for each caputured image
private struct CapturedImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}
// Function to stitch an array of UIImages into a single image for multi-cropping
func stitchImagesVertically(_ images: [UIImage]) -> UIImage? {
    // No images, do nothing
    guard !images.isEmpty else { return nil }
    
    // Scale down large images to avoid memory issues
    let maxAllowedWidth: CGFloat = 1080
    let maxWidth = images.map { $0.size.width }.max() ?? 0
    // If images are smaller than the allowed width, no scaling needed
    let scaleFactor = min(1.0, maxAllowedWidth / maxWidth)
    // Create a scaled copy of each image
    let scaledImages = images.map { image -> UIImage in
        if scaleFactor == 1.0 { return image }
        let newSize = CGSize(width: image.size.width * scaleFactor,
                             height: image.size.height * scaleFactor)
        // Go into a new graphics context at the smaller size
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let scaled = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return scaled
    }
    
    // Total height after scaling
    let totalHeight = scaledImages.reduce(0) { $0 + $1.size.height }
    // Use the maximum width in the images as the final width
    let finalWidth = scaledImages.map { $0.size.width }.max() ?? 0
    UIGraphicsBeginImageContextWithOptions(CGSize(width: finalWidth, height: totalHeight), false, 0)
    
    var yOffset: CGFloat = 0
    for image in scaledImages {
        image.draw(at: CGPoint(x: 0, y: yOffset))
        yOffset += image.size.height
    }
    // Grab the stitched image from the context
    let stitchedImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    
    return stitchedImage
}

struct ScanView: View {
    // Manages the camera
    @StateObject private var camera = CameraController()
    // Current zoom level
    @State private var currentZoomFactor: CGFloat = 1.0
    // Zoom level at the end of the last pinch
    @State private var lastZoomFactor: CGFloat = 1.0
    // Toggle between landing screen and live camera screen
    @State private var showCamera = false

    // Capture and crop flow
    @State private var capturedItems: [CapturedImageItem] = []
    @State private var croppedImages: [UIImage] = []
    @State private var finalImage: UIImage?
    @State private var didSkipCrop = false
    @State private var showCropper = false

    // Camera roll photo selection
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var cropperImages: [UIImage] = []
    // OCR
    // The structured OCR result for the final image
    @State private var ocrDocument: ReceiptDocument?
    // Populates the receipt document with relevant receipt info
    private let ocrService = OCRService()

    // Edit screen navigation
    @State private var navigateToEdit = false

    // Confirmation/Upload flow (kept for folder selection after edit)
    @State private var showConfirm = false
    @State private var isUploading = false
    @State private var uploadErrorMessage: String?
    
    @State private var folders: [FirestoreService.FolderData] = []
    @State private var selectedFolderId: String? = nil
    private let firestore = FirestoreService()
    private let uploader = ReceiptUploader()
    @State private var showFolderPicker = false

    var body: some View {
        contentView
            .navigationTitle("Scan")
            // Show alert if camera permissions are denied
            .cameraAccessAlert(camera: camera)
            // Show alert if upload does not work correctly
            .genericErrorAlert(message: $uploadErrorMessage)
        // Present the cropping UI to cover the full screen
        .fullScreenCover(
            isPresented: $showCropper,
            onDismiss: {
                // When the cropper is dismissed, stich images if needed and run OCR
                Task {
                    let imagesToStitch = croppedImages
                    if !imagesToStitch.isEmpty,
                       let stitched = stitchImagesVertically(imagesToStitch) {
                        await runOCR(on: stitched)
                    }

                    // Restart camera after cropping
                    if showCamera {
                        camera.startSession()
                    }
                }
            }
        ) {
            // Content of the full-screen cropper
            MultiCropView(
                images: $cropperImages,
                croppedImages: $croppedImages,
                onCancel: {
                    // User canceled cropping, reset to a clean state
                    resetForRetake()
                },
                // User finished cropping
                onDone: {
                    capturedItems = cropperImages.map { CapturedImageItem(image: $0) }
                    showCropper = false
                }
            )
            // Prevent swipe-down dismissal
            .interactiveDismissDisabled(true)
        }
            // Navigation link to push EditReceiptsView when going to edit
            .editNavigationLink(
                ocrDocument: ocrDocument,
                isActive: $navigateToEdit,
                onCancel: { resetForRetake() },
                onSaveAndUpload: { edited in
                    // Dismiss Edit screen
                    navigateToEdit = false
                    // Keep the edited document
                    ocrDocument = edited
                    // Show confirmation dialog after editing
                    showConfirm = true
                    // Clear out the images
                    croppedImages = []
                    capturedItems = []
                }
            )
            // Pop-up to pick a folder before final upload
            .folderPickerSheet(
                isPresented: $showFolderPicker,
                folders: folders,
                onSelect: { id in
                    selectedFolderId = id
                    showFolderPicker = false
                    showConfirm = true
                },
                onNone: {
                    selectedFolderId = nil
                    showFolderPicker = false
                    showConfirm = true
                }
            )
            // Confimation dialog for upload
            .finalUploadConfirmation(
                isPresented: $showConfirm,
                isUploading: isUploading,
                selectedFolderId: selectedFolderId,
                folders: folders,
                chooseFolder: {
                    // Load folders first, then show folder picker
                    Task { await loadFolders() }
                    showFolderPicker = true
                },
                uploadAction: {
                    Task {
                        // Only upload if we have the final document to use
                        if let doc = ocrDocument {
                            await uploadFinalImage(with: doc)
                        }
                    }
                }
            )
    }

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            if showCamera {
                // Live camera mode
                cameraContent
            } else {
                // The initial landing screen with "Open Camera"
                landingContent
            }
        }
        // When camera is visible, hide buttons
        .navigationBarBackButtonHidden(showCamera)
        .toolbar(showCamera ? .hidden : .automatic, for: .navigationBar)
        .toolbar(showCamera ? .hidden : .automatic, for: .tabBar)
    }
    // Main camera screen: preview + overlays + capture control
    private var cameraContent: some View {
        ZStack {
            // Live camera preview
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea(.all)
                // Add zooming feature to camera
                .gesture(
                                MagnificationGesture()
                                    .onChanged { value in
                                        // Calculate the potential new zoom based on the start of this gesture
                                        let potentialZoom = self.lastZoomFactor * value
                                        // Set a maximum zoom
                                        self.currentZoomFactor = max(1.0, min(potentialZoom, 5.0))
                                        camera.setZoom(self.currentZoomFactor)
                                    }
                                    .onEnded { value in
                                        // Save the final zoom value so the next pinch starts from here
                                        self.lastZoomFactor = self.currentZoomFactor
                                    }
                            )
            // Crosshair to help align the receipt
            CenterReticle()
            // Tip at the top of the screen
            VStack {
                Text("Tip: Isolate the receipt (no extra text) on a dark background for best results. ")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                Spacer()
            }
            // Capture contols are at the bottom
            VStack {
                Spacer()
                captureControls
                    .padding(.horizontal, 34)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            // When camera screen appears, ask permission, then configure the session.
            Task {
                await camera.checkPermissions()
                if camera.isAuthorized {
                    await camera.configureSession()
                    camera.startSession()
                    // Wait until the session is running
                    await waitUntilSessionRunning()
                }
            }
        }
        .onDisappear {
            // Stop camera when leaving this screen
            camera.stopSession()
        }
    }
    // The control bar at the bottom of the camera screen
    private var captureControls: some View {
        HStack {
            Button {
                // Open the crop view sheet (if images exist)
                if !capturedItems.isEmpty {
                    cropperImages = capturedItems.map { $0.image }
                    showCropper = true
                    // Pause the camera while cropping
                    camera.stopSession()
                }
            } label: {
                ZStack(alignment: .topTrailing) {

                    // Thumbnail preview of last captured image
                    Group {
                        if let last = capturedItems.last?.image {
                            Image(uiImage: last)
                                .resizable()
                                .scaledToFill()
                        } else {
                            // Placeholder when no images are captured yet
                            Color.black.opacity(0.2)
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    )
                    .opacity(capturedItems.isEmpty ? 0.4 : 1.0)

                    // Images captured counter badge
                    if !capturedItems.isEmpty {
                        Text("\(capturedItems.count)")
                            .font(.caption2.weight(.bold))
                            .padding(4)
                            .background(.white, in: Circle())
                            .foregroundColor(.black)
                            .offset(x: 6, y: -6)
                    }
                }
            }
            // Disable thumbnail button if there is nothing to crop
            .disabled(capturedItems.isEmpty)
            .padding(.trailing, 24)



            Spacer()

            Button {
                Task {
                    do {
                        // Take a photo using the CameraController
                        let image = try await camera.capturePhoto()
                        // Update capturedItems on the main thread
                        await MainActor.run {
                            didSkipCrop = false
                            croppedImages = []
                            capturedItems.append(CapturedImageItem(image: image))
                        }
                        // Uncomment below for single-shot behavior
                        //camera.stopSession()
                    } catch {
                        // Show error if cqapture failed
                        await MainActor.run {
                            uploadErrorMessage = error.localizedDescription
                        }
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(.white)
                        .frame(width: 66, height: 66)
                    Circle()
                        .stroke(.white.opacity(0.8), lineWidth: 2)
                        .frame(width: 74, height: 74)
                }
            }
            .accessibilityLabel("Capture Photo")
            // Disable capture while session isn't running
            .disabled(!camera.isSessionRunning)

            Spacer()
            // Close button
            Button {
                // Go back to anding screen and stop camera preview
                withAnimation { showCamera = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
            }
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 12)
    }

    // Landing screen that appears before the user opens the camera
    private var landingContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .resizable()
                .scaledToFit()
                .frame(height: 120)
                .foregroundStyle(.tint)

            Text("Scan Receipts")
                .font(.title)
                .fontWeight(.semibold)

            Text("Use your iPhone camera to capture receipt images. Place receipts on a dark background for better contrast.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                // Switch to the camera UI
                withAnimation { showCamera = true }
            } label: {
                Label("Open Camera", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
            
            PhotosPicker(
                selection: $selectedItems,
                maxSelectionCount: 0,  // unlimited photos
                matching: .images
            ) {
                Label("Choose from Library", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .padding(.horizontal)
            .onChange(of: selectedItems) { items in
                Task {
                    var loadedImages: [UIImage] = []

                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self),
                           let image = UIImage(data: data) {
                            loadedImages.append(image)
                        }
                    }

                    guard !loadedImages.isEmpty else { return }

                    await MainActor.run {
                        // Assign directly to cropperImages first
                        cropperImages = loadedImages
                        // Only flip the sheet if there are images
                        if !cropperImages.isEmpty {
                            showCropper = true
                            camera.stopSession()
                        }
                    }
                }
            }
        }
        .padding()
    }

    // Wait until the session is reported running (with a short timeout) to avoid hitting capture before session start
    private func waitUntilSessionRunning(timeout: TimeInterval = 1.0) async {
        let start = Date()
        while !camera.isSessionRunning && Date().timeIntervalSince(start)
            // Sleep in short intervals
            < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }
    // Run OCR on the given image, then navigate to the edit view
    private func runOCR(on image: UIImage) async {
        do {
            // Process the image with OCRService to get the ReceiptDocument
            let doc = try await ocrService.process(image: image)
            await MainActor.run {
                ocrDocument = doc
                finalImage = image
                // Trigger navigation to the EditReceiptView
                navigateToEdit = true
            }
        } catch {
            // Show an error if OCR fails
            uploadErrorMessage = "OCR failed: \(error.localizedDescription)"
        }
    }
    // Upload the final image and edited document to the database
    private func uploadFinalImage(with document: ReceiptDocument) async {
        // Prevent double-taps from starting multiple uploads
        guard !isUploading, let imageToUpload = finalImage else { return }
        isUploading = true
        // Make sure that isUploading is reset
        defer { isUploading = false }

        do {
            // Ensure the user is signed in
            guard let uid = Auth.auth().currentUser?.uid else {
                uploadErrorMessage = "Not signed in."
                return
            }
            // Convert the document into a payload for Firebase
            guard let payload = document.makeFirestorePayload(folderID: selectedFolderId) else {
                uploadErrorMessage = "Missing required fields (Store, Total, Date)."
                return
            }
            
            // Upload image to Fire Storage
            let tempId = UUID().uuidString
            let imageURL = try await uploader.uploadReceiptImage(
                imageToUpload,
                forUser: uid,
                receiptId: tempId
            )

            // Write Firestore record for the new receipt
            _ = try await firestore.createReceiptFromOCR(
                ocr: document,
                payload: payload,
                imageURL: imageURL,
                folderId: selectedFolderId
            )
            // Clean up and return to landing state
            resetAfterUpload()

        } catch {
            // Show backend errors
            uploadErrorMessage = error.localizedDescription
        }
    }
    

           


    // Fetch current folders for the current user
    private func loadFolders() async {
        do { folders = try await firestore.fetchFolders() }
        catch { uploadErrorMessage = error.localizedDescription }
    }
    // Reset state for retaking images while in camera mode
    private func resetForRetake() {
        croppedImages = []
        capturedItems = []
        cropperImages = []
        selectedItems = []
        finalImage = nil
        ocrDocument = nil
        selectedFolderId = nil
        showConfirm = false
        showCropper = false
        navigateToEdit = false
        // Reset Zoom settings
        currentZoomFactor = 1.0
        lastZoomFactor = 1.0
        camera.setZoom(1.0)
        // Make sure session is still running
        if showCamera { camera.startSession() }
    }
    // Reset the state after a successful upload and go back to landing screen
    private func resetAfterUpload() {
        croppedImages = []
        capturedItems = []
        cropperImages = []
        finalImage = nil
        ocrDocument = nil
        selectedFolderId = nil
        showConfirm = false
        navigateToEdit = false
        showCamera = false
    }
}
// Center crosshair overlay
private struct CenterReticle: View {
    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = 24
            let thickness: CGFloat = 2
            let color: Color = .white

            ZStack {
                Rectangle()
                    .fill(color.opacity(0.9))
                    .frame(width: thickness, height: 60)
                Rectangle()
                    .fill(color.opacity(0.9))
                    .frame(width: 60, height: thickness)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .shadow(radius: 2)
            .accessibilityHidden(true)
        }
        // Does not intecept touches
        .allowsHitTesting(false)
    }
}

#Preview {
    NavigationStack { ScanView() }
}

private extension View {
    // Presents an alert when the camera controller has no access
    func cameraAccessAlert(camera: CameraController) -> some View {
        alert("Camera Access Needed", isPresented: Binding(
            get: { camera.lastError == .unauthorized },
            set: { _ in }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enable camera access in Settings to scan receipts.")
        }
    }
    // Generic error alert
    func genericErrorAlert(message: Binding<String?>) -> some View {
        alert("Error", isPresented: Binding(
            get: { message.wrappedValue != nil },
            set: { newValue in if !newValue { message.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { message.wrappedValue = nil }
        } message: {
            Text(message.wrappedValue ?? "Unknown error")
        }
    }
    // Helper modifier that wires up MultiCropView
    func multiCropperCover(
            finalImage: Binding<UIImage?>,
            capturedItems: Binding<[CapturedImageItem]>,
            croppedImages: Binding<[UIImage]>,
            showCropper: Binding <Bool>,
            showCamera: Binding<Bool>,
            camera: CameraController,
            runOCR: @escaping (UIImage) async -> Void
    ) -> some View {
            fullScreenCover(
                isPresented: showCropper,
                onDismiss: {
                    Task {
                        let imagesToStitch = croppedImages.wrappedValue
                        if !imagesToStitch.isEmpty {
                            if let stitched = stitchImagesVertically(imagesToStitch) {
                                await runOCR(stitched)
                            }
                        }
                    }
                    // If no images were captured, restart the camera
                    if capturedItems.wrappedValue.isEmpty {
                        camera.startSession()
                        showCamera.wrappedValue = true
                    }
                },
                content: {
                    MultiCropView(
                        images: Binding(
                            get: { capturedItems.wrappedValue.map { $0.image } },
                            set: { _ in } // read-only in this binding
                        ),
                        croppedImages: croppedImages,
                        onCancel: {
                            // Reset the state when cropping is cancelled
                            croppedImages.wrappedValue = []
                            capturedItems.wrappedValue = []
                            finalImage.wrappedValue = nil
                            showCropper.wrappedValue = false

                            if showCamera.wrappedValue {
                                camera.startSession()
                            }
                        },
                        onDone: {
                            showCropper.wrappedValue
                        }
                    )
                    .interactiveDismissDisabled(true)
                }
            )
        }
    // Helper that pushes EditReceiptView in the navigation stack
    func editNavigationLink(
        ocrDocument: ReceiptDocument?,
        isActive: Binding<Bool>,
        onCancel: @escaping () -> Void,
        onSaveAndUpload: @escaping (ReceiptDocument) -> Void
    ) -> some View {
        background {
            NavigationLink(
                isActive: isActive,
                destination: {
                    // Only show EditReceiptView if we have a document to edit
                    if let doc = ocrDocument {
                        EditReceiptView(
                            original: doc,
                            onCancel: onCancel,
                            onSaveAndUpload: onSaveAndUpload
                        )
                    } else {
                        EmptyView()
                    }
                },
                label: {
                    EmptyView()
                }
            )
            .hidden()
        }
    }
    // Sheet that shows a list of folders
    func folderPickerSheet(
        isPresented: Binding<Bool>,
        folders: [FirestoreService.FolderData],
        onSelect: @escaping (String?) -> Void,
        onNone: @escaping () -> Void
    ) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                List {
                    Section("Choose a folder") {
                        Button("None") {
                            onNone()
                        }
                        ForEach(folders, id: \.id) { folder in
                            Button(folder.name) {
                                onSelect(folder.id)
                            }
                        }
                    }
                }
                .navigationTitle("Select Folder")
            }
        }
    }
    // Confirmation diaglog that appears before uploading a receipt
    func finalUploadConfirmation(
        isPresented: Binding<Bool>,
        isUploading: Bool,
        selectedFolderId: String?,
        folders: [FirestoreService.FolderData],
        chooseFolder: @escaping () -> Void,
        uploadAction: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            // If a folder is already chosen, show its name in the title
            selectedFolderId == nil
                ? "Upload this receipt?"
                : "Upload to folder: \(folders.first(where: { $0.id == selectedFolderId })?.name ?? "Folder")",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            // Option to change folder before uploading
            Button("Choose Folder") { chooseFolder() }
            // Main upload button
            Button(isUploading ? "Uploading..." : "Upload") {
                uploadAction()
            }
            .disabled(isUploading)
            // Cacnel option to the back to editing
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Review your edits, then upload.")
        }
    }
}

