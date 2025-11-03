import SwiftUI

struct ReceiptsView: View {
    // MARK: - State
    @State private var showingFolderSheet = false
    @State private var newFolderName = ""
    @State private var newFolderDescription = ""
    @State private var alertMessage: String?
    @State private var isLoading = false
    @State private var folders: [FirestoreService.FolderData] = []
    @Binding var selectedTab: ContentView.Tab
    
    private let firestoreService = FirestoreService()
    
    // MARK: - Placeholder receipts
    struct PlaceholderReceipt: Identifiable {
        let id = UUID()
        let merchant: String
        let date: String
        let total: String
    }

    let sampleReceipts: [PlaceholderReceipt] = [
        .init(merchant: "Safeway", date: "Oct 10, 2025", total: "$42.18"),
        .init(merchant: "Office Depot", date: "Oct 12, 2025", total: "$128.99"),
        .init(merchant: "Costco", date: "Oct 15, 2025", total: "$256.40")
    ]

    // MARK: - Body
    var body: some View {
        List {
            // Receipts Section
            Section("Recent Receipts") {
                ForEach(sampleReceipts) { receipt in
                    HStack {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.tint)
                        VStack(alignment: .leading) {
                            Text(receipt.merchant)
                                .font(.headline)
                            Text(receipt.date)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(receipt.total)
                            .font(.headline)
                    }
                    .contentShape(Rectangle())
                }
            }

            // Add Receipt button
            Section {
                Button {
                    selectedTab = .scan
                } label: {
                    Label("Add Receipt", systemImage: "plus.circle")
                }
            }

            // Folders Section
            Section("Folders") {
                ForEach(folders, id: \.id) { folder in
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
        .sheet(isPresented: $showingFolderSheet) {
            folderSheet
        }
    }

    // MARK: - Folder Sheet
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

    // MARK: - Folder Functions
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
            let fetched = try await firestoreService.fetchFolders()
            folders = fetched
        } catch {
            print("Load folders error: \(error)")
            alertMessage = "Failed to load folders: \(error.localizedDescription)"
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

#Preview {
    NavigationStack {
        ReceiptsView(selectedTab: .constant(.receipts))
    }
}
