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
    @State private var capturedItem: CapturedImageItem?
    @State private var croppedImage: UIImage?
    @State private var didSkipCrop = false

    // Confirmation
    @State private var showConfirm = false
    @State private var isUploading = false
    @State private var uploadErrorMessage: String?

    var body: some View {
        ZStack {
            if showCamera {
                // Full-screen camera preview
                CameraPreviewView(session: camera.session)
                    .ignoresSafeArea(.all)

                // Center reticle
                CenterReticle()

                // Tip at the top, within safe area
                VStack {
                    Text("Tip: Place receipt on a dark background for best results.")
                        .font(.subheadline)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.top, 12)
                    Spacer()
                }

                // Bottom controls: Capture centered, Close in bottom-right
                VStack {
                    Spacer()

                    ZStack {
                        // Capture button centered
                        Button {
                            Task {
                                do {
                                    // Capture photo
                                    let image = try await camera.capturePhoto()

                                    // Update state and present cropper synchronously on main actor
                                    await MainActor.run {
                                        didSkipCrop = false
                                        croppedImage = nil
                                        capturedItem = CapturedImageItem(image: image)
                                    }

                                    // Stop session immediately after scheduling presentation
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
                        .disabled(!camera.isSessionRunning) // prevent early tap before session is ready

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
                .onAppear {
                    Task {
                        await camera.checkPermissions()
                        if camera.isAuthorized {
                            await camera.configureSession()
                            camera.startSession()

                            // Optional: wait briefly for session to report running
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
            } else {
                // Landing content when camera is not shown
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
        }
        .navigationTitle("Scan")
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
        // Cropping UI using item-based presentation to ensure image is non-nil
        .fullScreenCover(item: $capturedItem, onDismiss: {
            // Only show confirmation if user explicitly cropped or explicitly skipped cropping.
            if croppedImage != nil || didSkipCrop {
                showConfirm = true
            } else {
                // User dismissed without action; resume camera if visible.
                if showCamera {
                    camera.startSession()
                }
            }
        }, content: { item in
            CropView(
                image: item.image,
                onCancel: {
                    // Explicit cancel: clear and return to camera without confirmation
                    didSkipCrop = false
                    croppedImage = nil
                    capturedItem = nil
                    if showCamera {
                        camera.startSession()
                    }
                },
                onSkip: {
                    // Explicit skip: use original and show confirmation
                    didSkipCrop = true
                    croppedImage = nil
                    capturedItem = nil
                },
                onCropped: { result in
                    // Explicit crop: use result and show confirmation
                    didSkipCrop = false
                    croppedImage = result
                    capturedItem = nil
                }
            )
            // Prevent accidental swipe-to-dismiss from bypassing explicit choice.
            .interactiveDismissDisabled(true)
        })
        // Confirmation prompt
        .confirmationDialog("Upload this receipt?", isPresented: $showConfirm, titleVisibility: .visible) {
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
        } message: {
            Text("Make sure the receipt is clearly visible and readable.")
        }
    }

    // Wait until the session is reported running (with a short timeout)
    private func waitUntilSessionRunning(timeout: TimeInterval = 1.0) async {
        let start = Date()
        while !camera.isSessionRunning && Date().timeIntervalSince(start) < timeout {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }
    }

    // MARK: - Upload Integration

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
            
            let url = try await uploader.uploadReceiptImage(
                imageToUpload,
                forUser: uid,
                receiptId: receiptId
            )

            
            try await Task.sleep(nanoseconds: 300_000_000)
            didSkipCrop = false
            croppedImage = nil
            capturedItem = nil
            showConfirm = false
            withAnimation { showCamera = false }
        } catch {
            uploadErrorMessage = error.localizedDescription
        }
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
