//
//  ReceiptsView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI

struct ReceiptsView: View {
    // Placeholder sample data
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

    var body: some View {
        List {
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

            Section {
                Button {
                    // Placeholder: import or add receipt
                } label: {
                    Label("Add Receipt", systemImage: "plus.circle")
                }
            }
        }
        .navigationTitle("Receipts")
    }
}

#Preview {
    NavigationStack { ReceiptsView() }
}
