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

    // Editing existing receipt
    @State private var showingEdit = false
    @State private var workingReceipt: Receipt
    @State private var alertMessage: String?

    private let firestore = FirestoreService()

    init(receipt: Receipt) {
        self.receipt = receipt
        _workingReceipt = State(initialValue: receipt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {

                imageSection

                storeInfoSection

                Divider()

                totalsSection

                metadataSection
            }
            .padding()
        }
        .navigationTitle("Receipt Details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { showingEdit = true }
            }
        }
        .task { await loadImage() }
        .sheet(isPresented: $showingEdit) {
            NavigationStack {
                EditReceiptView(
                    original: makeReceiptDocument(from: workingReceipt),
                    onCancel: { showingEdit = false },
                    onSaveAndUpload: { updatedDoc in
                        Task { await saveEdits(updatedDoc) }
                    }
                )
            }
        }
        .alert("Update", isPresented: Binding(
            get: { alertMessage != nil },
            set: { _ in alertMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
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
            Text(workingReceipt.storeName)
                .font(.title.bold())

            Text(workingReceipt.date, style: .date)
                .font(.headline)
                .foregroundColor(.secondary)

            Text("Category: \(workingReceipt.category)")
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
                Text("$\(workingReceipt.tax, specifier: "%.2f")")
                    .bold()
            }

            HStack {
                Text("Total Amount")
                Spacer()
                Text("$\(workingReceipt.totalAmount, specifier: "%.2f")")
                    .font(.title3.bold())
            }
        }
    }

    var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Created")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(workingReceipt.createdAt, style: .date)
                .font(.caption2)
                .foregroundColor(.secondary)

            Text("Last Edited")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(workingReceipt.updatedAt, style: .date)    // <-- use the property directly
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Helpers
private extension ReceiptDetailView {

    func loadImage() async {
        guard let urlString = workingReceipt.imageUrl else {
            imageErrorMessage = "Missing image URL."
            return
        }

        isLoadingImage = true
        defer { isLoadingImage = false }

        do {
            let ref = Storage.storage().reference(forURL: urlString)

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

    func saveEdits(_ updated: ReceiptDocument) async {
        guard let id = workingReceipt.id else {
            alertMessage = "Missing receipt ID."
            return
        }
        // Build payload from edited doc. Keep existing category unless you want to expose editing it.
        let payload = updated.makeFirestorePayload(
            defaultCategory: workingReceipt.category,
            folderID: workingReceipt.folderId
        )
        guard let payload else {
            alertMessage = "Missing required fields (Store, Total, Date)."
            return
        }

        do {
            try await firestore.updateReceipt(id: id, with: payload, imageURL: workingReceipt.imageUrl.flatMap(URL.init(string:)))
            // Update local working receipt to reflect changes
            await MainActor.run {
                workingReceipt = Receipt(
                    id: workingReceipt.id,
                    category: payload.receiptCategory,
                    storeName: payload.storeName,
                    date: payload.date,
                    extractedText: payload.extractedText,
                    tax: payload.tax,
                    totalAmount: payload.totalAmount,
                    createdAt: workingReceipt.createdAt,
                    updatedAt: Date(),
                    folderId: payload.folderID,
                    imageUrl: workingReceipt.imageUrl,
                    ocrDocument: workingReceipt.ocrDocument
                )
                // If your Receipt struct includes updatedAt, update it here too.
                // workingReceipt.updatedAt = Date()
                showingEdit = false
                alertMessage = "Receipt updated."
            }
        } catch {
            await MainActor.run {
                alertMessage = "Update failed: \(error.localizedDescription)"
            }
        }
    }

    // Map Firestore Receipt -> ReceiptDocument for editing
    func makeReceiptDocument(from receipt: Receipt, tokens: [OcrToken] = []) -> ReceiptDocument {
        func detString(_ s: String?, field: FieldType) -> DetectedString? {
            guard let s = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return DetectedString(value: s, rawText: s, confidence: 1.0, boundingBox: nil, candidates: [], fieldType: field, isUserVerified: true)
        }
        func detMoney(_ d: Double?, field: FieldType) -> DetectedMoney? {
            guard let d = d else { return nil }
            let dec = Decimal(d)
            let money = MoneyAmount.from(decimal: dec)
            return DetectedMoney(value: money, rawText: NSDecimalNumber(decimal: dec).stringValue, confidence: 1.0, boundingBox: nil, candidates: [], fieldType: field, isUserVerified: true)
        }
        func detDate(_ date: Date?) -> DetectedDate? {
            guard let date = date else { return nil }
            return DetectedDate(value: date, rawText: ISO8601DateFormatter().string(from: date), confidence: 1.0, boundingBox: nil, candidates: [], fieldType: .date, isUserVerified: true)
        }

        return ReceiptDocument(
            rawText: receipt.extractedText,
            store: detString(receipt.storeName, field: .storeName),
            date: detDate(receipt.date),
            time: nil,
            paymentMethod: nil,
            subtotal: nil,
            tax: detMoney(receipt.tax, field: .tax),
            total: detMoney(receipt.totalAmount, field: .total),
            lineItems: [],
            additionalFields: [],
            tokens: tokens
        )
    }
}
