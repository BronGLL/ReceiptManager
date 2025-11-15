import SwiftUI
// Debug View that shows the OCR text extracted from the recipt
// Also shows fields for things it itemizes, price/tax, and savings.
struct OCRDebugView: View {
    let document: ReceiptDocument

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    // shows the exact text produced by OCR for comparison
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Raw Recognized Text")
                            .font(.headline)
                        Text(document.rawText.isEmpty ? "(empty)" : document.rawText)
                            // Monospace for easy scanning and copy/paste
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .padding()
                            .background(.background, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                    }

                    // Creates the parsed sections block
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Parsed Sections")
                            .font(.headline)

                        ForEach(document.makeTableSections()) { section in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(section.title)
                                    .font(.subheadline)
                                    .fontWeight(.semibold)

                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { _, row in
                                    switch row {
                                        // key/value string for things like store name
                                    case .keyValueString(let key, let value):
                                        KeyValueRow(key: key, value: value?.value ?? "—")
                                        // Date value wrapped in DetectedDate function
                                    case .keyValueDate(let key, let value):
                                        KeyValueRow(key: key, value: value.map { DateFormatter.localizedString(from: $0.value, dateStyle: .medium, timeStyle: .none) } ?? "—")
                                        // Key/value for money amounts (floats)
                                    case .keyValueMoney(let key, let value):
                                        let moneyText: String = {
                                            guard let v = value?.value else { return "—" }
                                            let dec = Decimal(v.minorUnits) / 100
                                            return "$" + NSDecimalNumber(decimal: dec).stringValue
                                        }()
                                        KeyValueRow(key: key, value: moneyText)
                                        // Full line-item row: name, qty, price
                                    case .item(let item):
                                        VStack(alignment: .leading, spacing: 4) {
                                            // Output Item name
                                            Text("• \(item.name.value)")
                                            // Quantity parse, if needed
                                            if let qty = item.quantity?.value {
                                                Text("  Qty: \(qty)")
                                            }
                                            // Unit price
                                            if let unit = item.unitPrice?.value {
                                                let dec = Decimal(unit.minorUnits) / 100
                                                Text("  Unit: $\(NSDecimalNumber(decimal: dec).stringValue)")
                                            }
                                            // item price
                                            if let tot = item.totalPrice?.value {
                                                let dec = Decimal(tot.minorUnits) / 100
                                                Text("  Total: $\(NSDecimalNumber(decimal: dec).stringValue)")
                                            }
                                        }
                                    }
                                }
                            }
                            // Formatting the Debug screen
                            .padding()
                            .background(.background, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(.quaternary, lineWidth: 1)
                            )
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("OCR Debug")
        }
    }
}
// label : value row
private struct KeyValueRow: View {
    let key: String
    let value: String
    var body: some View {
        HStack {
            Text(key)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}
