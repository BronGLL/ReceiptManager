//
//  FirestoreService.swift
//  ReceiptManagerIOSApp
//
//  Created by Michael Tong on 11/3/25.
//
import Foundation
import FirebaseFirestore
import FirebaseAuth

struct Receipt: Codable, Identifiable {
    @DocumentID var id: String?
    var category: String
    var storeName: String
    var date: Date
    var extractedText: String
    var tax: Double
    var totalAmount: Double
    var createdAt: Date
    var folderId: String?
    var imageUrl: String?
    var ocrDocument: String?
}

class FirestoreService {
    private let db = Firestore.firestore()
    
    func createReceiptFromOCR(
            ocr: ReceiptDocument,
            payload: ReceiptDocument.FirestorePayload,
            imageURL: URL,
            folderId: String?
        ) async throws -> String {

            guard let userId = Auth.auth().currentUser?.uid else {
                throw NSError(domain: "FirestoreService", code: 401,
                              userInfo: [NSLocalizedDescriptionKey: "User not logged in"])
            }

            let receiptsRef = db
                .collection("users")
                .document(userId)
                .collection("receipts")

            let docRef = receiptsRef.document()

            // Encode full OCR document
            let encodedReceiptData = try JSONEncoder().encode(ocr)
            let encodedReceiptString = encodedReceiptData.base64EncodedString()

            var data: [String: Any] = [
                "storeName": payload.storeName,
                "category": payload.receiptCategory,
                "totalAmount": payload.totalAmount,
                "tax": payload.tax,
                "date": Timestamp(date: payload.date),
                "extractedText": payload.extractedText,
                "ocrDocument": encodedReceiptString,
                "folderId": folderId ?? NSNull(),
                "imageUrl": imageURL.absoluteString,
                "createdAt": Timestamp(date: Date()),
                "updatedAt": Timestamp(date: Date())
            ]

            try await docRef.setData(data)
            return docRef.documentID
        }
    
    func addReceipt(
        storeName: String,
        totalAmount: Double,
        date: Date,
        receiptCategory: String,
        tax: Double,
        extractedText: String,
        folderID: String? = nil
    ) async throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(
                domain: "FirestoreService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "User not logged in"]
            )
        }

        var receiptData: [String: Any] = [
            "category": receiptCategory,
            "storeName": storeName,
            "date": Timestamp(date: date),
            "extractedText": extractedText,
            "tax": tax,
            "totalAmount": totalAmount,
            "createdAt": Timestamp(date: Date())
        ]

        if let folderID = folderID {
            receiptData["folderId"] = folderID
        } else {
            receiptData["folderId"] = NSNull()
        }

        try await db
            .collection("users")
            .document(userId)
            .collection("receipts")
            .addDocument(data: receiptData)
    }
    
    func addFolder(name: String, description: String) async throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FirestoreService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "User not logged in"])
        }

        let folderData: [String: Any] = [
            "name": name,
            "description": description,
            "createdAt": Timestamp(date: Date())
        ]

        try await db
            .collection("users")
            .document(userId)
            .collection("folders")
            .addDocument(data: folderData)
    }
    
    struct FolderData {
            let id: String
            let name: String
            let description: String
        }

    func fetchFolders() async throws -> [FolderData] {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FirestoreService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "User not logged in"])
        }

        let snapshot = try await db
            .collection("users")
            .document(userId)
            .collection("folders")
            .getDocuments()

        return snapshot.documents.map { doc in
            FolderData(
                id: doc.documentID,
                name: doc["name"] as? String ?? "Unnamed",
                description: doc["description"] as? String ?? ""
            )
        }
    }
    
    func deleteFolder(folderId: String) async throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FirestoreService", code: 1, userInfo: [NSLocalizedDescriptionKey: "User not signed in"])
        }
        
        let folderRef = db.collection("users").document(userId).collection("folders").document(folderId)
        try await folderRef.delete()
    }
    // Fetch all receipts
    func fetchReceipts() async throws -> [Receipt] {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FirestoreService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "User not logged in"])
        }

        let snapshot = try await db
            .collection("users")
            .document(userId)
            .collection("receipts")
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            try? doc.data(as: Receipt.self)
        }
    }
    
    func fetchReceipts(inFolder folderId: String) async throws -> [Receipt] {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FirestoreService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "User not logged in"])
        }

        let snapshot = try await db
            .collection("users")
            .document(userId)
            .collection("receipts")
            .whereField("folderId", isEqualTo: folderId)
            .order(by: "createdAt", descending: true)
            .getDocuments()

        return snapshot.documents.compactMap { doc in
            try? doc.data(as: Receipt.self)
        }
    }

    // Move receipt to a folder
    func moveReceipt(_ receiptId: String, toFolder folderId: String?) async throws {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(domain: "FirestoreService", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "User not logged in"])
        }

        let ref = db
            .collection("users")
            .document(userId)
            .collection("receipts")
            .document(receiptId)

        try await ref.updateData([
            "folderId": folderId ?? NSNull()
        ])
    }
    
    func fetchReceiptDetail(id: String) async throws -> Receipt {
        guard let userId = Auth.auth().currentUser?.uid else {
            throw NSError(
                domain: "FirestoreService",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "User not logged in"]
            )
        }

        let doc = try await db
            .collection("users")
            .document(userId)
            .collection("receipts")
            .document(id)
            .getDocument()

        guard let receipt = try? doc.data(as: Receipt.self) else {
            throw NSError(
                domain: "FirestoreService",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "Receipt not found"]
            )
        }

        return receipt
    }

}

