//
//  ScanView.swift
//  ReceiptManagerIOSApp
//

import SwiftUI
import PhotosUI
import AVFoundation
import FirebaseAuth

private struct CapturedImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct ScanView: View {
    // MARK: - Camera
    @StateObject private var camera = CameraController()
    @State private var showCamera = false

    // MARK: - OCR
    @State private var ocrDocument: ReceiptDocument?
    private let ocrService = OCRService()
    @State private var hasRunOCR = false

    // MARK: - Multi-photo cropping
    @State private var imagesToProcess: [UIImage] = []
    @State private var croppedImages: [UIImage] = []
    @State private var showingMultiCrop = false

    // Edit screen navigation
    @State private var navigateToEdit = false

    // Confirmation / upload
    @State private var showConfirm = false
    @State private var isUploading = false
    @State private var uploadErrorMessage: String?
    @State private var showFolderPicker = false
    
    @State private var folders: [FirestoreService.FolderData] = []
    @State private var selectedFolderId: String? = nil
    private let firestore = FirestoreService()
    private let uploader = ReceiptUploader()

    var body: some View {
        ZStack {
            cameraView
            landingView
        }
        .navigationTitle("Scan")
        .statusBarHidden(true)
        .cameraAccessAlert(camera: camera)
        .genericErrorAlert(message: $uploadErrorMessage)

        // Multi-image crop
        .fullScreenCover(isPresented: $showingMultiCrop) {
            MultiCropView(
                images: $imagesToProcess,
                croppedImages: $croppedImages
            )
            .onDisappear {
                // Trigger OCR if there are cropped images
                if !croppedImages.isEmpty {
                    Task { await runOCROnAllCroppedImages() }
                    navigateToEdit = true
                } else if !imagesToProcess.isEmpty {
                    // fallback: no crop done, use original images
                    croppedImages = imagesToProcess
                    Task { await runOCROnAllCroppedImages() }
                    navigateToEdit = true
                }
                imagesToProcess = []
                hasRunOCR = false
            }
        }

        // Edit navigation
        .editNavigationLink(
            ocrDocument: ocrDocument,
            isActive: $navigateToEdit,
            onCancel: { resetForRetake() },
            onSaveAndUpload: { edited in
                ocrDocument = edited
                Task {
                    await MainActor.run {
                        navigateToEdit = false
                    }
                    await showFolderPickerFlow()
                }
            }
        )

        
        // Folder picker sheet
        .folderPickerSheet(
            isPresented: $showFolderPicker,
            folders: folders,
            onSelect: { id in
                selectedFolderId = id
                showConfirm = true
            },
            onNone: {
                selectedFolderId = nil
                showConfirm = true
            }
        )

        // Final confirmation
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
                Task { await uploadFinalImages() }
            }
        )
    }

    // MARK: - Camera View
    @ViewBuilder
    private var cameraView: some View {
        if showCamera {
            ZStack {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()

                CenterReticle()

                // Top buttons: Cancel and MultiCrop
                VStack {
                    HStack {
                        Button {
                            withAnimation { showCamera = false }
                            camera.stopSession()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 28, weight: .semibold))
                                .foregroundStyle(.white)
                                .shadow(radius: 2)
                        }
                        Spacer()

                        Button {
                            showingMultiCrop = true
                            withAnimation { showCamera = false }
                        } label: {
                            ZStack(alignment: .topTrailing) {
                                if let lastImage = imagesToProcess.last {
                                    Image(uiImage: lastImage)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 50, height: 50)
                                        .clipped()
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.white.opacity(0.8), lineWidth: 1)
                                        )
                                } else {
                                    Rectangle()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.white.opacity(0.8), lineWidth: 1)
                                        )
                                }
                                if !imagesToProcess.isEmpty {
                                    Text("\(imagesToProcess.count)")
                                        .font(.caption2.bold())
                                        .foregroundColor(.white)
                                        .padding(6)
                                        .background(Circle().fill(Color.accentColor))
                                        .offset(x: 8, y: -8)
                                }
                            }
                        }
                        .disabled(imagesToProcess.isEmpty)
                    }
                    .padding()
                    Spacer()
                }

                // Bottom capture button
                VStack {
                    Spacer()
                    Button {
                        Task { await capturePhoto() }
                    } label: {
                        ZStack {
                            Circle().fill(.white).frame(width: 66, height: 66)
                            Circle().stroke(.white.opacity(0.8), lineWidth: 2).frame(width: 74, height: 74)
                        }
                    }
                    .padding(.bottom, 24)
                }
            }
            .onAppear { Task { await setupCamera() } }
            .onDisappear { camera.stopSession() }
        }
    }

    @ViewBuilder
    private var landingView: some View {
        if !showCamera {
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
            }
            .padding()
        }
    }

    // MARK: - Camera & Capture
    private func setupCamera() async {
        await camera.checkPermissions()
        if camera.isAuthorized {
            await camera.configureSession()
            camera.startSession()
            await waitUntilSessionRunning()
        }
    }

    private func waitUntilSessionRunning(timeout: TimeInterval = 1.0) async {
        let start = Date()
        while !camera.isSessionRunning && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func capturePhoto() async {
        do {
            let image = try await camera.capturePhoto()
            await MainActor.run {
                imagesToProcess.append(image)
            }
        } catch {
            await MainActor.run { uploadErrorMessage = error.localizedDescription }
        }
    }

    // MARK: - OCR
    private func runOCROnAllCroppedImages() async {
        guard !croppedImages.isEmpty else { return }
        var combinedText = ""
        for image in croppedImages {
            do {
                let doc = try await ocrService.process(image: image)
                combinedText += doc.rawText + "\n"
            } catch {
                await MainActor.run { uploadErrorMessage = "OCR failed: \(error.localizedDescription)" }
            }
        }
        let mergedDoc = ReceiptDocument(id: UUID(), rawText: combinedText)
        await MainActor.run { ocrDocument = mergedDoc }
    }

    // MARK: - Upload / Folder
    private func showFolderPickerFlow() async {
        if folders.isEmpty {
            do {
                folders = try await firestore.fetchFolders()
            } catch {
                await MainActor.run { uploadErrorMessage = error.localizedDescription }
                return
            }
        }
        await MainActor.run {
            showFolderPicker = true
        }
    }

    private func loadFolders() async {
        do { folders = try await firestore.fetchFolders() }
        catch { uploadErrorMessage = error.localizedDescription }
    }

    private func uploadFinalImages() async {
        guard !isUploading, !croppedImages.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }

        do {
            guard let uid = Auth.auth().currentUser?.uid else {
                uploadErrorMessage = "Not signed in."
                return
            }

            let receiptId = try await uploader.createReceiptDocument(forUser: uid, storeName: "Scanned Receipt")
            if let finalImage = stitchImagesVertically(croppedImages) {
                _ = try await uploader.uploadReceiptImage(finalImage, forUser: uid, receiptId: receiptId)
            }

            // Reset everything
            croppedImages.removeAll()
            imagesToProcess.removeAll()
            showConfirm = false
            hasRunOCR = false
            withAnimation { showCamera = false }
        } catch {
            uploadErrorMessage = error.localizedDescription
        }
    }

    private func retakeReceipt() {
        croppedImages.removeAll()
        imagesToProcess.removeAll()
        showConfirm = false
        hasRunOCR = false
        withAnimation { showCamera = true }
        camera.startSession()
    }

    private func resetForRetake() {
        croppedImages.removeAll()
        imagesToProcess.removeAll()
        ocrDocument = nil
        selectedFolderId = nil
        showConfirm = false
        navigateToEdit = false
        if showCamera { camera.startSession() }
    }

    // MARK: - Image Stitching
    func stitchImagesVertically(_ images: [UIImage]) -> UIImage? {
        guard !images.isEmpty else { return nil }
        let maxWidth = images.map { $0.size.width }.max() ?? 0
        let totalHeight = images.reduce(0) { total, image in
            let scale = maxWidth / image.size.width
            return total + (image.size.height * scale)
        }
        UIGraphicsBeginImageContextWithOptions(CGSize(width: maxWidth, height: totalHeight), false, 0)
        var yOffset: CGFloat = 0
        for image in images {
            let scale = maxWidth / image.size.width
            let newHeight = image.size.height * scale
            image.draw(in: CGRect(x: 0, y: yOffset, width: maxWidth, height: newHeight))
            yOffset += newHeight
        }
        let stitched = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        return stitched
    }
}

// MARK: - Center Reticle
private struct CenterReticle: View {
    var body: some View {
        GeometryReader { geo in
            let size: CGFloat = 24
            let thickness: CGFloat = 2
            let color: Color = .white
            ZStack {
                Rectangle().fill(color.opacity(0.9)).frame(width: thickness, height: 60)
                Rectangle().fill(color.opacity(0.9)).frame(width: 60, height: thickness)
            }
            .frame(width: size, height: size)
            .position(x: geo.size.width / 2, y: geo.size.height / 2)
            .shadow(radius: 2)
        }
        .allowsHitTesting(false)
    }
}


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

    func cropperCover(
        capturedItem: Binding<CapturedImageItem?>,
        showCamera: Binding<Bool>,
        didSkipCrop: Binding<Bool>,
        croppedImage: Binding<UIImage?>,
        camera: CameraController,
        runOCR: @escaping (UIImage) async -> Void
    ) -> some View {
        fullScreenCover(item: capturedItem, onDismiss: {
            // After crop/skip, navigation to edit happens when OCR completes
        }, content: { item in
            CropView(
                image: item.image,
                onCancel: {
                    didSkipCrop.wrappedValue = false
                    croppedImage.wrappedValue = nil
                    capturedItem.wrappedValue = nil
                    if showCamera.wrappedValue {
                        camera.startSession()
                    }
                },
                onSkip: {
                    didSkipCrop.wrappedValue = true
                    croppedImage.wrappedValue = nil
                    capturedItem.wrappedValue = nil
                    Task { await runOCR(item.image) }
                },
                onCropped: { result in
                    didSkipCrop.wrappedValue = false
                    croppedImage.wrappedValue = result
                    capturedItem.wrappedValue = nil
                    Task { await runOCR(result) }
                }
            )
            .interactiveDismissDisabled(true)
        })
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
                            isPresented.wrappedValue = false
                            onNone()
                        }
                        ForEach(folders, id: \.id) { folder in
                            Button(folder.name) {
                                isPresented.wrappedValue = false
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
