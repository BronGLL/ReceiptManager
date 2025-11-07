import SwiftUI

struct ReceiptsView: View {
    // MARK: - State
    @State private var showingFolderSheet = false
    @State private var showingMoveSheet = false
    @State private var newFolderName = ""
    @State private var newFolderDescription = ""
    @State private var alertMessage: String?
    @State private var isLoading = false
    @State private var folders: [FirestoreService.FolderData] = []
    @State private var receipts: [Receipt] = []
    @State private var selectedReceipt: Receipt?

    @Binding var selectedTab: ContentView.Tab

    private let firestoreService = FirestoreService()

    // MARK: - Body
    var body: some View {
        List {
            // MARK: - Receipts Section
            Section("Recent Receipts") {
                if receipts.isEmpty {
                    Text("No receipts yet. Add one below!")
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
                            VStack(alignment: .trailing) {
                                Text("$\(receipt.totalAmount, specifier: "%.2f")")
                                    .font(.headline)
                                if let folderId = receipt.folderId,
                                   let folderName = folders.first(where: { $0.id == folderId })?.name {
                                    Text(folderName)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedReceipt = receipt
                            showingMoveSheet = true
                        }
                    }
                }
            }

            // MARK: - Add Receipt Button
            Section {
                Button {
                    selectedTab = .scan
                } label: {
                    Label("Add Receipt", systemImage: "plus.circle")
                }
            }

            // MARK: - Folders Section
            Section("Folders") {
                ForEach(folders, id: \.id) { folder in
                    NavigationLink(destination: FolderDetailView(folder: folder)) {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.yellow)
                            VStack(alignment: .leading) {
                                Text(folder.name)
                                    .font(.headline)
                                Text(folder.description)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .onDelete(perform: deleteFolders)

                Button {
                    showingFolderSheet = true
                } label: {
                    Label("Create New Folder", systemImage: "plus.square")
                }
            }
        }
        .navigationTitle("Receipts")
        .onAppear {
            Task {
                await loadFolders()
                await loadReceipts()
            }
        }
        .alert("Firestore", isPresented: Binding<Bool>(
            get: { alertMessage != nil },
            set: { _ in alertMessage = nil }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(isPresented: $showingFolderSheet) {
            folderSheet
        }
        .sheet(isPresented: $showingMoveSheet) {
            if let selectedReceipt {
                moveReceiptSheet(for: selectedReceipt)
            }
        }
    }

    // MARK: - Folder Creation Sheet
    private var folderSheet: some View {
        VStack(spacing: 20) {
            Text("New Folder")
                .font(.headline)

            TextField("Folder Name", text: $newFolderName)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            TextField("Description", text: $newFolderDescription)
                .textFieldStyle(RoundedBorderTextFieldStyle())

            HStack {
                Button("Cancel") {
                    resetFolderSheet()
                }
                Spacer()
                Button("Create") {
                    Task {
                        await createFolder()
                    }
                }
                .disabled(newFolderName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.top)
        }
        .padding()
    }

    // MARK: - Move Receipt Sheet
    private func moveReceiptSheet(for receipt: Receipt) -> some View {
        NavigationStack {
            Form {
                Section("Move “\(receipt.storeName)” to Folder") {
                    Picker("Folder", selection: Binding<String?>(
                        get: { receipt.folderId },
                        set: { newFolderId in
                            Task {
                                await moveReceipt(receipt, to: newFolderId)
                                showingMoveSheet = false
                            }
                        }
                    )) {
                        Text("None").tag(String?.none)
                        ForEach(folders, id: \.id) { folder in
                            Text(folder.name).tag(Optional(folder.id))
                        }
                    }
                }
            }
            .navigationTitle("Assign Folder")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingMoveSheet = false }
                }
            }
        }
    }

    // MARK: - Folder & Receipt Actions
    private func createFolder() async {
        isLoading = true
        do {
            try await firestoreService.addFolder(
                name: newFolderName,
                description: newFolderDescription
            )
            alertMessage = "Folder created successfully!"
            resetFolderSheet()
            await loadFolders()
        } catch {
            print("Create folder error: \(error)")
            alertMessage = "Error: \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func loadFolders() async {
        do {
            folders = try await firestoreService.fetchFolders()
        } catch {
            alertMessage = "Failed to load folders: \(error.localizedDescription)"
        }
    }

    private func loadReceipts() async {
        do {
            receipts = try await firestoreService.fetchReceipts()
        } catch {
            alertMessage = "Failed to load receipts: \(error.localizedDescription)"
        }
    }

    private func moveReceipt(_ receipt: Receipt, to folderId: String?) async {
        guard let id = receipt.id else { return }
        do {
            try await firestoreService.moveReceipt(id, toFolder: folderId)
            await loadReceipts()
        } catch {
            alertMessage = "Failed to move receipt: \(error.localizedDescription)"
        }
    }

    private func deleteFolders(at offsets: IndexSet) {
        Task {
            for index in offsets {
                let folder = folders[index]
                do {
                    try await firestoreService.deleteFolder(folderId: folder.id)
                    folders.remove(at: index)
                } catch {
                    alertMessage = "Failed to delete folder: \(error.localizedDescription)"
                }
            }
        }
    }

    private func resetFolderSheet() {
        showingFolderSheet = false
        newFolderName = ""
        newFolderDescription = ""
    }
}

// MARK: - Preview
#Preview {
    NavigationStack {
        ReceiptsView(selectedTab: .constant(.receipts))
    }
}
