//
//  AddReceiptsView.swift
//  ReceiptManagerIOSApp
//
//  Created by Michael Tong on 11/6/25.
//

import SwiftUI

struct AddReceiptView: View {
    @State private var storeName = ""
    @State private var totalAmount = ""
    @State private var selectedFolderId: String? = nil
    @State private var folders: [FirestoreService.FolderData] = []
    @State private var isLoading = false
    @State private var alertMessage: String?

    private let firestoreService = FirestoreService()

    var body: some View {
        Form {
            Section("Receipt Details") {
                TextField("Store Name", text: $storeName)
                TextField("Total Amount", text: $totalAmount)
                    .keyboardType(.decimalPad)
            }

            Section("Assign to Folder") {
                if folders.isEmpty {
                    Text("No folders found.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Folder", selection: $selectedFolderId) {
                        Text("None").tag(String?.none)
                        ForEach(folders, id: \.id) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                }
            }

            Button("Save Receipt") {
                Task { await saveReceipt() }
            }
            .disabled(storeName.isEmpty || totalAmount.isEmpty)
        }
        .navigationTitle("Add Receipt")
        .onAppear {
            Task { await loadFolders() }
        }
        .alert("Firestore", isPresented: Binding<Bool>(
            get: { alertMessage != nil },
            set: { _ in alertMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    private func loadFolders() async {
        do {
            folders = try await firestoreService.fetchFolders()
        } catch {
            alertMessage = "Failed to load folders: \(error.localizedDescription)"
        }
    }

    private func saveReceipt() async {
        guard let total = Double(totalAmount) else {
            alertMessage = "Please enter a valid number for total."
            return
        }

        do {
            try await firestoreService.addReceipt(
                storeName: storeName,
                totalAmount: total,
                date: Date(),
                receiptCategory: "Uncategorized",
                tax: 0,
                extractedText: "",
                folderID: selectedFolderId
            )
            alertMessage = "Receipt added successfully!"
        } catch {
            alertMessage = "Error saving receipt: \(error.localizedDescription)"
        }
    }
}
