//
//  ScanView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI

struct ScanView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.viewfinder")
                .resizable()
                .scaledToFit()
                .frame(height: 120)
                .foregroundStyle(.tint)

            Text("Scan Receipts")
                .font(.title)
                .fontWeight(.semibold)

            Text("Use your iPhone camera to capture receipt images. In a future release, we’ll extract totals, dates, and vendors using on-device or server-side processing.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            Button {
                // Placeholder: camera capture action will go here.
            } label: {
                Label("Open Camera", systemImage: "camera")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal)
        }
        .padding()
        .navigationTitle("Scan")
    }
}

#Preview {
    NavigationStack { ScanView() }
}
