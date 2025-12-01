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

// MARK: - Helper Structs
// These must be defined outside of ScanView so the compiler can find them.

struct CapturedImageItem: Identifiable {
    let id = UUID()
    let image: UIImage
}

struct CenterReticle: View {
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

// MARK: - Main View

struct ScanView: View {
    @StateObject private var camera = CameraController()
    @State private var showCamera = false

    // Capture and crop flow
    @State private var capturedItem: CapturedImageItem?
    @State private var croppedImage: UIImage?
    @State private var didSkipCrop = false

    // OCR
    @State private var ocrDocument: ReceiptDocument?
    private let ocrService = OCRService()

    // Confirmation
    @State private var showConfirm = false
    @State private var isUploading = false
    @State private var uploadErrorMessage: String?

    // MARK: - Main Body
    var body: some View {
        ZStack {
            if showCamera {
                activeCameraLayer
            } else {
                landingLayer
            }
        }
        .navigationTitle("Scan")
        // --- MODIFIERS ---
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
        .fullScreenCover(item: $capturedItem, onDismiss: handleCropDismiss) { item in
            cropView(for: item)
        }
        // Present the editor right after OCR instead of the debug view
        .sheet(item: $ocrDocument) { doc in
            NavigationStack {
                EditReceiptView(
                    original: doc,
                    onCancel: { ocrDocument = nil },
                    onSaveAndUpload: { updated in
                        Task { await saveEditedReceiptFromScan(updated) }
                    }
                )
            }
        }
        .confirmationDialog(
            "Upload this receipt?",
            isPresented: Binding(
                get: { showConfirm && ocrDocument == nil },
                set: { showConfirm = $0 }
            ),
            titleVisibility: .visible
        ) {
            uploadConfirmationButtons
        } message: {
            Text("Make sure the receipt is clearly visible and readable.")
        }
    }
}

// MARK: - Subviews & Logic Components extension
extension ScanView {
    
    // 1. The Screen when camera is NOT active
    private var landingLayer: some View {
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
        .navigationBarBackButtonHidden(false)
        .toolbar(.automatic, for: .navigationBar)
        .toolbar(.automatic, for: .tabBar)
    }

    // 2. The Active Camera Screen
    private var activeCameraLayer: some View {
        ZStack {
            // Full-screen camera preview
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea(.all)

            // Center reticle
            CenterReticle()

            // Controls Overlay
            cameraControlsOverlay
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
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(.hidden, for: .tabBar)
    }

    // 3. The Buttons/Tip inside the Camera Screen
    private var cameraControlsOverlay: some View {
        VStack {
            // Tip
            Text("Tip: Place receipt on a dark background for best results.")
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, 12)
            
            Spacer()

            // Bottom controls
            ZStack {
                // Capture button centered
                captureButton

                // Close button bottom-right
                HStack {
                    Spacer()
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
            }
            .padding(.horizontal, 34)
            .padding(.bottom, 24)
        }
    }

    // 4. The Logic-heavy Capture Button
    private var captureButton: some View {
        Button {
            Task {
                do {
                    // Capture photo
                    let image = try await camera.capturePhoto()

                    // Update state synchronously on main actor
                    await MainActor.run {
                        didSkipCrop = false
                        croppedImage = nil
                        capturedItem = CapturedImageItem(image: image)
                    }

                    // Stop session
                    camera.stopSession()
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
    }
    
    // 5. Crop View Builder
    private func cropView(for item: CapturedImageItem) -> some View {
        // NOTE: If you get "Extra argument 'onSkip'" here, it means your CropView.swift
        // definition doesn't have an 'onSkip' parameter. You can delete the `onSkip:` block below if needed.
        CropView(
            image: item.image,
            onCancel: {
                didSkipCrop = false
                croppedImage = nil
                capturedItem = nil
                if showCamera { camera.startSession() }
            },
            onCropped: { result in
                didSkipCrop = false
                croppedImage = result
                capturedItem = nil
                Task { await runOCR(on: result) }
            }
        )
        .interactiveDismissDisabled(true)
    }

    // 6. Upload Confirmation Buttons
    @ViewBuilder
    private var uploadConfirmationButtons: some View {
        Button(isUploading ? "Uploading..." : "Upload") {
            Task { await uploadFinalImage() }
        }.disabled(isUploading)

        Button("Retake", role: .destructive) {
            didSkipCrop = false
            croppedImage = nil
            capturedItem = nil
            showConfirm = false
            if showCamera {
                camera.startSession()
            } else {
                withAnimation { showCamera = true }
            }
        }

        Button("Cancel", role: .cancel) { }
    }
    
    // MARK: - Logic Helpers
    
    private func handleCropDismiss() {
        if croppedImage != nil || didSkipCrop {
            showConfirm = true
        } else {
            if showCamera { camera.startSession() }
        }
    }
    
    private func waitUntilSessionRunning(timeout: TimeInterval = 1.0) async {
        let start = Date()
        while !camera.isSessionRunning && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    private func runOCR(on image: UIImage) async {
        do {
            let doc = try await ocrService.process(image: image)
            // Ensure UI update happens on Main Thread to PREVENT FREEZING
            await MainActor.run {
                ocrDocument = doc
            }
        } catch {
            await MainActor.run {
                uploadErrorMessage = "OCR failed: \(error.localizedDescription)"
            }
        }
    }

    // Called from the editor's Upload button when scanning a new receipt
    private func saveEditedReceiptFromScan(_ updated: ReceiptDocument) async {
        // Make sure we have an image to upload
        guard let imageToUpload = croppedImage ?? capturedItem?.image else {
            await MainActor.run {
                uploadErrorMessage = "Missing image to upload."
            }
            return
        }
        // Validate auth
        guard let uid = Auth.auth().currentUser?.uid else {
            await MainActor.run {
                uploadErrorMessage = "Not signed in."
            }
            return
        }
        // Build Firestore payload from edited document
        guard let payload = updated.makeFirestorePayload(defaultCategory: "Uncategorized", folderID: nil) else {
            await MainActor.run {
                uploadErrorMessage = "Missing required fields (Store, Total, Date)."
            }
            return
        }

        do {
            let uploader = ReceiptUploader()
            // Create a Firestore doc to get an ID
            let receiptId = try await uploader.createReceiptDocument(
                forUser: uid,
                storeName: payload.storeName
            )
            // Upload the image to Storage using that ID
            let url = try await uploader.uploadReceiptImage(
                imageToUpload,
                forUser: uid,
                receiptId: receiptId
            )
            // Update the Firestore doc with the edited fields and image URL
            let firestore = FirestoreService()
            try await firestore.updateReceipt(
                id: receiptId,
                with: payload,
                imageURL: url
            )

            await MainActor.run {
                didSkipCrop = false
                croppedImage = nil
                capturedItem = nil
                ocrDocument = nil
                showConfirm = false
                withAnimation { showCamera = false }
            }
        } catch {
            await MainActor.run {
                uploadErrorMessage = error.localizedDescription
            }
        }
    }

    private func uploadFinalImage() async {
        guard !isUploading else { return }
        guard let imageToUpload = croppedImage ?? capturedItem?.image else { return }
        isUploading = true
        defer { isUploading = false }

        do {
            guard let uid = Auth.auth().currentUser?.uid else {
                uploadErrorMessage = "Not signed in."
                return
            }
            
            let uploader = ReceiptUploader()
            let receiptId = try await uploader.createReceiptDocument(
                forUser: uid,
                storeName: "Scanned Receipt"
            )
            
            let _ = try await uploader.uploadReceiptImage(
                imageToUpload,
                forUser: uid,
                receiptId: receiptId
            )

            try await Task.sleep(nanoseconds: 300_000_000)
            
            await MainActor.run {
                didSkipCrop = false
                croppedImage = nil
                capturedItem = nil
                showConfirm = false
                withAnimation { showCamera = false }
            }
        } catch {
            await MainActor.run {
                uploadErrorMessage = error.localizedDescription
            }
        }
    }
}

#Preview {
    NavigationStack { ScanView() }
}
