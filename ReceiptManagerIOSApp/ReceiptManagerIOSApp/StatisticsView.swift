//
//  StatisticsView.swift
//  ReceiptManagerIOSApp
//
//  Created by Bronsen Laine-Lasala on 10/17/25.
//

import SwiftUI

struct StatisticsView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                Image(systemName: "chart.bar.fill")
                    .resizable()
                    .scaledToFit()
                    .frame(height: 120)
                    .foregroundStyle(.tint)

                Text("Spending Overview")
                    .font(.title)
                    .fontWeight(.semibold)

                Text("This page will summarize spending by category, merchant, and time period using data extracted from your receipts.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                // Simple placeholder “cards”
                Group {
                    StatCard(title: "This Month", value: "$427.57", subtitle: "Oct 2025")
                    StatCard(title: "Top Merchant", value: "Safeway", subtitle: "$182.10")
                    StatCard(title: "Most Frequent Category", value: "Office Supplies", subtitle: "7 purchases")
                }
            }
            .padding()
        }
        .navigationTitle("Statistics")
    }
}

private struct StatCard: View {
    let title: String
    let value: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
            Text(subtitle)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary, lineWidth: 1)
        )
    }
}

#Preview {
    NavigationStack { StatisticsView() }
}
