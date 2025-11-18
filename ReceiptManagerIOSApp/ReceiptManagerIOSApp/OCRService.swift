import Foundation
import Vision
import UIKit
import ImageIO

// Main OCR pipeline for running vision and parsing text
@MainActor
final class OCRService {
    
    // Small helper struct that carries a price token and its numeric value.
    private struct PLine {
        let tok: OcrToken
        let priceStr: String
        let value: Decimal
    }


    // Turn this to false to not see debug outputs in the console
    private let DEBUG_OCR = true
    private func dlog(_ msg: @autoclosure () -> String) {
        if DEBUG_OCR { print("OCR DEBUG:", msg()) }
    }

    // Given an image, run the OCR, parse, and return ReceiptDocument
    func process(image: UIImage) async throws -> ReceiptDocument {
        let (tokens, rawText) = try await recognize(image: image)
        dlog("Recognized \(tokens.count) lines")
        let doc = parse(tokens: tokens, rawText: rawText, imageSize: image.size)
        return doc
    }

    // Vision Text Recognition
    
    // Uses Vision to recognize text lines and convert them inro OcrToken objects
    private func recognize(image: UIImage) async throws -> ([OcrToken], String) {
        // We need the CGImage
        guard let cgImage = image.cgImage else {
            throw NSError(domain: "OCRService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Unable to access CGImage"])
        }
        // Configure the Vision request using VNRecognizeTextRequest()
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if #available(iOS 16.0, *) { request.automaticallyDetectsLanguage = true }

        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        // Run the Vision request on a background queue, then bridge to await
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try handler.perform([request])
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        let observations = request.results ?? []
        var tokens: [OcrToken] = []
        // Convert each Vision observation into token type
        for (i, obs) in observations.enumerated() {
            guard let best = obs.topCandidates(1).first else { continue }
            let r = obs.boundingBox
            let bbox = NormalizedRect(x: r.origin.x, y: r.origin.y, width: r.size.width, height: r.size.height)
            tokens.append(
                OcrToken(text: best.string,
                         confidence: Double(best.confidence),
                         boundingBox: bbox,
                         lineIndex: i,
                         wordIndex: nil)
            )
        }

        // Sort by reading order: first by row, then by column
        let sorted = tokens.sorted { a, b in
            let ay = a.boundingBox.y, by = b.boundingBox.y
            // Different rows
            if abs(ay - by) > 0.015 { return ay > by }
            // Return same row left to right
            return a.boundingBox.x < b.boundingBox.x
        }
        // multi-line string version of the text
        let rawText = sorted.map { $0.text }.joined(separator: "\n")
        return (sorted, rawText)
    }

    // Parsing
    
    // Main parser, takes raw text and tokens and fills in the fields
    private func parse(tokens: [OcrToken], rawText: String, imageSize: CGSize) -> ReceiptDocument {
        let text = normalize(rawText)
        dlog("RAW TEXT:\n\(text)\n")
        
        // Core fields
        let store = detectStore(tokens: tokens)
        let detectedDate = detectDate(from: text)
        let detectedTime = detectTime(from: text)
        let (subtotal, tax, total) = detectTotals(from: text)

        // Try primary itemization first
        var lineItems = detectLineItems(tokens: tokens, fullText: text)

        // If that fails, we go to a text only scanner
        if lineItems.isEmpty {
            dlog("Primary itemizer returned 0 items — trying text-window fallback")
            lineItems = detectLineItemsTextWindow(fullText: text)
        }

        let extras = detectDiscountAdditionalFields(from: text)
        
        // Build the final document
        return ReceiptDocument(
            sourceImageSize: imageSize,
            rawText: text,
            store: store,
            storeType: nil,
            storeLocation: nil,
            date: detectedDate,
            time: detectedTime,
            paymentMethod: detectPaymentMethod(from: text),
            transactionId: detectTransactionId(from: text),
            subtotal: subtotal,
            tax: tax,
            total: total,
            lineItems: lineItems,
            additionalFields: extras,
            tokens: tokens,
            createdAt: Date(),
            updatedAt: Date()
        )
    }

    // Field Detectors
    // Gets the store name by looking at the first few lines that don't look like prices
    private func detectStore(tokens: [OcrToken]) -> DetectedString? {
        // Sort from top to bottom
        let sorted = tokens.sorted { $0.boundingBox.y > $1.boundingBox.y }
        for t in sorted.prefix(8) {
            let s = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            // Skip lines that look like prices (store detection only)
            if looksLikePrice(s) || s.range(of: #"^\d+$"#, options: .regularExpression) != nil { continue }
            dlog("Store guess: \(s)")
            return DetectedString(
                value: s, rawText: s, confidence: t.confidence,
                boundingBox: t.boundingBox, candidates: [],
                fieldType: .storeName, isUserVerified: false
            )
        }
        return nil
    }
    // Find a date string in the full text and normalize to a date
    private func detectDate(from text: String) -> DetectedDate? {
        // allow 4-digit year, or 2-digit year only if NOT followed by a colon
        let monthNamePattern = #"(?i)\b(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Sept|Oct|Nov|Dec)\.?\s+\d{1,2}(?:,\s*(?:\d{4}|\d{2}(?!\s*:)))?"#

        let patterns = [
            // yyyy-MM-dd
            #"(\d{4})[-/](\d{2})[-/](\d{2})"#,
            // MM/dd/yy or MM/dd/yyyy
            #"(\d{2})[-/](\d{2})[-/](\d{2,4})"#,
            // "Nov 24", "Nov 24, 2025", "Nov 24, 25"
            monthNamePattern
        ]

        for p in patterns {
            if let match = firstMatch(in: text, pattern: p) {
                // Clean out stray characters
                let cleaned = match.replacingOccurrences(of: #"[^\w/,: -]"#, with: " ",
                                                         options: .regularExpression)
                if let date = parseDateString(cleaned) {
                    dlog("Parsed date match '\(match)' -> \(date)")
                    return DetectedDate(
                        value: date, rawText: match, confidence: 0.9,
                        boundingBox: nil, candidates: [], fieldType: .date, isUserVerified: false
                    )
                }
            }
        }
        return nil
    }

    // 24-hour time only for time extraction, in HH:MM or HH:MM:SS
    private func detectTime(from text: String) -> DetectedString? {
        let pattern = #"(?<!\d)(?:[01]?\d|2[0-3]):[0-5]\d(?:[:][0-5]\d)?(?!\s?(?:AM|PM|am|pm))"#
        if let match = firstMatch(in: text, pattern: pattern) {
            dlog("Parsed time: \(match)")
            return DetectedString(
                value: match,
                rawText: match,
                confidence: 0.9,
                boundingBox: nil,
                candidates: [],
                fieldType: .time,
                isUserVerified: false
            )
        }
        return nil
    }
    // Detect tax and totals using labels
    private func detectTotals(from text: String)
    -> (DetectedMoney?, DetectedMoney?, DetectedMoney?) {

        func toMoney(_ s: String) -> MoneyAmount? {
            guard let dec = decimalFromMoneyString(s) else { return nil }
            return MoneyAmount.from(decimal: dec)
        }

        // Split lines once sowe can scan for "Tax" in input
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        var taxMoney: MoneyAmount? = nil

        for i in 0..<lines.count {
            let line = lines[i]

            // Case 1: "Tax $1.19" or "Sales Tax: 1.19"
            if let _ = line.range(of: #"(?i)^\s*(sales\s+)?tax\b"#, options: .regularExpression),
               let rAmt = line.range(of: #"\d{1,3}(?:,\d{3})*(?:[.,]\d{2})"#, options: .regularExpression),
               let d = decimalFromMoneyString(String(line[rAmt])) {
                taxMoney = MoneyAmount.from(decimal: d)
                dlog("Tax from labeled same-line: \(d)")
                break
            }

            // Case 2: line is just "Tax", and amount on the next non-empty line
            if line.range(of: #"(?i)^\s*(sales\s+)?tax\s*[:\-]?\s*$"#, options: .regularExpression) != nil {
                var j = i + 1
                while j < lines.count, lines[j].isEmpty { j += 1 }
                if j < lines.count,
                   let rAmt = lines[j].range(of: moneyRegex, options: .regularExpression),
                   let d = decimalFromMoneyString(String(lines[j][rAmt])) {
                    taxMoney = MoneyAmount.from(decimal: d)
                    dlog("Tax from next-line: \(d)")
                    break
                }
            }
        }

        let subtotal = firstLabeledMoney(in: text, labels: ["subtotal", "sub total"]).flatMap(toMoney)
        if let s = subtotal { dlog("Subtotal: \(s.minorUnits)") }

        // ignore  "crv"/"deposit"
        let labelTax = firstLabeledMoney(in: text, labels: ["tax", "sales tax"]).flatMap(toMoney)
        // Try to find a "total/amount due/balance" label
        var totalStr = firstLabeledMoney(in: text, labels: [
            "total", "amount due", "balance", "price you pay", "payment amount"
        ])

        // If we still don't have a total, we pick the largest amount near the bottom
        if totalStr == nil {
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
                totalStr = best
            }
        }

        let detSubtotal = subtotal.map {
            DetectedMoney(value: $0, rawText: moneyString(from: $0), confidence: 0.9,
                          boundingBox: nil, candidates: [], fieldType: .subtotal, isUserVerified: false)
        }
        let finalTax = (taxMoney ?? labelTax)
        let detTax = finalTax.map {
            DetectedMoney(value: $0, rawText: moneyString(from: $0), confidence: 0.95,
                          boundingBox: nil, candidates: [], fieldType: .tax, isUserVerified: false)
        }

        let detTotal = totalStr.flatMap(toMoney).map {
            DetectedMoney(value: $0, rawText: moneyString(from: $0), confidence: 0.95,
                          boundingBox: nil, candidates: [], fieldType: .total, isUserVerified: false)
        }

        if let t = detTotal { dlog("Total: \(t.value.minorUnits)") }
        return (detSubtotal, detTax, detTotal)
    }

    // Itemization

    // Main item extractor. Anchors on price, then looks for names and price
    private func detectLineItems(tokens: [OcrToken], fullText: String) -> [LineItem] {
        var prices: [PLine] = []

        // collect price candidates, line must end with a price
        for t in tokens {
            let line = t.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = line.lowercased()
            // skip the totals, balance, and savings
            if isStopWordLine(lower) || isSavingsLine(lower) { dlog("SKIP stop/savings: \(line)"); continue }

            if let (priceStr, dec) = priceFromLine(line) {
                // Ignore negatives (savings)
                if dec < 0 { dlog("SKIP negative: \(line)"); continue }
                if dec <= 0.50 {
                    // Ignore crv or tax amounts
                    let near = neighboringText(around: t, in: tokens, radius: 2).joined(separator: " ").lowercased()
                    if near.contains("crv") || near.contains("deposit") || near.contains("bottle") || hasTaxSuffix(priceStr) {
                        dlog("SKIP micro CRV/Tax: \(line)")
                        continue
                    }
                }
                dlog("PRICE CAND: \(line)  -> \(priceStr)")
                prices.append(PLine(tok: t, priceStr: priceStr, value: dec))
            }
        }
        dlog("Total price-candidates: \(prices.count)")
        if prices.isEmpty { return [] }

        // Keep dominant right edge
        prices = filterToDominantPriceColumn(prices)

        // Sort and group nearby prices belonging to the same item
        prices.sort { $0.tok.boundingBox.y > $1.tok.boundingBox.y }
        let groupDy: CGFloat = 0.040
        var grouped: [[PLine]] = []
        for p in prices {
            if var last = grouped.last, let tail = last.last,
               abs(tail.tok.boundingBox.y - p.tok.boundingBox.y) <= groupDy {
                last.append(p); grouped[grouped.count - 1] = last
            } else { grouped.append([p]) }
        }
        dlog("Formed \(grouped.count) price groups")
        // Choose which price in a group is the main one
        func chooseEffectivePrice(_ g: [PLine]) -> PLine {
            if let eaMax = g.filter({ $0.priceStr.lowercased().contains("ea") }).max(by: { $0.value < $1.value }) {
                return eaMax
            }
            // Prefer lines that have sales
            if let s = g.first(where: { hasSaleSuffix($0.priceStr) }) { return s }
            // Otherwise, pick the smallest value in a group
            if let m = g.min(by: { $0.value < $1.value }) { return m }
            return g.last!
        }

        // Look only above for the price token for the totals
        let hardStopsAbove = ["subtotal","total","amount due","balance","payment amount","price you pay","change","crv","deposit"]

        var items: [LineItem] = []
        for (gIdx, group) in grouped.enumerated() {
            let chosen = chooseEffectivePrice(group)
            let priceTok = chosen.tok

            // totals/tax context only ABOVE
            let upCtx = aboveContext(for: priceTok, in: tokens, up: 2).joined(separator: " ").lowercased()
            if hardStopsAbove.contains(where: { upCtx.contains($0) }) {
                dlog("GROUP \(gIdx): skip (totals context above) \(upCtx)")
                continue
            }

            guard let startIdx = tokens.firstIndex(where: { $0.lineIndex == priceTok.lineIndex }) else { continue }

            var parts: [String] = []
            var qtyHint: Int?
            var unitPriceDec: Decimal?

            var j = startIdx - 1
            var steps = 0
            let lookbackMaxDy: CGFloat = 0.18
            let lookbackMaxSteps = 14
            var priceLinesSeen = 0
            
            // Walk to the above nearby lines to get item details
            while j >= 0 && steps < lookbackMaxSteps {
                let cand = tokens[j]
                let raw = cand.text.trimmingCharacters(in: .whitespacesAndNewlines)
                let low = raw.lowercased()
                // Stop if we went too far above
                if abs(cand.boundingBox.y - priceTok.boundingBox.y) > lookbackMaxDy { break }
                // Stop at section headers if they had one
                if isSectionHeaderFuzzy(raw) { dlog("GROUP \(gIdx): break on section '\(raw)'"); break }

                // Allow up to two price lines above
                if lineEndsWithPrice(raw) {
                    priceLinesSeen += 1
                    if priceLinesSeen <= 2 { steps += 1; j -= 1; continue }
                    break
                }
                // Lines that have 2 @ 2.50 or 2 for 5
                if isQtyOrUnitLine(low) {
                    if let q = extractQuantity(low) { qtyHint = q }
                    if let (_, dec) = priceFromLine(raw) { unitPriceDec = dec; dlog("GROUP \(gIdx): unit price line '\(raw)'") }
                    steps += 1; j -= 1; continue
                }
                // Try to treat the line as part of the item name
                let sn = sanitizedName(raw)
                if isWordyItemName(sn) {
                    parts.insert(sn, at: 0)
                    dlog("GROUP \(gIdx): name part '\(sn)'")
                    if parts.count == 2 { break }
                } else {
                    dlog("GROUP \(gIdx): skip as name '\(raw)'")
                }

                steps += 1; j -= 1
            }
            
            let name = parts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            // If we did not find a useable name, drop the price group
            if name.isEmpty {
                dlog("GROUP \(gIdx): no plausible name found above \(chosen.priceStr)")
                continue
            }

            // Build the line item
            let money = MoneyAmount.from(decimal: chosen.value)
            let detName  = DetectedString(value: name, rawText: name, confidence: 0.80,
                                          boundingBox: priceTok.boundingBox, candidates: [],
                                          fieldType: .itemName, isUserVerified: false)
            // Treat this price and put it into unitPrice
            let detPrice = DetectedMoney(value: money, rawText: chosen.priceStr, confidence: 0.93,
                                         boundingBox: priceTok.boundingBox, candidates: [],
                                         fieldType: .itemUnitPrice,  // put it in unitPrice so your UI says “Price”
                                         isUserVerified: false)

            let qtyDet: DetectedValue<Double>? = qtyHint.map { q in
                DetectedValue<Double>(value: Double(q), rawText: "\(q)", confidence: 0.8,
                                      boundingBox: nil, candidates: [], fieldType: .unknown, isUserVerified: false)
            }

            items.append(LineItem(name: detName,
                                  quantity: qtyDet,
                                  unitPrice: detPrice,
                                  // Leave nil to avoid “Total” label
                                  totalPrice: nil))
            dlog("ITEM:  \(name)  →  \(chosen.priceStr)\(qtyDet != nil ? " (qty \(Int(qtyDet!.value)))" : "")")
        }

        dlog("Items detected (primary): \(items.count)")
        return items
    }

    // Keep a dominant right-edge “price column” only if it’s clearly the main cluster.
    private func filterToDominantPriceColumn(_ prices: [PLine]) -> [PLine] {
        if prices.count < 4 { return prices }
        func rightEdge(_ r: NormalizedRect) -> CGFloat { r.x + r.width }
        let edges = prices.map { rightEdge($0.tok.boundingBox) }
        let binWidth: CGFloat = 0.02
        func bin(_ x: CGFloat) -> Int { Int((x / binWidth).rounded()) }
        var hist: [Int:Int] = [:]
        edges.forEach { hist[bin($0), default: 0] += 1 }
        guard let (key, count) = hist.max(by: { $0.value < $1.value }) else { return prices }
        let ratio = Double(count) / Double(prices.count)
        if count >= 3 && ratio >= 0.4 {
            let out = prices.filter { abs(bin(rightEdge($0.tok.boundingBox)) - key) <= 1 }
            dlog("Right-edge median kept=\(out.count)/\(prices.count) (decisive)")
            return out
        } else {
            dlog("Right-edge histogram not decisive (count=\(count) of \(prices.count)) — skipping column filter")
            return prices
        }
    }




    // Backup that scans the text lines without using bounding boxes
    // Only emits items with a real name; drops CRV/tiny/negative lines entirely.

    private func detectLineItemsTextWindow(fullText: String) -> [LineItem] {
        var items: [LineItem] = []
        let rawLines = fullText.components(separatedBy: .newlines)
        let lines = rawLines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        // Line that chcks if we reached total/balance, so we stop scanning items
        func isTerminator(_ s: String) -> Bool {
            let l = s.lowercased()
            return l == "tax" || l.hasPrefix("tax ") || l.contains("subtotal")
                || l.contains(" balance") || l.contains("amount due")
                || l.contains("payment amount") || l == "total" || l.hasPrefix("total ")
        }
        // Decide if a price line s not a product
        func isNonItem(_ s: String, amount: Decimal) -> Bool {
            let l = s.lowercased()
            if amount < 0 { return true }
            if amount <= 0.50 { return l.contains("crv") || l.contains("deposit") || l.contains("bottle") || l.contains("bag") }
            return l.contains("tax") || l.contains("balance") || l.contains("amount due") || l.contains("payment amount")
        }
        // Look above a prie line for a useable product name
        func nameNear(_ idx: Int) -> String? {
            var j = idx - 1
            var steps = 0
            while j >= 0 && steps < 4 {
                let cand = sanitizedName(lines[j])
                if isWordyItemName(cand) { return cand }
                steps += 1; j -= 1
            }
            // If we can't find a name, drop the item
            return nil
        }
        // Find the first line that looks like a price, not total
        var inItems = false
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let lower = line.lowercased()

            if isTerminator(lower) { break }

            if !inItems {
                if let _ = priceAnywhere(line), !lower.contains("total") && !lower.contains("amount due") && !lower.contains("balance") {
                    inItems = true
                    dlog("FALLBACK: entering items at line \(i): \(line)")
                } else { i += 1; continue }
            }

            if let (priceStr, priceDec) = priceAtLineEnd(line) {
                if isNonItem(lower, amount: priceDec) { i += 1; continue }

                // Choose best price by seeing into the next few lines
                var best: (str: String, dec: Decimal, idx: Int) = (priceStr, priceDec, i)
                var sawSaleSuffix = hasSaleSuffix(priceStr)
                var k = i + 1
                let hi = min(lines.count - 1, i + 6)
                while k <= hi {
                    let lk = lines[k].lowercased()
                    if isTerminator(lk) { break }
                    if let (ps, pd) = priceAtLineEnd(lines[k]) {
                        if isNonItem(lk, amount: pd) { k += 1; continue }
                        if hasSaleSuffix(ps) {
                            best = (ps, pd, k); sawSaleSuffix = true
                        } else if !sawSaleSuffix && pd > best.dec {
                            best = (ps, pd, k)
                        }
                    }
                    k += 1
                }
                // Drop this price group if we can't find a real name nearby
                guard let name = nameNear(i) else { i = max(i + 1, best.idx + 1); continue } // drop if no real name
                dlog("FALLBACK ITEM: \(name) → \(best.str)")

                // show as unitPrice only
                let money = MoneyAmount.from(decimal: best.dec)
                let detName = DetectedString(value: name, rawText: name, confidence: 0.7,
                                             boundingBox: nil, candidates: [],
                                             fieldType: .itemName, isUserVerified: false)
                let detUnit = DetectedMoney(value: money, rawText: best.str, confidence: 0.9,
                                            boundingBox: nil, candidates: [],
                                            fieldType: .itemUnitPrice, isUserVerified: false)

                items.append(LineItem(name: detName, quantity: nil, unitPrice: detUnit, totalPrice: nil))
                i = max(i + 1, best.idx + 1)
                continue
            }
            i += 1
        }

        dlog("Items detected (fallback): \(items.count)")
        return items
    }


    // Payment and Transaction helpers
    // Simple keyword-based payment method detection
    private func detectPaymentMethod(from text: String) -> DetectedString? {
        let lower = text.lowercased()
        let candidates = [
            "apple pay", "google pay",
            "debit card", "credit card",
            "visa", "mastercard", "amex",
            "cash"
        ]
        if let hit = candidates.first(where: { lower.contains($0) }) {
            return DetectedString(value: hit.capitalized, rawText: hit, confidence: 0.7,
                                  boundingBox: nil, candidates: [], fieldType: .paymentMethod, isUserVerified: false)
        }
        return nil
    }
    
    // Try to grab transaction ID through regex
    private func detectTransactionId(from text: String) -> DetectedString? {
        let patterns = [
            #"(?i)\btxn[\s:#-]*([A-Z0-9\-]{6,})"#,
            #"(?i)\btransaction\s*id[\s:#-]*([A-Z0-9\-]{6,})"#,
            #"(?i)\bauth(?:orization)?\s*code[\s:#-]*([A-Z0-9\-]{4,})"#,
            #"(?i)\bref(?:erence)?[\s:#-]*([A-Z0-9\-]{6,})"#
        ]
        for p in patterns {
            if let m = firstMatch(in: text, pattern: p) {
                return DetectedString(value: m, rawText: m, confidence: 0.6,
                                      boundingBox: nil, candidates: [], fieldType: .transactionId, isUserVerified: false)
            }
        }
        return nil
    }

    // Discounts gets added to AdditionalFields

    // Collect savings/discount lines
    private func detectDiscountAdditionalFields(from text: String) -> [DetectedString] {
        let lines = text.components(separatedBy: .newlines)
        var fields: [DetectedString] = []
        var total = Decimal(0)

        for raw in lines {
            let l = raw.trimmingCharacters(in: .whitespaces)
            guard isSavingsLine(l),
                  let r = l.range(of: moneyRegex, options: .regularExpression),
                  let d = decimalFromMoneyString(String(l[r])) else { continue }
            total += d
            fields.append(DetectedString(value: l, rawText: l, confidence: 0.75,
                                         boundingBox: nil, candidates: [], fieldType: .unknown, isUserVerified: false))
        }

        if total != 0 {
            let totalStr = NSDecimalNumber(decimal: total).stringValue
            fields.append(DetectedString(value: "discounts_total=\(totalStr)",
                                         rawText: totalStr,
                                         confidence: 0.9,
                                         boundingBox: nil, candidates: [], fieldType: .unknown, isUserVerified: false))
        }
        return fields
    }

    // Utilities
    
    #if DEBUG
    private func ocrLog(_ s: @autoclosure () -> String) {
        print("🧩 OCR DEBUG: \(s())")
    }
    #else
    private func ocrLog(_ s: @autoclosure () -> String) { }
    #endif


    // Only look above a token and avoid pulling in tax lines below
    private func aboveContext(for center: OcrToken, in toks: [OcrToken], up: Int) -> [String] {
        guard let i = toks.firstIndex(where: { $0.lineIndex == center.lineIndex }) else { return [] }
        let lo = max(0, i - up), hi = i - 1
        guard hi >= lo else { return [] }
        return toks[lo...hi].map { $0.text }
    }

    // Check if a line describes quantity or unit pricing "@ 2"
    private func isQtyOrUnitLine(_ raw: String) -> Bool {
        let l = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if l.range(of: #"^\s*\d+\s*@\s*$"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"\b(?:ea|each|lb|lbs|kg|per|pkg)\b"#, options: .regularExpression) != nil { return true }
        if l.range(of: #"^\s*\d+\s*(?:for|\/)\s*\$?\d+(?:\.\d{2})?\s*$"#, options: .regularExpression) != nil { return true }
        return false
    }

    // Try to pull an integer quantity
    private func extractQuantity(_ raw: String) -> Int? {
        let l = raw.lowercased()
        if let r = l.range(of: #"^\s*(\d+)\s*@\s*$"#, options: .regularExpression) {
            return Int(l[r].replacingOccurrences(of: "@", with: "")
                          .trimmingCharacters(in: .whitespaces))
        }
        if let r = l.range(of: #"^\s*(\d+)\s*(?:for|\/)\s*\$?\d+(?:\.\d{2})?\s*$"#, options: .regularExpression) {
            let s = String(l[r])
            if let m = s.range(of: #"\d+"#, options: .regularExpression) {
                return Int(s[m])
            }
        }
        return nil
    }

    // Detect section headers, if the reciept uses one
    private func isSectionHeaderFuzzy(_ raw: String) -> Bool {
        let letters = raw.lowercased()
            .replacingOccurrences(of: #"[^a-z]"#, with: "", options: .regularExpression)
        let headers = ["refrig","frozen","liquor","produce","bakery","grocery","poultry",
                       "soda","beer","wine","deli","meat","seafood","household","beverages","snacks"]
        if headers.contains(where: { letters.contains($0) }) { return true }
        if letters.contains("poul") && (letters.contains("try") || letters.contains("iry")) { return true }
        return false
    }


    // Regex for money strings (floats) like 1.99
    private var moneyRegex: String {
        #"[-]?\$?\s?\d{1,3}(?:,\d{3})*(?:[.,]\d{2})\b(?:\s?[A-Za-z])?"#
    }
    // Check if a string looks like a price
    private func looksLikePrice(_ s: String) -> Bool {
        s.range(of: moneyRegex, options: .regularExpression) != nil
    }
    // Find a labeled amount for each label
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
    // Convert a money string into a Decimal
    private func decimalFromMoneyString(_ s: String) -> Decimal? {
        let cleaned = s
            .replacingOccurrences(of: "[^0-9,.-]", with: "", options: .regularExpression)
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: #"[A-Za-z]$"#, with: "", options: .regularExpression)
        return Decimal(string: cleaned)
    }
    // Builds a $x.xx string from a certain MoneyAmount
    private func moneyString(from amount: MoneyAmount) -> String {
        let dec = Decimal(amount.minorUnits) / 100
        return "$" + NSDecimalNumber(decimal: dec).stringValue
    }
    // Return the first regex match for a pattern in text
    private func firstMatch(in text: String, pattern: String) -> String? {
        text.range(of: pattern, options: .regularExpression).map { String(text[$0]) }
    }
    // Fix common OCR issues
    private func normalize(_ text: String) -> String {
        var t = text
        // "-"
        t = t.replacingOccurrences(of: "[\u{2212}\u{2012}\u{2013}\u{2014}]",
                                   with: "-", options: .regularExpression)
        // Detets values seperated by commas (18 , 88)
        t = t.replacingOccurrences(of: #"(\d)\s*,\s*(\d{2})"#,
                                   with: #"$1.$2"#, options: .regularExpression)
        // common OCR flubs
        t = t.replacingOccurrences(of: "(?i)savinas", with: "savings", options: .regularExpression)
        t = t.replacingOccurrences(of: "(?i)meaber",  with: "member",  options: .regularExpression)
        // collapse spaces
        t = t.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return t
    }
    // Try several date formats until one parse is successful
    private func parseDateString(_ s: String) -> Date? {
        let fmts = [
            "yyyy-MM-dd","MM/dd/yyyy","MM/dd/yy","yyyy/MM/dd","dd/MM/yyyy","dd/MM/yy",
            "MMM d, yyyy","MMM d, yy","MMM d"
        ]
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone(secondsFromGMT: 0)
        // Map 2-digit years to 2000–2099
        df.twoDigitStartDate = Calendar.current.date(from: DateComponents(year: 2000, month: 1, day: 1))

        for f in fmts {
            df.dateFormat = f
            if let d = df.date(from: s) {
                if f == "MMM d" {
                    var comps = Calendar.current.dateComponents(in: TimeZone(secondsFromGMT: 0)!, from: Date())
                    let md = Calendar.current.dateComponents([.month,.day], from: d)
                    comps.month = md.month; comps.day = md.day
                    return Calendar.current.date(from: comps)
                }
                return d
            }
        }
        return nil
    }

    // Itemization helpers

    // Accept price at end-of-line
    private func lineEndsWithPrice(_ s: String) -> Bool {
        let pattern = #"\$?\s?\d{1,3}(?:,\d{3})*(?:[.,]\d{2})(?:\s?[A-Za-z]){0,3}\s*$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    // Extract price string from a line that ends with a price
    private func priceFromLine(_ line: String) -> (String, Decimal)? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #"\$?\s?\d{1,3}(?:,\d{3})*(?:[.,]\d{2})(?:\s?[A-Za-z]){0,3}\s*$"#
        guard let r = trimmed.range(of: pattern, options: .regularExpression) else { return nil }
        let priceStr = String(trimmed[r]).trimmingCharacters(in: .whitespaces)
        guard let d = decimalFromMoneyString(priceStr) else { return nil } // strips letters internally
        return (priceStr, d)
    }
    // Find a price string anywhere in the line
    private func priceAnywhere(_ line: String) -> (String, Decimal)? {
        guard let r = line.range(of: moneyRegex, options: .regularExpression) else { return nil }
        let s = String(line[r])
        guard let d = decimalFromMoneyString(s) else { return nil }
        return (s, d)
    }
    // Like priceAnywhere, but for the end of the line
    private func priceAtLineEnd(_ line: String) -> (String, Decimal)? {
        guard let r = line.range(of: moneyRegex, options: .regularExpression),
              r.upperBound == line.endIndex else { return nil }
        let s = String(line[r])
        guard let d = decimalFromMoneyString(s) else { return nil }
        return (s, d)
    }
    // Returns true if line contains Sale value
    private func hasSaleSuffix(_ s: String) -> Bool {
        s.trimmingCharacters(in: .whitespaces).hasSuffix("S")
        || s.trimmingCharacters(in: .whitespaces).hasSuffix("s")
    }

    // Lines that are not items (section headers / totals / payments / crv/tax)
    private func isStopWordLine(_ lower: String) -> Bool {
        let bads = [
            "price you pay", "payment amount", "amount due", "balance", "change",
            "subtotal", "tax", "total", "crv", "deposit",
            "card #", "visa", "mastercard", "amex", "debit", "credit",
            "auth:", "ref:", "tvr", "aid"
        ]
        return bads.contains(where: { lower.contains($0) })
    }

    // Clean up a line and strip things not part of item name
    private func sanitizedName(_ s: String) -> String {
        var name = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = name.lowercased()

        if isStopWordLine(lower) || isSavingsLine(lower) { return "" }
        if lower.range(of: #"^\d{4,}$"#, options: .regularExpression) != nil { return "" }
        if lower.range(of: #"^[0-9]+(?:[ .-][0-9]+)*$"#, options: .regularExpression) != nil { return "" }
        if lower.range(of: moneyRegex, options: .regularExpression) != nil { return "" }

        let headers = ["refrig","frozen","liquor","poultry","soda","grocery","produce","bakery",
                       "deli","meat","seafood","beer","wine","beverages","household"]
        if headers.contains(where: { lower.contains($0) }) { return "" }

        let letters = lower.replacingOccurrences(of: #"[^a-z]"#, with: "", options: .regularExpression)
        if letters.count < 2 { return "" }
        // Replace bullets/dashes with spaces
        name = name.replacingOccurrences(of: #"[|•\-–—]+"#, with: " ", options: .regularExpression)
        name = name.replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
        return name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Check if the line is for member savings
    private func isSavingsLine(_ s: String) -> Bool {
        s.range(of: #"(?i)sav[i1l]ngs?"#, options: .regularExpression) != nil
    }

    // Pull a small context window to help classification
    private func neighboringText(around center: OcrToken, in toks: [OcrToken], radius: Int) -> [String] {
        guard let i = toks.firstIndex(where: { $0.lineIndex == center.lineIndex }) else { return [] }
        let lo = max(0, i - radius), hi = min(toks.count - 1, i + radius)
        return toks[lo...hi].map { $0.text }
    }
}

// Helpers

// Returns true if a price ends with a tax flag "T"
private func hasTaxSuffix(_ s: String) -> Bool {
    let t = s.trimmingCharacters(in: .whitespaces)
    return t.hasSuffix("T") || t.hasSuffix("t")
}

// Looks like a real product name: mostly letters, without totals/tax/headers.
private func isWordyItemName(_ s: String) -> Bool {
    let l = s.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
    if l.isEmpty { return false }
    let bans = ["tax","crv","deposit","balance","amount due","subtotal","total","change",
                "payment amount","debit","credit","card","auth","aid","tvr","store hours",
                "us debit","grocery tax","crv bev","bev","beverage","visa","mastercard","amex",
                "entry method","approved","auth code","total:"]
    if bans.contains(where: { l.contains($0) }) { return false }
    let headers = ["refrig","frozen","liquor","poultry","soda","grocery","produce","bakery",
                   "deli","meat","seafood","beer","wine","household","snacks","beverages"]
    if headers.contains(where: { l.contains($0) }) { return false }

    let letters = l.replacingOccurrences(of: #"[^a-z]"#, with: "", options: .regularExpression)
    let digits  = l.replacingOccurrences(of: #"[^0-9]"#, with: "", options: .regularExpression)
    return letters.count >= 2 && letters.count >= max(2, digits.count)
}
// Map UIImage.Orientation for Vision
extension CGImagePropertyOrientation {
    init(_ ui: UIImage.Orientation) {
        switch ui {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}

