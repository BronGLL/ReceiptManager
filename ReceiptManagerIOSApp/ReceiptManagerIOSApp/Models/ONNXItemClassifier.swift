import Foundation
import CoreML

// A Swift class that handles ML classification of Items
final class ItemClassifier {
    // Configure the model
    let model = try? ReceiptItemClassifier(configuration: MLModelConfiguration())
    // Classifies an array of labels ("ITEM" or "NON_ITEM") for the order of input
    func classify(receiptLines: [String]) -> [String] {
        // If the model fails to load, return "NON_ITEM" for all lines
        guard let model = model else { return Array(repeating: "NON_ITEM", count: receiptLines.count) }
        // Stores the results from classification
        var results: [String] = []
        // Loop through each line from the OCR extraction
        for line in receiptLines {
            // Attempt to predict the label for the currecnt line, and append the label
            if let prediction = try? model.prediction(text: line) {
                results.append(prediction.label)
            } else {
                // If a prediction fails, its a NON_ITEM
                results.append("NON_ITEM")
            }
        }
        // Return our classification results
        return results
    }

    // Classify a single line
    func classifyWithConfidence(text: String) -> (label: String, confidence: Double) {
        // Fail if model did not load properly
        guard let model = model else { return ("NON_ITEM", 0.0) }
        
        do {
            // Perform prediction on the given text string
            let output = try model.prediction(text: text)
            // Set to test models aggression on predictions
            let confidence = 1.0
            // Return the label and confidence
            return (output.label, confidence)
        } catch {
            // Print error for debugging
            print("Model prediction error: \(error)")
            return ("NON_ITEM", 0.0)
        }
    }
}
