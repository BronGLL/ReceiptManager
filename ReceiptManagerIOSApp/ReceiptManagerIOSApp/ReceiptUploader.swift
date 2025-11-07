//
//  ReceiptUploader.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 11/5/25.
//

import Foundation
import UIKit
import FirebaseStorage
import FirebaseFirestore
import FirebaseAuth


@MainActor
final class ReceiptUploader {

    private let storage = Storage.storage()
    private let db = Firestore.firestore()

    func uploadReceiptImage(_ image: UIImage, forUser userId: String, receiptId: String) async throws -> URL {
        guard let imageData = image.jpegData(compressionQuality: 0.8) else {
            throw NSError(domain: "ReceiptUploader", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to convert UIImage to JPEG data."])
        }

        let path = "users/\(userId)/receipts/\(receiptId).jpg"
        let ref = storage.reference(withPath: path)

        _ = try await ref.putDataAsync(imageData, metadata: nil)

        let downloadURL = try await ref.downloadURL()

        try await db.collection("users")
            .document(userId)
            .collection("receipts")
            .document(receiptId)
            .updateData(["imageUrl": downloadURL.absoluteString])

        return downloadURL
    }

    /// Create a new Firestore receipt document (if not yet existing)
    /// before uploading the image. Returns the receipt document ID.
    func createReceiptDocument(forUser userId: String,
                               storeName: String,
                               category: String = "Uncategorized",
                               totalAmount: Double = 0.0,
                               tax: Double = 0.0) async throws -> String {
        let receiptsRef = db.collection("users").document(userId).collection("receipts")
        let docRef = receiptsRef.document()

        let data: [String: Any] = [
            "storeName": storeName,
            "category": category,
            "totalAmount": totalAmount,
            "tax": tax,
            "createdAt": FieldValue.serverTimestamp(),
            "imageUrl": ""
        ]

        try await docRef.setData(data)
        return docRef.documentID
    }
}
