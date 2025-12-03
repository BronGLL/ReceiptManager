import SwiftUI
import UIKit

struct EditReceiptView: View {
    let original: ReceiptDocument
    var onCancel: () -> Void
    var onSaveAndUpload: (ReceiptDocument) -> Void

    @State private var storeName: String
    @State private var purchaseDate: Date

    // Time as both a string (to match your document model) and a Date for the picker UI
    @State private var purchaseTime: String
    @State private var purchaseTimeDate: Date

    @State private var paymentMethod: String

    // Totals as strings
    @State private var subtotalText: String
    @State private var taxText: String
    @State private var totalText: String

    @State private var items: [EditableItem]

    @State private var isValid = true
    @State private var validationMessage: String?

    // Focus handling for cursor placement
    enum FieldFocus: Hashable {
        case subtotal, tax, total
        case itemQty(UUID), itemUnit(UUID), itemTotal(UUID)
    }
    @FocusState private var focusedField: FieldFocus?
    // Keep a map of text field bridges to move caret
    @State private var textFieldRefs: [FieldFocus: WeakTextFieldRef] = [:]

    init(original: ReceiptDocument,
         onCancel: @escaping () -> Void,
         onSaveAndUpload: @escaping (ReceiptDocument) -> Void) {
        self.original = original
        self.onCancel = onCancel
        self.onSaveAndUpload = onSaveAndUpload

        // Prefill states
        _storeName = State(initialValue: original.store?.value ?? "")
        _purchaseDate = State(initialValue: original.date?.value ?? Date())

        let initialTimeString = original.time?.value ?? ""
        _purchaseTime = State(initialValue: initialTimeString)
        // Try parse a time (HH:mm) from string; default to now's time if not present
        let parsedTime = Self.parseTimeFromString(initialTimeString) ?? Date()
        _purchaseTimeDate = State(initialValue: parsedTime)

        _paymentMethod = State(initialValue: original.paymentMethod?.value ?? "")
        _subtotalText = State(initialValue: original.subtotal.map { moneyToString($0.value) } ?? "")
        _taxText = State(initialValue: original.tax.map { moneyToString($0.value) } ?? "")
        _totalText = State(initialValue: original.total.map { moneyToString($0.value) } ?? "")

        // Default quantity to "1" if missing
        let mappedItems = original.lineItems.map { EditableItem(from: $0) }
        _items = State(initialValue: mappedItems)
    }

    var body: some View {
        Form {
            Section("Store") {
                TextField("Store Name", text: $storeName)
            }

            Section("Purchase Details") {
                DatePicker("Date", selection: $purchaseDate, displayedComponents: .date)

                // Time picker similar to Date
                DatePicker("Time (optional)", selection: $purchaseTimeDate, displayedComponents: .hourAndMinute)
                    .onChange(of: purchaseTimeDate) { new in
                        // Defer to next run loop to avoid "Modifying state during view update"
                        DispatchQueue.main.async {
                            purchaseTime = Self.timeString(from: new)
                        }
                    }

                TextField("Payment Method (optional)", text: $paymentMethod)
            }

            Section("Totals") {
                // Persistent labels with trailing aligned text fields
                HStack {
                    Text("Subtotal (optional)")
                    Spacer()
                    caretControllableTextField(
                        placeholder: "0.00",
                        text: $subtotalText,
                        focusKey: .subtotal
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Tax (optional)")
                    Spacer()
                    caretControllableTextField(
                        placeholder: "0.00",
                        text: $taxText,
                        focusKey: .tax
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                }
                HStack {
                    Text("Total")
                    Spacer()
                    caretControllableTextField(
                        placeholder: "0.00",
                        text: $totalText,
                        focusKey: .total
                    )
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                }
            }
            // Allows guests to edit items in a receipt
            Section("Items") {
                if items.isEmpty {
                    Text("No items detected").foregroundStyle(.secondary)
                } else {
                    ForEach($items) { $item in
                        VStack(alignment: .leading, spacing: 8) {
                            TextField("Item name", text: $item.name)

                            HStack {
                                Text("Qty")
                                caretControllableTextField(
                                    placeholder: "1",
                                    text: $item.quantity,
                                    focusKey: .itemQty(item.id)
                                )
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                            }

                            HStack {
                                Text("Unit Price")
                                caretControllableTextField(
                                    placeholder: "0.00",
                                    text: $item.unitPrice,
                                    focusKey: .itemUnit(item.id)
                                )
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            }

                            HStack {
                                Text("Total Price")
                                caretControllableTextField(
                                    placeholder: computedTotalPlaceholder(for: item),
                                    text: $item.totalPrice,
                                    focusKey: .itemTotal(item.id)
                                )
                                .keyboardType(.decimalPad)
                                .multilineTextAlignment(.trailing)
                            }
                        }
                    }
                    .onDelete { idx in items.remove(atOffsets: idx) }
                }
                Button {
                    items.append(EditableItem.empty())
                } label: {
                    Label("Add Item", systemImage: "plus.circle")
                }
            }

            if let msg = validationMessage {
                Section {
                    Text(msg).foregroundStyle(.red)
                }
            }
        }
        .navigationTitle("Edit Receipt")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onCancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Upload") {
                    if let updated = buildEditedDocument() {
                        onSaveAndUpload(updated)
                    }
                }
                .disabled(!isFormValid())
            }
        }
        .onChange(of: storeName) { _ in _ = isFormValid() }
        .onChange(of: totalText) { _ in _ = isFormValid() }
        .onAppear { _ = isFormValid() }
        // When a field becomes focused, move caret to end once.
        .onChange(of: focusedField) { newFocus in
            guard let key = newFocus, let ref = textFieldRefs[key]?.textField else { return }
            moveCaretToEnd(ref)
        }
    }

    // MARK: - Helpers (UI)

    // Build a TextField that lets us capture its underlying UITextField for caret control
    private func caretControllableTextField(placeholder: String, text: Binding<String>, focusKey: FieldFocus) -> some View {
        ZStack(alignment: .trailing) {
            TextField(placeholder, text: text)
                .focused($focusedField, equals: focusKey)
                .background(UnderlyingUITextFieldCapture { uiTextField in
                    // Store a weak ref so we can move caret when focused
                    textFieldRefs[focusKey] = WeakTextFieldRef(textField: uiTextField)
                })
        }
    }

    // Compute a dynamic placeholder for total price when user hasn't typed one
    private func computedTotalPlaceholder(for item: EditableItem) -> String {
        if !item.totalPrice.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return item.totalPrice // user-entered stays as placeholder text
        }
        let q = Self.parseDouble(item.quantity) ?? 1.0
        let unit = parseMoney(item.unitPrice).map { NSDecimalNumber(decimal: $0).doubleValue } ?? 0.0
        let total = q * unit
        return total > 0 ? String(format: "%.2f", total) : "0.00"
    }

    private func moveCaretToEnd(_ tf: UITextField) {
        // Defer to ensure the field is active and has text
        DispatchQueue.main.async {
            let end = tf.endOfDocument
            tf.selectedTextRange = tf.textRange(from: end, to: end)
        }
    }

    // MARK: - Validation

    private func isFormValid() -> Bool {
        var errors: [String] = []
        if storeName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            errors.append("Store name is required.")
        }
        if parseMoney(totalText) == nil {
            errors.append("Total is required and must be a valid amount (e.g., 12.34).")
        }
        validationMessage = errors.first
        isValid = errors.isEmpty
        return isValid
    }

    // MARK: - Build final document

    private func buildEditedDocument() -> ReceiptDocument? {
        guard isFormValid() else { return nil }

        func wrapString(_ value: String, field: FieldType) -> DetectedString {
            DetectedString(value: value, rawText: value, confidence: 1.0, boundingBox: nil, candidates: [], fieldType: field, isUserVerified: true)
        }
        func wrapMoney(_ dec: Decimal, field: FieldType) -> DetectedMoney {
            let money = MoneyAmount.from(decimal: dec)
            return DetectedMoney(value: money, rawText: moneyToString(money), confidence: 1.0, boundingBox: nil, candidates: [], fieldType: field, isUserVerified: true)
        }
        func wrapDate(_ date: Date) -> DetectedDate {
            DetectedDate(value: date, rawText: ISO8601DateFormatter().string(from: date), confidence: 1.0, boundingBox: nil, candidates: [], fieldType: .date, isUserVerified: true)
        }

        let editedStore = wrapString(storeName, field: .storeName)
        let editedDate = wrapDate(purchaseDate)

        // Time: if string is empty but user picked a time, still save it; if they cleared, keep nil
        let trimmedTime = purchaseTime.trimmingCharacters(in: .whitespacesAndNewlines)
        let timeStringToSave: String? = trimmedTime.isEmpty ? Self.timeString(from: purchaseTimeDate) : trimmedTime
        let editedTime = timeStringToSave.map { wrapString($0, field: .time) }

        let editedPayment = paymentMethod.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : wrapString(paymentMethod, field: .paymentMethod)

        let editedSubtotal = parseMoney(subtotalText).map { wrapMoney($0, field: .subtotal) }
        let editedTax = parseMoney(taxText).map { wrapMoney($0, field: .tax) }
        guard let totalDec = parseMoney(totalText) else { return nil }
        let editedTotal = wrapMoney(totalDec, field: .total)

        let editedItems: [LineItem] = items.compactMap { e in
            let nameTrim = e.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !nameTrim.isEmpty else { return nil }
            let detName = wrapString(nameTrim, field: .itemName)

            // Quantity: default to 1 if empty/invalid
            let qtyValue: Double = Self.parseDouble(e.quantity) ?? 1.0
            let qtyDet = DetectedValue<Double>(value: qtyValue, rawText: String(format: "%g", qtyValue), confidence: 1.0, boundingBox: nil, candidates: [], fieldType: .itemQuantity, isUserVerified: true)

            // Unit price
            let unitPriceDec = parseMoney(e.unitPrice)
            let unitDet: DetectedMoney? = unitPriceDec.map { dec in
                DetectedMoney(value: MoneyAmount.from(decimal: dec), rawText: e.unitPrice, confidence: 1.0, boundingBox: nil, candidates: [], fieldType: .itemUnitPrice, isUserVerified: true)
            }

            // Total price: if user typed one, use it; else compute qty * unit
            let explicitTotalDec = parseMoney(e.totalPrice)
            let computedTotalDec: Decimal? = {
                guard explicitTotalDec == nil, let unitDec = unitPriceDec else { return nil }
                let unitNS = NSDecimalNumber(decimal: unitDec)
                let totalDouble = unitNS.doubleValue * qtyValue
                return Decimal(string: String(format: "%.2f", totalDouble))
            }()
            let totalDecToUse = explicitTotalDec ?? computedTotalDec

            let totalDet: DetectedMoney? = totalDecToUse.map { dec in
                let raw = explicitTotalDec != nil ? e.totalPrice : NSDecimalNumber(decimal: dec).stringValue
                return DetectedMoney(value: MoneyAmount.from(decimal: dec), rawText: raw, confidence: 1.0, boundingBox: nil, candidates: [], fieldType: .itemTotalPrice, isUserVerified: true)
            }

            return LineItem(name: detName, quantity: qtyDet, unitPrice: unitDet, totalPrice: totalDet)
        }

        var doc = original
        doc.store = editedStore
        doc.date = editedDate
        doc.time = editedTime
        doc.paymentMethod = editedPayment
        doc.subtotal = editedSubtotal
        doc.tax = editedTax
        doc.total = editedTotal
        doc.lineItems = editedItems
        doc.updatedAt = Date()
        return doc
    }

    // MARK: - Utilities

    private static func parseDouble(_ s: String) -> Double? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cleaned = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    private static func parseTimeFromString(_ s: String) -> Date? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Try common time formats
        let fmts = ["HH:mm", "h:mm a", "HH:mm:ss"]
        let df = DateFormatter()
        df.locale = Locale.current
        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: trimmed) {
                // Combine parsed time with "today" date
                var comps = Calendar.current.dateComponents([.hour, .minute, .second], from: d)
                let now = Date()
                let today = Calendar.current.dateComponents([.year, .month, .day], from: now)
                comps.year = today.year
                comps.month = today.month
                comps.day = today.day
                return Calendar.current.date(from: comps)
            }
        }
        return nil
    }

    private static func timeString(from date: Date) -> String {
        let df = DateFormatter()
        df.locale = Locale.current
        df.dateFormat = "HH:mm"
        return df.string(from: date)
    }
}

// MARK: - Helpers

private func parseMoney(_ s: String) -> Decimal? {
    let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let cleaned = trimmed
        .replacingOccurrences(of: "[^0-9,.-]", with: "", options: .regularExpression)
        .replacingOccurrences(of: ",", with: ".")
    return Decimal(string: cleaned)
}

private func moneyToString(_ money: MoneyAmount) -> String {
    let dec = Decimal(money.minorUnits) / 100
    return NSDecimalNumber(decimal: dec).stringValue
}

private struct EditableItem: Identifiable {
    let id = UUID()
    var name: String
    var quantity: String
    var unitPrice: String
    var totalPrice: String

    static func empty() -> EditableItem {
        // Default quantity "1" for new items
        EditableItem(name: "", quantity: "1", unitPrice: "", totalPrice: "")
    }

    init(name: String, quantity: String, unitPrice: String, totalPrice: String) {
        self.name = name
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.totalPrice = totalPrice
    }

    init(from item: LineItem) {
        self.name = item.name.value
        // Default quantity to "1" if missing
        if let q = item.quantity?.value {
            self.quantity = String(format: "%g", q)
        } else {
            self.quantity = "1"
        }
        if let up = item.unitPrice?.value {
            self.unitPrice = moneyToString(up)
        } else {
            self.unitPrice = ""
        }
        if let tp = item.totalPrice?.value {
            self.totalPrice = moneyToString(tp)
        } else {
            self.totalPrice = "" // leave empty to allow auto-compute
        }
    }
}

// MARK: - UITextField capture helpers

private final class WeakTextFieldRef {
    weak var textField: UITextField?
    init(textField: UITextField?) { self.textField = textField }
}

private struct UnderlyingUITextFieldCapture: UIViewRepresentable {
    var onResolve: (UITextField) -> Void

    func makeUIView(context: Context) -> UIView {
        ProbeView(onResolve: onResolve)
    }
    func updateUIView(_ uiView: UIView, context: Context) { }

    private final class ProbeView: UIView {
        let onResolve: (UITextField) -> Void
        init(onResolve: @escaping (UITextField) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            backgroundColor = .clear
        }
        required init?(coder: NSCoder) { fatalError() }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            resolve()
        }

        private func resolve() {
            guard let tf = findTextField(in: superview) else { return }
            onResolve(tf)
        }

        private func findTextField(in view: UIView?) -> UITextField? {
            guard let view = view else { return nil }
            if let tf = view as? UITextField { return tf }
            for sub in view.subviews {
                if let found = findTextField(in: sub) { return found }
            }
            return nil
        }
    }
}
