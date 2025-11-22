//
//  ScanView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI
import AVFoundation
import UIKit
import FirebaseAuth
import FirebaseStorage
import FirebaseFirestore

private struct CapturedImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}


struct ScanView: View {
    @StateObject private var camera = CameraController()
    @State private var showCamera = false

    // Capture and crop flow
    @State private var capturedItems: [CapturedImageItem] = []
    @State private var croppedImages: [UIImage] = []
    @State private var didSkipCrop = false
    @State private var showMultiCrop = false

    // OCR
    @State private var ocrDocument: ReceiptDocument?
    private let ocrService = OCRService()
    @State private var didRunOCR = false

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
            .multiCropperCover(
                capturedItems: $capturedItems,
                croppedImages: $croppedImages,
                showMultiCrop: $showMultiCrop,
                didRunOCR: $didRunOCR,
                runOCR: runOCR
            )
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
        ZStack {
            HStack {
                Spacer()

                // Preview button (shows number of captured photos)
                
                Button {
                    showMultiCrop = true
                    showCamera = false // temporarily hide camera to trigger fullScreenCover
                } label: {
                    ZStack(alignment: .topTrailing) {
                        // Thumbnail of last photo
                        if let last = capturedItems.last?.image {
                            Image(uiImage: last)
                                .resizable()
                                .scaledToFill()
                                .frame(width: 50, height: 50)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(.white, lineWidth: 1)
                                )
                        } else {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(.white.opacity(0.3))
                                .frame(width: 50, height: 50)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.white.opacity(0.6), lineWidth: 1)
                                )
                        }

                        // Count badge
                        if !capturedItems.isEmpty {
                            Text("\(capturedItems.count)")
                                .font(.caption2.bold())
                                .foregroundColor(.white)
                                .padding(4)
                                .background(.blue, in: Circle())
                                .offset(x: 8, y: -8)
                        }
                    }
                }
                .accessibilityLabel("\(capturedItems.count) photos taken")
                .disabled(capturedItems.isEmpty)
                .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .padding(.top, 44)

            // Capture button (center bottom)
            VStack {
                Spacer()
                Button {
                    Task {
                        do {
                            let image = try await camera.capturePhoto()
                            await MainActor.run {
                                didSkipCrop = false
                                croppedImages = []
                                capturedItems.append(CapturedImageItem(image: image))
                            }
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
                .padding(.bottom, 24)
            }

            // Close button (top-left)
            VStack {
                HStack {
                    Button {
                        withAnimation { showCamera = false }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                    }
                    .accessibilityLabel("Close")
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 44)
            .padding(.horizontal, 16)
        }
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
                navigateToEdit = true
            }
        } catch {
            uploadErrorMessage = "OCR failed: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Upload Integration (now accepts edited doc)
    private func uploadFinalImage(with document: ReceiptDocument) async {
        guard !isUploading, !croppedImages.isEmpty else { return }
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

            guard let finalImage = stitchImagesVertically(croppedImages) else {
                uploadErrorMessage = "Failed to stitch images."
                return
            }

            // 1️⃣ Create a single receipt document
            let receiptId = try await uploader.createReceiptDocument(forUser: uid,
                                                                     storeName: payload.storeName,
                                                                     totalAmount: payload.totalAmount,
                                                                     tax: payload.tax)

            // 2️⃣ Upload image
            let imageURL = try await uploader.uploadReceiptImage(finalImage, forUser: uid, receiptId: receiptId)

            // 3️⃣ Update document with OCR + image
            try await uploader.updateReceiptDocument(forUser: uid, receiptId: receiptId, payload: payload, imageURL: imageURL)

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
        ocrDocument = nil
        selectedFolderId = nil
        showConfirm = false
        navigateToEdit = false
        didRunOCR = false
        if showCamera { camera.startSession() }
    }

    private func resetAfterUpload() {
        croppedImages = []
        capturedItems = []
        ocrDocument = nil
        selectedFolderId = nil
        showConfirm = false
        navigateToEdit = false
        showCamera = false
        didRunOCR = false
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
        capturedItems: Binding<[CapturedImageItem]>,
        croppedImages: Binding<[UIImage]>,
        showMultiCrop: Binding<Bool>,
        didRunOCR: Binding<Bool>, // <- new
        runOCR: @escaping (UIImage) async -> Void
    ) -> some View {
        fullScreenCover(isPresented: showMultiCrop) {
            MultiCropView(
                images: Binding(
                    get: { capturedItems.wrappedValue.map { $0.image } },
                    set: { _ in }
                ),
                croppedImages: croppedImages
            )
            .interactiveDismissDisabled(true)
            .onDisappear {
                Task {
                    if !didRunOCR.wrappedValue, let stitched = stitchImagesVertically(croppedImages.wrappedValue) {
                        await runOCR(stitched)
                        didRunOCR.wrappedValue = true
                    }
                    capturedItems.wrappedValue.removeAll()
                }
            }
        }
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

func stitchImagesVertically(_ images: [UIImage]) -> UIImage? {
        guard !images.isEmpty else { return nil }
        
        // Find the max width
        let maxWidth = images.map { $0.size.width }.max() ?? 0
        
        // Calculate total height after scaling images proportionally to maxWidth
        let totalHeight = images.reduce(0) { total, image in
            let scaleFactor = maxWidth / image.size.width
            return total + (image.size.height * scaleFactor)
        }
        
        // Begin graphics context
        UIGraphicsBeginImageContextWithOptions(CGSize(width: maxWidth, height: totalHeight), false, 0)
        
        var yOffset: CGFloat = 0
        for image in images {
            let scaleFactor = maxWidth / image.size.width
            let newHeight = image.size.height * scaleFactor
            image.draw(in: CGRect(x: 0, y: yOffset, width: maxWidth, height: newHeight))
            yOffset += newHeight
        }
        
        let stitchedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return stitchedImage
    }


