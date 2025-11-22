//
//  ScanView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
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
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var imagesToProcess: [UIImage] = []
    @State private var croppedImages: [UIImage] = []
    @State private var showingMultiCrop = false


    // MARK: - Confirmation & Upload
    @State private var showConfirm = false
    @State private var isUploading = false
    @State private var uploadErrorMessage: String?

    var body: some View {
        ZStack {
            cameraView
            landingView
        }
        .navigationTitle("Scan")
        .statusBarHidden(true)
        .alert("Camera Access Needed", isPresented: Binding(
            get: { camera.lastError == .unauthorized },
            set: { _ in }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enable camera access in Settings to scan receipts.")
        }
        .alert("Error", isPresented: Binding(
            get: { uploadErrorMessage != nil },
            set: { newValue in if !newValue { uploadErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { uploadErrorMessage = nil }
        } message: {
            Text(uploadErrorMessage ?? "Unknown error")
        }

        // Multi-image crop
        .fullScreenCover(isPresented: $showingMultiCrop) {
            MultiCropView(
                images: $imagesToProcess,
                croppedImages: $croppedImages
            )
            .onDisappear {
                // Only show confirmation if we have cropped images
                if !croppedImages.isEmpty {
                    showConfirm = true
                } else if !imagesToProcess.isEmpty {
                    // fallback: no crop done, use original images
                    croppedImages = imagesToProcess
                    showConfirm = true
                }

                // Clear imagesToProcess; croppedImages will be used for upload
                imagesToProcess = []
                hasRunOCR = false
            }
        }        // Trigger OCR after croppedImages update
        .onChange(of: croppedImages) { oldValue, newValue in
            guard !newValue.isEmpty, !hasRunOCR else { return }
            hasRunOCR = true
            Task { await runOCROnAllCroppedImages() }
        }

//        // Show OCR debug sheet
//        .sheet(item: $ocrDocument) { doc in
//            OCRDebugView(document: doc)
//        }
        
        .confirmationDialog("Upload this receipt?", isPresented: $showConfirm, titleVisibility: .visible) {
            Button(isUploading ? "Uploading..." : "Upload") { Task { await uploadFinalImages() } }
                .disabled(isUploading)
            Button("Retake", role: .destructive, action: retakeReceipt)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Make sure the receipt is clearly visible and readable.")
        }
    }

    // MARK: - Camera View
    @ViewBuilder
    private var cameraView: some View {
        if showCamera {
            ZStack {
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea()

                CenterReticle()

                // Top buttons: Cancel (left) and Crop Receipt (right)
                VStack {
                    HStack {
                        // Cancel button
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
                                // Thumbnail: last captured image or placeholder
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
                                    // Placeholder
                                    Rectangle()
                                        .fill(Color.white.opacity(0.2))
                                        .frame(width: 50, height: 50)
                                        .cornerRadius(8)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 8)
                                                .stroke(Color.white.opacity(0.8), lineWidth: 1)
                                        )
                                }
                                
                                // Badge with number of photos taken
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

                // Bottom centered capture button
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

                Button {
                    // TO DO
                } label: {
                    Label("Choose From Library", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
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
                imagesToProcess.append(image) // <- accumulate for multicrop
            }
        } catch {
            await MainActor.run { uploadErrorMessage = error.localizedDescription }
        }
    }


    // MARK: - OCR
    private func finishReceiptOCR() {
        guard !croppedImages.isEmpty else { return }
        Task { await runOCROnAllCroppedImages() }
    }

    private func runOCROnAllCroppedImages() async {
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
        await MainActor.run {
            ocrDocument = mergedDoc
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
    
    // MARK: - Upload & Retake
    private func uploadFinalImages() async {
        guard !isUploading, !croppedImages.isEmpty else { return }
        isUploading = true
        defer { isUploading = false }

        do {
            guard let uid = Auth.auth().currentUser?.uid else {
                uploadErrorMessage = "Not signed in."
                return
            }

            let uploader = ReceiptUploader()
            let receiptId = try await uploader.createReceiptDocument(forUser: uid, storeName: "Scanned Receipt")
            
            // Stitch images
            if let finalImage = stitchImagesVertically(croppedImages) {
                _ = try await uploader.uploadReceiptImage(finalImage, forUser: uid, receiptId: receiptId)
            }

            // ✅ Reset everything for next receipt
            croppedImages.removeAll()
            imagesToProcess.removeAll()
            showConfirm = false
            hasRunOCR = false
            withAnimation { showCamera = false }
            camera.startSession()
        } catch {
            uploadErrorMessage = error.localizedDescription
        }
    }

    private func retakeReceipt() {
        croppedImages = []
        imagesToProcess = []
        showConfirm = false
        hasRunOCR = false
        withAnimation { showCamera = true }
        camera.startSession()
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
        }
        .allowsHitTesting(false)
    }
}
