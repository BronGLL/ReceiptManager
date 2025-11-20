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


    func upload(
        receipt: ReceiptDocument,
        image: UIImage,
        forUser userId: String,
        folderID: String? = nil
    ) async throws -> String {

        // Convert to Firestore payload
        guard let payload = receipt.makeFirestorePayload(folderID: folderID) else {
            throw NSError(
                domain: "ReceiptUploader",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Missing required OCR fields"]
            )
        }

        // Create Firestore doc ID first
        let receiptsRef = db.collection("users")
            .document(userId)
            .collection("receipts")

        let docRef = receiptsRef.document()

        // Encode full ReceiptDocument to JSON
        let encodedReceiptData = try JSONEncoder().encode(receipt)
        let encodedReceiptString = encodedReceiptData.base64EncodedString()

        // Build Firestore dictionary
        var data: [String: Any] = [
            "storeName": payload.storeName,
            "category": payload.receiptCategory,
            "totalAmount": payload.totalAmount,
            "tax": payload.tax,
            "date": payload.date,
            "extractedText": payload.extractedText,

            // Entire OCR document preserved
            "ocrDocument": encodedReceiptString,

            "folderID": payload.folderID ?? NSNull(),
            "createdAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp(),
            "imageUrl": "" // Filled after image upload
        ]

        // Write metadata FIRST
        try await docRef.setData(data)

        // Upload receipt image
        let downloadURL = try await uploadReceiptImage(
            image,
            forUser: userId,
            receiptId: docRef.documentID
        )

        // Patch the image URL
        try await docRef.updateData([
            "imageUrl": downloadURL.absoluteString,
            "updatedAt": FieldValue.serverTimestamp()
        ])

        return docRef.documentID
    }



    func uploadReceiptImage(
        _ image: UIImage,
        forUser userId: String,
        receiptId: String
    ) async throws -> URL {

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

}
