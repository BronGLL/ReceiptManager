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

private struct CapturedImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

func stitchImagesVertically(_ images: [UIImage]) -> UIImage? {
    guard !images.isEmpty else { return nil }
    
    // Scale down large images to avoid memory issues
    let maxAllowedWidth: CGFloat = 1080
    let maxWidth = images.map { $0.size.width }.max() ?? 0
    let scaleFactor = min(1.0, maxAllowedWidth / maxWidth)
    
    let scaledImages = images.map { image -> UIImage in
        if scaleFactor == 1.0 { return image }
        let newSize = CGSize(width: image.size.width * scaleFactor,
                             height: image.size.height * scaleFactor)
        UIGraphicsBeginImageContextWithOptions(newSize, false, 0)
        image.draw(in: CGRect(origin: .zero, size: newSize))
        let scaled = UIGraphicsGetImageFromCurrentImageContext() ?? image
        UIGraphicsEndImageContext()
        return scaled
    }
    
    // Total height after scaling
    let totalHeight = scaledImages.reduce(0) { $0 + $1.size.height }
    let finalWidth = scaledImages.map { $0.size.width }.max() ?? 0
    
    UIGraphicsBeginImageContextWithOptions(CGSize(width: finalWidth, height: totalHeight), false, 0)
    
    var yOffset: CGFloat = 0
    for image in scaledImages {
        image.draw(at: CGPoint(x: 0, y: yOffset))
        yOffset += image.size.height
    }
    
    let stitchedImage = UIGraphicsGetImageFromCurrentImageContext()
    UIGraphicsEndImageContext()
    
    return stitchedImage
}

struct ScanView: View {
    @StateObject private var camera = CameraController()
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
    @State private var ocrDocument: ReceiptDocument?
    private let ocrService = OCRService()

    // Edit screen navigation
    @State private var navigateToEdit = false

    // Confirmation (kept for folder selection after edit)
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
            .cameraAccessAlert(camera: camera)
            .genericErrorAlert(message: $uploadErrorMessage)
        .fullScreenCover(
            isPresented: $showCropper,
            onDismiss: {
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
            MultiCropView(
                images: $cropperImages,
                croppedImages: $croppedImages,
                onCancel: {
                    resetForRetake()
                },
                onDone: {
                    capturedItems = cropperImages.map { CapturedImageItem(image: $0) }
                    showCropper = false
                }
            )
            .interactiveDismissDisabled(true)
        }

            .editNavigationLink(
                ocrDocument: ocrDocument,
                isActive: $navigateToEdit,
                onCancel: { resetForRetake() },
                onSaveAndUpload: { edited in
                    // 1) Dismiss Edit screen
                    navigateToEdit = false
                    // 2) Keep the edited document
                    ocrDocument = edited
                    showConfirm = true
                    
                    croppedImages = []
                    capturedItems = []
                }
            )
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
            .finalUploadConfirmation(
                isPresented: $showConfirm,
                isUploading: isUploading,
                selectedFolderId: selectedFolderId,
                folders: folders,
                chooseFolder: {
                    Task { await loadFolders() }
                    showFolderPicker = true
                },
                uploadAction: {
                    Task {
                        if let doc = ocrDocument {
                            await uploadFinalImage(with: doc)
                        }
                    }
                }
            )
    }

    // MARK: - Split main branches

    @ViewBuilder
    private var contentView: some View {
        ZStack {
            if showCamera {
                cameraContent
            } else {
                landingContent
            }
        }
        .navigationBarBackButtonHidden(showCamera)
        .toolbar(showCamera ? .hidden : .automatic, for: .navigationBar)
        .toolbar(showCamera ? .hidden : .automatic, for: .tabBar)
    }

    private var cameraContent: some View {
        ZStack {
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea(.all)

            CenterReticle()

            VStack {
                Text("Tip: Place receipt on a dark background for best results.")
                    .font(.subheadline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.top, 12)
                Spacer()
            }

            VStack {
                Spacer()
                captureControls
                    .padding(.horizontal, 34)
                    .padding(.bottom, 24)
            }
        }
        .onAppear {
            Task {
                await camera.checkPermissions()
                if camera.isAuthorized {
                    await camera.configureSession()
                    camera.startSession()
                    await waitUntilSessionRunning()
                }
            }
        }
        .onDisappear {
            camera.stopSession()
        }
    }

    private var captureControls: some View {
        HStack {
            // MARK: - Thumbnail + Counter (Left side)
            Button {
                // Open the crop view sheet (if images exist)
                if !capturedItems.isEmpty {
                    showCropper = true
                    camera.stopSession()
                }
            } label: {
                ZStack(alignment: .topTrailing) {

                    // Thumbnail preview
                    Group {
                        if let last = capturedItems.last?.image {
                            Image(uiImage: last)
                                .resizable()
                                .scaledToFill()
                        } else {
                            Color.black.opacity(0.2)   // Visible placeholder
                        }
                    }
                    .frame(width: 48, height: 48)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.white.opacity(0.8), lineWidth: 1)
                    )
                    .opacity(capturedItems.isEmpty ? 0.4 : 1.0)

                    // Counter Badge
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
            .disabled(capturedItems.isEmpty)
            .padding(.trailing, 24)



            Spacer()

            // MARK: - Capture Button (center)
            Button {
                Task {
                    do {
                        let image = try await camera.capturePhoto()
                        await MainActor.run {
                            didSkipCrop = false
                            croppedImages = []
                            capturedItems.append(CapturedImageItem(image: image))
                        }
                        //camera.stopSession()
                    } catch {
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
            .disabled(!camera.isSessionRunning)

            Spacer()

            // MARK: - Close Button (right)
            Button {
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

    // Wait until the session is reported running (with a short timeout)
    private func waitUntilSessionRunning(timeout: TimeInterval = 1.0) async {
        let start = Date()
        while !camera.isSessionRunning && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    // MARK: - OCR Integration

    private func runOCR(on image: UIImage) async {
        do {
            let doc = try await ocrService.process(image: image)
            await MainActor.run {
                ocrDocument = doc
                finalImage = image
                navigateToEdit = true
            }
        } catch {
            uploadErrorMessage = "OCR failed: \(error.localizedDescription)"
        }
    }
    
    
    // MARK: - Upload Integration (now accepts edited doc)
    private func uploadFinalImage(with document: ReceiptDocument) async {
        guard !isUploading, let imageToUpload = finalImage else { return }
        isUploading = true
        defer { isUploading = false }

        do {
            guard let uid = Auth.auth().currentUser?.uid else {
                uploadErrorMessage = "Not signed in."
                return
            }

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

            // Write Firestore record
            _ = try await firestore.createReceiptFromOCR(
                ocr: document,
                payload: payload,
                imageURL: imageURL,
                folderId: selectedFolderId
            )

            resetAfterUpload()

        } catch {
            uploadErrorMessage = error.localizedDescription
        }
    }
    

           



    private func loadFolders() async {
        do { folders = try await firestore.fetchFolders() }
        catch { uploadErrorMessage = error.localizedDescription }
    }

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
        if showCamera { camera.startSession() }
    }

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
        .allowsHitTesting(false)
    }
}

#Preview {
    NavigationStack { ScanView() }
}

// MARK: - View Modifiers / Helpers to reduce type-checking load

private extension View {
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

    func finalUploadConfirmation(
        isPresented: Binding<Bool>,
        isUploading: Bool,
        selectedFolderId: String?,
        folders: [FirestoreService.FolderData],
        chooseFolder: @escaping () -> Void,
        uploadAction: @escaping () -> Void
    ) -> some View {
        confirmationDialog(
            selectedFolderId == nil
                ? "Upload this receipt?"
                : "Upload to folder: \(folders.first(where: { $0.id == selectedFolderId })?.name ?? "Folder")",
            isPresented: isPresented,
            titleVisibility: .visible
        ) {
            Button("Choose Folder") { chooseFolder() }
            Button(isUploading ? "Uploading..." : "Upload") {
                uploadAction()
            }
            .disabled(isUploading)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Review your edits, then upload.")
        }
    }
}

