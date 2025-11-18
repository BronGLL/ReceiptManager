import Foundation
import CoreGraphics

// A normalized rectangle in image coordinates where all values are in [0, 1]. FOr bounding boxes
public struct NormalizedRect: Codable, Equatable, Hashable {
    public var x: CGFloat
    public var y: CGFloat
    public var width: CGFloat
    public var height: CGFloat

    public init(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

// Cents (minor units)
public struct MoneyAmount: Codable, Equatable, Hashable {
    public var currencyCode: String
    public var minorUnits: Int64

    public init(currencyCode: String = "USD", minorUnits: Int64) {
        self.currencyCode = currencyCode
        self.minorUnits = minorUnits
    }

    // Dollars (major units)
    public var decimalValue: Decimal {
        Decimal(minorUnits) / 100
    }

    // Creates a MoneyAmount using major/minor units
    public static func from(decimal: Decimal, currencyCode: String = "USD") -> MoneyAmount {
        let nsDecimal = decimal as NSDecimalNumber
        let cents = (nsDecimal.multiplying(by: 100)).rounding(accordingToBehavior: nil)
        return MoneyAmount(currencyCode: currencyCode, minorUnits: cents.int64Value)
    }
}

// Tells the UI how to extract fields
public enum FieldType: String, Codable, CaseIterable {
    // Top-level store info
    case storeName
    case storeType
    case storeLocation

    // Purchase details
    case date
    case time
    case paymentMethod
    case transactionId

    // Totals
    case subtotal
    case tax
    case total

    // Line item fields
    case itemName
    case itemQuantity
    case itemUnitPrice
    case itemTotalPrice
    
    // Extras
    case address
    case phone
    case unknown
}

// Creating an alternative candidate value for a detected field
public struct Candidate<T: Codable & Equatable>: Codable, Equatable {
    public var value: T
    public var rawText: String
    public var confidence: Double

    public init(value: T, rawText: String, confidence: Double) {
        self.value = value
        self.rawText = rawText
        self.confidence = confidence
    }
}

// A detected/parsed value with OCR context and metadata.
public struct DetectedValue<T: Codable & Equatable>: Codable, Equatable {
    public var value: T
    // Keeps the OCR string
    public var rawText: String
    public var confidence: Double
    // Stores where on the image the value came from
    public var boundingBox: NormalizedRect?
    public var candidates: [Candidate<T>]
    public var fieldType: FieldType
    // For user to confirm the values
    public var isUserVerified: Bool

    public init(
        value: T,
        rawText: String,
        confidence: Double,
        boundingBox: NormalizedRect? = nil,
        candidates: [Candidate<T>] = [],
        fieldType: FieldType,
        isUserVerified: Bool = false
    ) {
        self.value = value
        self.rawText = rawText
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.candidates = candidates
        self.fieldType = fieldType
        self.isUserVerified = isUserVerified
    }
}

// Typealiases for common field types
public typealias DetectedString = DetectedValue<String>
public typealias DetectedDate = DetectedValue<Date>
public typealias DetectedMoney = DetectedValue<MoneyAmount>

// A raw OCR token needed to use Vision
public struct OcrToken: Codable, Equatable, Hashable {
    public var text: String
    public var confidence: Double
    public var boundingBox: NormalizedRect
    public var lineIndex: Int?
    public var wordIndex: Int?

    public init(
        text: String,
        confidence: Double,
        boundingBox: NormalizedRect,
        lineIndex: Int? = nil,
        wordIndex: Int? = nil
    ) {
        self.text = text
        self.confidence = confidence
        self.boundingBox = boundingBox
        self.lineIndex = lineIndex
        self.wordIndex = wordIndex
    }
}

// Line Items

// A single purchased item row
public struct LineItem: Codable, Equatable, Identifiable {
    public let id: UUID
    public var name: DetectedString
    // How many of an item
    public var quantity: DetectedValue<Double>?
    // What the unit price is
    public var unitPrice: DetectedMoney?
    // Combined prices of units
    public var totalPrice: DetectedMoney?

    public init(
        id: UUID = UUID(),
        name: DetectedString,
        quantity: DetectedValue<Double>? = nil,
        unitPrice: DetectedMoney? = nil,
        totalPrice: DetectedMoney? = nil
    ) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.unitPrice = unitPrice
        self.totalPrice = totalPrice
    }
}

// Receipt Document

// A full OCR-parsed receipt with both typed fields and raw OCR context.
public struct ReceiptDocument: Identifiable, Equatable, Codable {
    public let id: UUID
    // Normalizing screen overlays
    public var sourceImageSize: CGSize?
    // All recognized text
    public var rawText: String

    // Store Information
    public var store: DetectedString?
    public var storeType: DetectedString?
    public var storeLocation: DetectedString?

    // Purchase Details
    public var date: DetectedDate?
    public var time: DetectedString?
    public var paymentMethod: DetectedString?
    public var transactionId: DetectedString?

    // Totals
    public var subtotal: DetectedMoney?
    public var tax: DetectedMoney?
    public var total: DetectedMoney?

    // Purchased Items
    public var lineItems: [LineItem]

    // More metadata (discounts)
    public var additionalFields: [DetectedString]
    public var tokens: [OcrToken]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        sourceImageSize: CGSize? = nil,
        rawText: String,
        store: DetectedString? = nil,
        storeType: DetectedString? = nil,
        storeLocation: DetectedString? = nil,
        date: DetectedDate? = nil,
        time: DetectedString? = nil,
        paymentMethod: DetectedString? = nil,
        transactionId: DetectedString? = nil,
        subtotal: DetectedMoney? = nil,
        tax: DetectedMoney? = nil,
        total: DetectedMoney? = nil,
        lineItems: [LineItem] = [],
        additionalFields: [DetectedString] = [],
        tokens: [OcrToken] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.sourceImageSize = sourceImageSize
        self.rawText = rawText

        self.store = store
        self.storeType = storeType
        self.storeLocation = storeLocation

        self.date = date
        self.time = time
        self.paymentMethod = paymentMethod
        self.transactionId = transactionId

        self.subtotal = subtotal
        self.tax = tax
        self.total = total

        self.lineItems = lineItems
        self.additionalFields = additionalFields
        self.tokens = tokens
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    // Handle CGSize reliably
    private enum CodingKeys: String, CodingKey {
        case id
        case sourceImageWidth
        case sourceImageHeight
        case rawText

        case store
        case storeType
        case storeLocation

        case date
        case time
        case paymentMethod
        case transactionId

        case subtotal
        case tax
        case total

        case lineItems
        case additionalFields
        case tokens
        case createdAt
        case updatedAt
    }
    // Some image initlizations
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        // Reconstruct CGSize
        if let w = try c.decodeIfPresent(Double.self, forKey: .sourceImageWidth),
           let h = try c.decodeIfPresent(Double.self, forKey: .sourceImageHeight) {
            sourceImageSize = CGSize(width: w, height: h)
        } else {
            sourceImageSize = nil
        }

        rawText = try c.decode(String.self, forKey: .rawText)

        store = try c.decodeIfPresent(DetectedString.self, forKey: .store)
        storeType = try c.decodeIfPresent(DetectedString.self, forKey: .storeType)
        storeLocation = try c.decodeIfPresent(DetectedString.self, forKey: .storeLocation)

        date = try c.decodeIfPresent(DetectedDate.self, forKey: .date)
        time = try c.decodeIfPresent(DetectedString.self, forKey: .time)
        paymentMethod = try c.decodeIfPresent(DetectedString.self, forKey: .paymentMethod)
        transactionId = try c.decodeIfPresent(DetectedString.self, forKey: .transactionId)

        subtotal = try c.decodeIfPresent(DetectedMoney.self, forKey: .subtotal)
        tax = try c.decodeIfPresent(DetectedMoney.self, forKey: .tax)
        total = try c.decodeIfPresent(DetectedMoney.self, forKey: .total)

        lineItems = try c.decodeIfPresent([LineItem].self, forKey: .lineItems) ?? []
        additionalFields = try c.decodeIfPresent([DetectedString].self, forKey: .additionalFields) ?? []
        tokens = try c.decodeIfPresent([OcrToken].self, forKey: .tokens) ?? []
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        if let size = sourceImageSize {
            try c.encode(Double(size.width), forKey: .sourceImageWidth)
            try c.encode(Double(size.height), forKey: .sourceImageHeight)
        }
        try c.encode(rawText, forKey: .rawText)

        try c.encodeIfPresent(store, forKey: .store)
        try c.encodeIfPresent(storeType, forKey: .storeType)
        try c.encodeIfPresent(storeLocation, forKey: .storeLocation)

        try c.encodeIfPresent(date, forKey: .date)
        try c.encodeIfPresent(time, forKey: .time)
        try c.encodeIfPresent(paymentMethod, forKey: .paymentMethod)
        try c.encodeIfPresent(transactionId, forKey: .transactionId)

        try c.encodeIfPresent(subtotal, forKey: .subtotal)
        try c.encodeIfPresent(tax, forKey: .tax)
        try c.encodeIfPresent(total, forKey: .total)

        try c.encode(lineItems, forKey: .lineItems)
        try c.encode(additionalFields, forKey: .additionalFields)
        try c.encode(tokens, forKey: .tokens)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
    }
}

// UI Table

// A section for rendering the Receipt Document
public struct ReceiptTableSection: Equatable, Identifiable {
    public enum Kind: String {
        case storeInfo
        case purchaseDetails
        case items
        case totals
        case extras
    }

    public let id: UUID
    public var title: String
    public var kind: Kind
    public var rows: [ReceiptTableRow]

    public init(id: UUID = UUID(), title: String, kind: Kind, rows: [ReceiptTableRow]) {
        self.id = id
        self.title = title
        self.kind = kind
        self.rows = rows
    }
}

// A row in the UI table for key/value pair or full line item
public enum ReceiptTableRow: Equatable, Identifiable {
    case keyValueString(key: String, value: DetectedString?)
    case keyValueDate(key: String, value: DetectedDate?)
    case keyValueMoney(key: String, value: DetectedMoney?)
    case item(LineItem)
    // SwiftUI stable ID
    public var id: String {
        switch self {
        case .keyValueString(let key, _): return "kv.string.\(key)"
        case .keyValueDate(let key, _): return "kv.date.\(key)"
        case .keyValueMoney(let key, _): return "kv.money.\(key)"
        case .item(let item): return "item.\(item.id.uuidString)"
        }
    }
    // Comparing associated values
    public static func == (lhs: ReceiptTableRow, rhs: ReceiptTableRow) -> Bool {
        switch (lhs, rhs) {
        case let (.keyValueString(lk, lv), .keyValueString(rk, rv)):
            return lk == rk && lv == rv
        case let (.keyValueDate(lk, lv), .keyValueDate(rk, rv)):
            return lk == rk && lv == rv
        case let (.keyValueMoney(lk, lv), .keyValueMoney(rk, rv)):
            return lk == rk && lv == rv
        case let (.item(li), .item(ri)):
            return li == ri
        default:
            return false
        }
    }
}

// Mapping Helpers

public extension ReceiptDocument {
    // Build a set of sections for the debug UI.
    func makeTableSections() -> [ReceiptTableSection] {
        var sections: [ReceiptTableSection] = []

        // Store Information
        sections.append(
            ReceiptTableSection(
                title: "STORE INFORMATION",
                kind: .storeInfo,
                rows: [
                    .keyValueString(key: "Store Name", value: self.store),
                    .keyValueString(key: "Store Type", value: self.storeType)
                ]
            )
        )

        // Purchase Details
        sections.append(
            ReceiptTableSection(
                title: "PURCHASE DETAILS",
                kind: .purchaseDetails,
                rows: [
                    .keyValueDate(key: "Purchase Date", value: self.date),
                    .keyValueString(key: "Purchase Time", value: self.time),
                    .keyValueString(key: "Payment Method", value: self.paymentMethod)
                ]
            )
        )

        // Items
        sections.append(
            ReceiptTableSection(
                title: "PURCHASED ITEMS",
                kind: .items,
                rows: self.lineItems.map { .item($0) }
            )
        )

        // Totals
        sections.append(
            ReceiptTableSection(
                title: "TOTALS",
                kind: .totals,
                rows: [
                    .keyValueMoney(key: "Tax", value: self.tax),
                    .keyValueMoney(key: "Total", value: self.total)
                ]
            )
        )

        // Discounts and Savings if needed
        if !self.additionalFields.isEmpty {
            let rows = self.additionalFields.enumerated().map { idx, field in
                ReceiptTableRow.keyValueString(key: "Discount \(idx + 1)", value: field)
            }
            sections.append(
                ReceiptTableSection(
                    title: "DISCOUNTS / SAVINGS",
                    kind: .extras,
                    rows: rows
                )
            )
        }

        return sections
    }

    // Firestore payload type
    struct FirestorePayload {
        public var storeName: String
        public var totalAmount: Double
        public var date: Date
        public var receiptCategory: String
        public var tax: Double
        public var extractedText: String
        public var folderID: String?
    }

    // Builds a Firestore-friendly payload, default if parsing did not recognize
    func makeFirestorePayload(
        defaultCategory: String = "Uncategorized",
        folderID: String? = nil
    ) -> FirestorePayload? {
        // We require store name, total amount, and date at the minimum
        guard
            let storeName = self.store?.value.trimmingCharacters(in: .whitespacesAndNewlines),
            !storeName.isEmpty,
            let totalMoney = self.total?.value,
            let date = self.date?.value
        else {
            return nil
        }

        // Convert MoneyAmount to Doubles
        let totalAmount = Decimal(totalMoney.minorUnits) / 100
        let taxAmount   = Decimal(self.tax?.value.minorUnits ?? 0) / 100

        return FirestorePayload(
            storeName: storeName,
            totalAmount: NSDecimalNumber(decimal: totalAmount).doubleValue,
            date: date,
            receiptCategory: defaultCategory,
            tax: NSDecimalNumber(decimal: taxAmount).doubleValue,
            extractedText: self.rawText,
            folderID: folderID
        )
    }
}
