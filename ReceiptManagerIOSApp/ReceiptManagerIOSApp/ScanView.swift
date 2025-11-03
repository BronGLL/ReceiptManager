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
                                    let image = try await camera.capturePhoto()
                                    capturedImage = image
                                    camera.stopSession()
                                } catch {
                                    // Handle error if desired
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
                    .padding(.bottom, 24) // lift above home indicator a bit
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
                // Fully hide bars while camera is visible
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
