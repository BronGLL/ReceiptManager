//
//  ReceiptUploader.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 11/5/25.
//

import Foundation
import UIKit
import FirebaseStorage
import FirebaseAuth
import FirebaseFirestore

@MainActor
final class ReceiptUploader {

    private let storage = Storage.storage()
    private let db = Firestore.firestore()
    
    // Uploads the receipt image to Firebase Storage returning its url
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
        return try await ref.downloadURL()
    }
}
