//
//  ReceiptDetailView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 11/19/25.
//


import SwiftUI
import FirebaseStorage

struct ReceiptDetailView: View {
    let receipt: Receipt

    @State private var receiptImage: UIImage?
    @State private var isLoadingImage = false
    @State private var imageErrorMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                // MARK: - Image at top
                imageSection

                // MARK: - Store + date + category
                storeInfoSection

                Divider()

                // MARK: - Totals
                totalsSection

                // Optional: createdAt / metadata
                metadataSection
            }
            .padding()
        }
        .navigationTitle("Receipt Details")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadImage() }
    }
}

// MARK: - Subviews
private extension ReceiptDetailView {

    var imageSection: some View {
        Group {
            if let img = receiptImage {
                Image(uiImage: img)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 14))
                    .shadow(radius: 4)
            } else if isLoadingImage {
                ProgressView("Loading image...")
            } else if let error = imageErrorMessage {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                    Text("Error loading image:")
                        .font(.headline)
                    Text(error)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                }
                .foregroundColor(.red)
            } else {
                RoundedRectangle(cornerRadius: 14)
                    .fill(.secondary.opacity(0.1))
                    .frame(height: 200)
                    .overlay(
                        VStack {
                            Image(systemName: "photo")
                                .font(.largeTitle)
                                .foregroundColor(.secondary)
                            Text("No Image Available")
                                .foregroundColor(.secondary)
                        }
                    )
            }
        }
    }

    var storeInfoSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(receipt.storeName)
                .font(.title.bold())

            Text(receipt.date, style: .date)
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Category: \(receipt.category)")
                .font(.subheadline)
                .foregroundColor(.primary.opacity(0.7))
        }
    }

    var totalsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Receipt Summary")
                .font(.headline)

            HStack {
                Text("Tax")
                Spacer()
                Text("$\(receipt.tax, specifier: "%.2f")")
                    .bold()
            }

            HStack {
                Text("Total Amount")
                Spacer()
                Text("$\(receipt.totalAmount, specifier: "%.2f")")
                    .font(.title3.bold())
            }
        }
    }

    var metadataSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Created:")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(receipt.createdAt, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Helpers
private extension ReceiptDetailView {

    func loadImage() async {
        guard let urlString = receipt.imageUrl else {
            imageErrorMessage = "Missing image URL."
            return
        }

        isLoadingImage = true
        defer { isLoadingImage = false }

        do {
            let ref = Storage.storage().reference(forURL: urlString)

            // Wrap callback API in async/await
            let data: Data = try await withCheckedThrowingContinuation { continuation in
                ref.getData(maxSize: 20_000_000) { data, error in
                    if let error = error {
                        continuation.resume(throwing: error)
                    } else if let data = data {
                        continuation.resume(returning: data)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "ImageLoad",
                            code: -1,
                            userInfo: [NSLocalizedDescriptionKey: "Unknown image error"]
                        ))
                    }
                }
            }

            if let img = UIImage(data: data) {
                self.receiptImage = img
            } else {
                imageErrorMessage = "Invalid image data."
            }

        } catch {
            imageErrorMessage = error.localizedDescription
        }
    }

}
