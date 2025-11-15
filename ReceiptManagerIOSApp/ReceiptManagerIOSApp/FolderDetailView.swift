//
//  FolderDetailView.swift
//  ReceiptManagerIOSApp
//
//  Created by Michael Tong on 11/6/25.
//

import SwiftUI

struct FolderDetailView: View {
    let folder: FirestoreService.FolderData
    @State private var receipts: [Receipt] = []
    @State private var isLoading = false
    @State private var alertMessage: String?

    private let firestoreService = FirestoreService()

    var body: some View {
        List {
            if isLoading {
                ProgressView("Loading receipts...")
            } else if receipts.isEmpty {
                Text("No receipts found in this folder.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(receipts) { receipt in
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(receipt.storeName)
                                .font(.headline)
                            Text(receipt.date, style: .date)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("$\(receipt.totalAmount, specifier: "%.2f")")
                            .font(.headline)
                    }
                }
            }
        }
        .navigationTitle(folder.name)
        .onAppear {
            Task { await loadReceipts() }
        }
        .alert("Error", isPresented: Binding<Bool>(
            get: { alertMessage != nil },
            set: { _ in alertMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func loadReceipts() async {
        isLoading = true
        do {
            receipts = try await firestoreService.fetchReceipts(inFolder: folder.id)
        } catch {
            alertMessage = "Failed to load receipts: \(error.localizedDescription)"
        }
        isLoading = false
    }
}
