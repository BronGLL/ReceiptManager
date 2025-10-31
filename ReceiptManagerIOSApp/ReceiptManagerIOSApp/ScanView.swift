//
//  ScanView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI
import AVFoundation

struct ScanView: View {
    @StateObject private var camera = CameraController()
    @State private var showCamera = false
    @State private var capturedImage: UIImage?

    var body: some View {
        VStack(spacing: 0) {
            if showCamera {
                ZStack {
                    // Live camera preview
                    CameraPreviewView(session: camera.session)
                        .ignoresSafeArea(edges: .bottom)

                    // Centering "+" reticle
                    CenterReticle()

                    // Dark background reminder
                    VStack {
                        Text("Tip: Place receipt on a dark background for best results.")
                            .font(.subheadline)
                            .padding(10)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.top, 16)
                        Spacer()
                    }
                }
                .onAppear {
                    Task {
                        await camera.checkPermissions()
                        if camera.isAuthorized {
                            await camera.configureSession()
                            camera.startSession()
                        }
                    }
                }
                .onDisappear {
                    camera.stopSession()
                }
                .toolbar {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button {
                            Task {
                                do {
                                    let image = try await camera.capturePhoto()
                                    capturedImage = image
                                    // Optional: stop session when captured
                                    camera.stopSession()
                                } catch {
                                    // You can handle error UI if desired
                                }
                            }
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.white)
                                    .frame(width: 66, height: 66)
                                Circle()
                                    .stroke(.black.opacity(0.8), lineWidth: 2)
                                    .frame(width: 74, height: 74)
                            }
                        }
                        .accessibilityLabel("Capture Photo")

                        Spacer()

                        Button {
                            withAnimation { showCamera = false }
                        } label: {
                            Label("Close", systemImage: "xmark.circle.fill")
                        }
                        .tint(.primary)
                    }
                }
            } else {
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

                    if let image = capturedImage {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Last Capture")
                                .font(.headline)
                            Image(uiImage: image)
                                .resizable()
                                .scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(.quaternary, lineWidth: 1)
                                )
                        }
                        .padding(.horizontal)
                    }
                }
                .padding()
            }
        }
        .navigationTitle("Scan")
        .alert("Camera Access Needed", isPresented: .constant(camera.lastError == .unauthorized)) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Please enable camera access in Settings to scan receipts.")
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
                // Vertical line
                Rectangle()
                    .fill(color.opacity(0.9))
                    .frame(width: thickness, height: 60)
                // Horizontal line
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
