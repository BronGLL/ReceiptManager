import Foundation
import Vision
import UIKit
import ImageIO

// Handles the main OCR extraction and processing
final class OCRService {
    
    // Initialize the Classifier
    private let classifier = ItemClassifier()
    
    // Stopwords that force a line to be considered a NON_ITEM
    private let CONTEXT_STOPWORDS = [
        "total", "subtotal", "subtctal", "tax", "balance", "amount", "change", "due",
        "visa", "mastercard", "amex", "debit", "credit", "auth", "ref:",
        "cashier", "tender", "net sales", "items sold", "count",
        "mall", "avenue", "street", " blvd", "lane", " ca ", " ny ",
        "card", "lard", "thank you"
    ]
    
    // Enable Debug Logging
    private let DEBUG_OCR = true
    // Helper function to print debug messages
    private func dlog(_ msg: @autoclosure () -> String) {
        if DEBUG_OCR {
            print("OCR DEBUG: \(msg())")
        }
    }
    
    // Performs Vision OCR and returns raw text and ordered tokens
    private func recognize(image: UIImage) async throws -> ([OcrToken], String) {
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "OCRService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Unable to access CGImage"])
        }
        // Configure VNRecognizeText request for accurate OCR
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = true }

        // Map UIKit orientation to CGImage orientation
        let orientation = mapOrientation(image.imageOrientation)
        // Image request handler
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        // Run async vision request
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    // Successful request
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        // Extract text observations from request results
        let observations = request.results ?? []
        var tokens: [OcrToken] = []
        // Convert each observation into an OCR token model
        for (i, obs) in observations.enumerated() {
            guard let best = obs.topCandidates(1).first else { continue }
            let r = obs.boundingBox
            let bbox = NormalizedRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
            
            tokens.append(OcrToken(
                text: best.string,
                confidence: Double(best.confidence),
                boundingBox: bbox,
                lineIndex: i,
                wordIndex: nil
            ))
        }
        // Sort by vertical position, then horizontal
        let sorted = tokens.sorted { a, b in
            if abs(a.boundingBox.y - b.boundingBox.y) > 0.015 {
                return a.boundingBox.y > b.boundingBox.y
            }
            return a.boundingBox.x < b.boundingBox.x
        }
        
        let rawText = sorted.map { $0.text }.joined(separator: "\n")
        return (sorted, rawText)
    }
    
    // Main function to process a UIImage and convert to a ReceiptDocument.
    // Performs OCR, ML classification, and regex parsing
    func process(image: UIImage) async throws -> ReceiptDocument {
        // Run Vision OCR request
        let (tokens, rawText) = try await recognize(image: image)
        dlog("Recognized \(tokens.count) lines")
        
        // Get original size of image for document output
        let imageSize = image.size
        
        // Run the parsing on a different thread
        let doc = await Task.detached {
            return self.parse(tokens: tokens, rawText: rawText, imageSize: imageSize)
        }.value
        
        return doc
    }
    
    // Predict and Parse pipeline (Normalize text, ML predictions, rule-based overrides, extract items and prices)
    private func parse(tokens: [OcrToken], rawText: String, imageSize: CGSize) -> ReceiptDocument {
        // Normalize the whitespace
        let text = normalize(rawText)
        // Extract the lines from OCR tokens
        let lines = tokens.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        
        // Prediction Loop, ML classification per line
        var predictions: [(label: String, confidence: Double)] = []
        
        for line in lines {
            let result = classifier.classifyWithConfidence(text: line)
            predictions.append(result)
        }
        
        // Initial labels from the classifier
        var finalLabels = predictions.map { $0.label }
        // Refine the ML output using known rules
        for i in 0..<lines.count {
            let line = lines[i].lowercased()
            let prevLine = i > 0 ? lines[i-1].lowercased() : ""
            
            // Too short is always NON_ITEM
            if line.count < 2 {
                if finalLabels[i] == "ITEM" { dlog("Rule(Length): '\(lines[i])' -> NON_ITEM") }
                finalLabels[i] = "NON_ITEM"
                continue
            }
            
            // Has a stopword
            if CONTEXT_STOPWORDS.contains(where: { line.contains($0) }) {
                if finalLabels[i] == "ITEM" { dlog("Rule(Stopword): '\(lines[i])' -> NON_ITEM") }
                finalLabels[i] = "NON_ITEM"
                continue
            }
            
            // Last line was Total/Tax, so this line is likely a price
            if CONTEXT_STOPWORDS.contains(where: { prevLine.contains($0) }) {
                if isPriceOnly(lines[i]) {
                    if finalLabels[i] == "ITEM" { dlog("Rule(Context): '\(lines[i])' -> NON_ITEM (Prev line was stopword)") }
                    finalLabels[i] = "NON_ITEM"
                }
            }
            
            // Rule D: Quantity Pattern (2 @ 1.99)
            if line.range(of: #"^\d+\s*@\s*[\$\d\.]"#, options: .regularExpression) != nil {
                
                // Mark the "2 @" line as NON_ITEM
                if finalLabels[i] == "ITEM" {
                    dlog("Rule(QtyPattern): '\(lines[i])' -> NON_ITEM (Strict match)")
                }
                finalLabels[i] = "NON_ITEM"
                
                // Rescue the line above the 2 @ for real item name
                if i > 0 {
                    let prevRaw = lines[i-1]
                    // Only turn previous line into ITEM if it looks like text
                    if !isPriceOnly(prevRaw) && !isDate(prevRaw) && prevRaw.count > 2 {
                        if finalLabels[i-1] == "NON_ITEM" {
                            dlog("Rule(QtyRescue): Flipping '\(prevRaw)' to ITEM because next line was a Qty pattern")
                            finalLabels[i-1] = "ITEM"
                        }
                    }
                }
                continue
            }
        }
        
        // Call the Line-Item extraction algorithmn
        let lineItems = constructLineItems(lines: lines, tokens: tokens, labels: finalLabels)
        
        // Other fields like Store, Date, Time, etc.
        let store = detectStore(tokens: tokens, labels: finalLabels)
        let detectedDate = detectDate(from: text)
        let detectedTime = detectTime(from: text)
        let (subtotal, tax, total) = detectTotals(from: text)
        let payment = detectPaymentMethod(from: text)
        let transactionId = detectTransactionId(from: text)
        let extras = detectDiscountAdditionalFields(from: text)
        // Return the document assembled with everything
        return ReceiptDocument(
            sourceImageSize: imageSize, rawText: text, store: store, storeType: nil, storeLocation: nil,
            date: detectedDate, time: detectedTime, paymentMethod: payment,
            transactionId: transactionId, subtotal: subtotal, tax: tax, total: total,
            lineItems: lineItems, additionalFields: extras, tokens: tokens,
            createdAt: Date(), updatedAt: Date()
        )
    }
    
    // Extraction Algorithm
    private func constructLineItems(lines: [String], tokens: [OcrToken], labels: [String]) -> [LineItem] {
        var items: [LineItem] = []
        var i = 0
        
        while i < lines.count {
            let label = labels[i]
            let line = lines[i]
            let token = tokens[i]
            
            // Skip NON_ITEM
            if label == "NON_ITEM" {
                i += 1
                continue
            }
            // Single Line Item (Beans 1.99)
            if let (priceStr, priceDec) = priceAtLineEnd(line) {
                let name = line.replacingOccurrences(of: priceStr, with: "").trimmingCharacters(in: .whitespaces)
                
                if name.count >= 2 {
                    items.append(createItem(name: name, price: priceDec, priceStr: priceStr, nameToken: token))
                    dlog("EXTRACT: Single Line -> \(name) | \(priceStr)")
                }
                i += 1
                continue
            }
            
            // Multi-Line Item (Cutwaters \n 12.50)
            if i + 1 < lines.count {
                let nextLine = lines[i+1]
                
                if let (priceStr, priceDec) = priceAnywhere(nextLine) {
                    if line.count >= 2 {
                        items.append(createItem(name: line, price: priceDec, priceStr: priceStr, nameToken: token))
                        dlog("EXTRACT: Multi Line -> \(line) | \(priceStr)")
                        i += 2
                        continue
                    }
                }
            }
            
            // Item was labeled, but no price found
            dlog("EXTRACT: Skipped ITEM (No price found): \(line)")
            i += 1
        }
        
        dlog("Total Items Extracted: \(items.count)")
        return items
    }
    // Helper that creates a LineItem model from the text and price
    private func createItem(name: String, price: Decimal, priceStr: String, nameToken: OcrToken) -> LineItem {
        let money = MoneyAmount.from(decimal: price)
        let detName = DetectedString(value: name, rawText: name, confidence: 0.8, boundingBox: nameToken.boundingBox, candidates: [], fieldType: .itemName, isUserVerified: false)
        let detPrice = DetectedMoney(value: money, rawText: priceStr, confidence: 0.9, boundingBox: nil, candidates: [], fieldType: .itemUnitPrice, isUserVerified: false)
        return LineItem(name: detName, quantity: nil, unitPrice: detPrice, totalPrice: nil)
    }
    
    // Guess the store name from the top 8 lines, filtering out dates/items/prices
    private func detectStore(tokens: [OcrToken], labels: [String]) -> DetectedString? {
        let limit = min(tokens.count, 8)
        for i in 0..<limit {
            let line = tokens[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            if labels[i] == "ITEM" { continue }
            if isPriceOnly(line) { continue }
            if isDate(line) { continue }
            
            dlog("Store guess: \(line)")
            return DetectedString(value: line, rawText: line, confidence: 0.9, boundingBox: tokens[i].boundingBox, candidates: [], fieldType: .storeName, isUserVerified: false)
        }
        return nil
    }
    // Detect valid dates using multiple formats in regex
    private func detectDate(from text: String) -> DetectedDate? {
        let monthNamePattern = #"(?i)\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+\d{1,2}(?:,\s*(?:\d{4}|\d{2}(?!\s*:)))?"#
        let patterns = [
            // YYYY-MM-DD and MM-DD-YYYY
            #"(\d{4})[-/](\d{2})[-/](\d{2})"#,
            #"(\d{2})[-/](\d{2})[-/](\d{2,4})"#,
            monthNamePattern
        ]
        
        for p in patterns {
            if let match = firstMatch(in: text, pattern: p) {
                let cleaned = match.replacingOccurrences(of: #"[^\w/,: -]"#, with: " ", options: .regularExpression)
                if let date = parseDateString(cleaned) {
                    dlog("Parsed date match '\(match)' -> \(date)")
                    return DetectedDate(value: date, rawText: match, confidence: 0.9, boundingBox: nil, candidates: [], fieldType: .date, isUserVerified: false)
                }
            }
        }
        return nil
    }
    // Detct the time in HH:MM:SS format (no AM/PM)
    private func detectTime(from text: String) -> DetectedString? {
        let pattern = #"(?<!\d)(?:[01]?\d|2[0-3]):[0-5]\d(?:[:][0-5]\d)?(?!\s?(?:AM|PM|am|pm))"#
        if let match = firstMatch(in: text, pattern: pattern) {
            dlog("Parsed time: \(match)")
            return DetectedString(value: match, rawText: match, confidence: 0.9, boundingBox: nil, candidates: [], fieldType: .time, isUserVerified: false)
        }
        return nil
    }
    // Total/Subtotal/Tax detection logic using a state machine
    private func detectTotals(from text: String) -> (DetectedMoney?, DetectedMoney?, DetectedMoney?) {
        
        // Helper to convert a string to a money object
        func toMoney(_ s: String, _ original: String) -> DetectedMoney? {
            guard let dec = decimalFromMoneyString(s) else { return nil }
            return DetectedMoney(value: MoneyAmount.from(decimal: dec), rawText: original, confidence: 0.95, boundingBox: nil, candidates: [], fieldType: .total, isUserVerified: false)
        }

        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        
        var foundSubtotal: DetectedMoney?
        var foundTax: DetectedMoney?
        var foundTotal: DetectedMoney?
        
        // Booleans to track whether a lable tells us to expect a price on the next line
        var expectingTax = false
        var expectingTotal = false
        var expectingSubtotal = false
        
        for line in lines {
            let lower = line.lowercased()
            
            // Extract any price on this line
            let priceMatch = priceAnywhere(line)
            let valStr = priceMatch?.0
            
            // Check the state of the line
            if expectingTotal, let v = valStr {
                foundTotal = toMoney(v, line)
                expectingTotal = false // Reset state
                continue // We found it, move on
            }
            
            if expectingTax, let v = valStr {
                foundTax = toMoney(v, line)
                expectingTax = false
                continue
            }
            
            if expectingSubtotal, let v = valStr {
                foundSubtotal = toMoney(v, line)
                expectingSubtotal = false
                continue
            }
            
            // Check the laels through context
            if lower.contains("total") || lower.contains("amount due") || lower.contains("balance") {
                if let v = valStr {
                    foundTotal = toMoney(v, line)
                }
                else {
                    expectingTotal = true
                }
            }
            
            // Line contains tax
            else if lower.contains("tax") || lower.contains("vat") {
                if let v = valStr {
                    foundTax = toMoney(v, line)
                } else {
                    expectingTax = true
                }
            }
            
            // Line contains subtotal
            else if lower.contains("subtotal") {
                if let v = valStr {
                    foundSubtotal = toMoney(v, line)
                } else {
                    expectingSubtotal = true
                }
            }
        }
        
        // If no price was found, take largest price near the bottom
        if foundTotal == nil {
            let ls = text.components(separatedBy: .newlines)
            let tail = ls.suffix(max(6, ls.count / 2))
            let candidates = tail.compactMap { l -> String? in
                guard let r = l.range(of: moneyRegex, options: .regularExpression) else { return nil }
                return String(l[r])
            }
            if let best = candidates.max(by: { (a, b) -> Bool in
                let da = decimalFromMoneyString(a) ?? 0
                let db = decimalFromMoneyString(b) ?? 0
                return NSDecimalNumber(decimal: da).doubleValue < NSDecimalNumber(decimal: db).doubleValue
            }) {
                if let money = toMoney(best, "Fallback Total") {
                    foundTotal = money
                }
            }
        }
        
        return (foundSubtotal, foundTax, foundTotal)
    }
    // Detect references to payment methods
    private func detectPaymentMethod(from text: String) -> DetectedString? {
        let lower = text.lowercased()
        let candidates = ["apple pay", "google pay", "debit card", "credit card", "visa", "mastercard", "amex", "cash"]
        if let hit = candidates.first(where: { lower.contains($0) }) {
            return DetectedString(value: hit.capitalized, rawText: hit, confidence: 0.7, boundingBox: nil, candidates: [], fieldType: .paymentMethod, isUserVerified: false)
        }
        return nil
    }
    // Detect transaction IDs using regex patterns
    private func detectTransactionId(from text: String) -> DetectedString? {
        let patterns = [
            #"(?i)\btxn[\s:#-]*([A-Z0-9\-]{6,})"#,
            #"(?i)\btransaction\s*id[\s:#-]*([A-Z0-9\-]{6,})"#,
            #"(?i)\bauth(?:orization)?\s*code[\s:#-]*([A-Z0-9\-]{4,})"#,
            #"(?i)\bref(?:erence)?[\s:#-]*([A-Z0-9\-]{6,})"#
        ]
        for p in patterns {
            if let m = firstMatch(in: text, pattern: p) {
                return DetectedString(value: m, rawText: m, confidence: 0.6, boundingBox: nil, candidates: [], fieldType: .transactionId, isUserVerified: false)
            }
        }
        return nil
    }
    // Detect discount fields
    private func detectDiscountAdditionalFields(from text: String) -> [DetectedString] {
        let lines = text.components(separatedBy: .newlines)
        var fields: [DetectedString] = []
        var total = Decimal(0)
        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard l.range(of: #"(?i)sav[i1l]ngs?"#, options: .regularExpression) != nil,
                  let r = l.range(of: moneyRegex, options: .regularExpression),
                  let d = decimalFromMoneyString(String(l[r])) else { continue }
            total += d
            fields.append(DetectedString(value: l, rawText: l, confidence: 0.75, boundingBox: nil, candidates: [], fieldType: .unknown, isUserVerified: false))
        }
        // If total discount > 0, we will add a summary field
        if total != 0 {
            let totalStr = NSDecimalNumber(decimal: total).stringValue
            fields.append(DetectedString(value: "discounts_total=\(totalStr)", rawText: totalStr, confidence: 0.9, boundingBox: nil, candidates: [], fieldType: .unknown, isUserVerified: false))
        }
        return fields
    }
    
    // True if line is only a price
    private func isPriceOnly(_ s: String) -> Bool {
        let pattern = #"^\$?\s*\d{1,3}(?:,\d{3})*(?:[.,]\d{2})\s*[A-Za-z]?\s*$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }
    // Detect the price strictly at end of line
    private func priceAtLineEnd(_ line: String) -> (String, Decimal)? {
        let pattern = #"\$?\s?\d{1,3}(?:,\d{3})*(?:[.,]\d{2})(?:\s?[A-Za-z]){0,3}\s*$"#
        guard let r = line.range(of: pattern, options: .regularExpression), r.upperBound == line.endIndex else { return nil }
        let s = String(line[r])
        guard let d = decimalFromMoneyString(s) else { return nil }
        return (s, d)
    }
    // Detect a price anywhere in a line
    private func priceAnywhere(_ line: String) -> (String, Decimal)? {
        guard let r = line.range(of: moneyRegex, options: .regularExpression) else { return nil }
        let s = String(line[r])
        guard let d = decimalFromMoneyString(s) else { return nil }
        return (s, d)
    }
    // Regex for detecting money amounts
    private var moneyRegex: String { #"[-]?\$?\s?\d{1,3}(?:,\d{3})*(?:[.,]\d{2})\b(?:\s?[A-Za-z])?"# }
    // Convert $3.49 to Decimal(3.49)
    private func decimalFromMoneyString(_ s: String) -> Decimal? {
        let cleaned = s.replacingOccurrences(of: "[^0-9,.-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: ".")
        return Decimal(string: cleaned)
    }
    // Basic date detection logic
    private func isDate(_ s: String) -> Bool {
        return s.range(of: #"\d{1,2}/\d{1,2}/\d{2,4}"#, options: .regularExpression) != nil
    }
    // Collapse multi-spaces to single spaces
    private func normalize(_ text: String) -> String {
        return text.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
    }
    // First regex match helper
    private func firstMatch(in text: String, pattern: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }
    // Extract labeled values like Total: 12.99
    private func firstLabeledMoney(in text: String, labels: [String]) -> String? {
        for label in labels {
            let pattern = #"(?i)\b\#(label)\b[:\s]*\$?\s?(\d{1,3}(?:,\d{3})*(?:[.,]\d{2}))\b"#
            if let r = text.range(of: pattern, options: .regularExpression) {
                let match = String(text[r])
                if let m = match.range(of: #"\d{1,3}(?:,\d{3})*(?:[.,]\d{2})"#, options: .regularExpression) {
                    return String(match[m])
                }
            }
        }
        return nil
    }
    // Convert MoneyAmount back into an x.xx string
    private func moneyString(from amount: MoneyAmount) -> String {
        let dec = Decimal(amount.minorUnits) / 100
        return "$" + NSDecimalNumber(decimal: dec).stringValue
    }
    // Attempt to intrepret the date formats
    private func parseDateString(_ s: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        let fmts = ["yyyy-MM-dd","MM/dd/yyyy","MM/dd/yy","MMM d, yyyy"]
        for f in fmts { df.dateFormat = f; if let d = df.date(from: s) { return d } }
        return nil
    }
    
    // Map UIKit image orientation to Coregraphics
    private func mapOrientation(_ ui: UIImage.Orientation) -> CGImagePropertyOrientation {
        switch ui {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
