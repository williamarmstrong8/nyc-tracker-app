import Foundation
import Vision
import UIKit

/// Runs on-device OCR (Vision framework) on a photo and returns a likely *venue name* — typically
/// the biggest, most confident piece of text in the frame. The heuristic assumes storefront-style
/// signage: short strings, big bounding boxes, often uppercase.
enum TextRecognizer {
    /// Best-effort name extraction from a single photo. Returns nil if nothing plausible was found.
    static func recognizePlaceName(from data: Data) async -> String? {
        guard let cgImage = UIImage(data: data)?.cgImage else { return nil }

        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation]
                else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: bestVenueName(from: observations))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            do {
                try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: nil)
            }
        }
    }

    /// Run OCR across every photo and merge into a single name candidate (biggest bbox × highest
    /// confidence across the batch wins).
    static func recognizePlaceName(fromBatch datas: [Data]) async -> String? {
        var best: (name: String, score: Double)?
        for data in datas {
            guard let cgImage = UIImage(data: data)?.cgImage else { continue }
            let observations: [VNRecognizedTextObservation] = await withCheckedContinuation { cont in
                let request = VNRecognizeTextRequest { req, err in
                    guard err == nil, let observations = req.results as? [VNRecognizedTextObservation] else {
                        cont.resume(returning: [])
                        return
                    }
                    cont.resume(returning: observations)
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                do {
                    try VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([request])
                } catch {
                    cont.resume(returning: [])
                }
            }
            for scored in scoredCandidates(from: observations) {
                if best == nil || scored.score > best!.score {
                    best = (scored.text, scored.score)
                }
            }
        }
        return best?.name
    }

    // MARK: - Scoring

    private struct Scored { let text: String; let score: Double }

    private static func bestVenueName(from observations: [VNRecognizedTextObservation]) -> String? {
        scoredCandidates(from: observations).max(by: { $0.score < $1.score })?.text
    }

    /// Filter to plausible venue-name observations and score by area × confidence, with a bonus
    /// for uppercase / title-case signage.
    private static func scoredCandidates(from observations: [VNRecognizedTextObservation]) -> [Scored] {
        observations.compactMap { obs -> Scored? in
            guard let top = obs.topCandidates(1).first else { return nil }
            let text = top.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard passesShape(text) else { return nil }

            let bbox = obs.boundingBox      // normalized [0..1]
            let area = Double(bbox.width * bbox.height)
            let confidence = Double(top.confidence)
            let styleBonus: Double = {
                if text == text.uppercased() { return 1.6 }
                if text.first?.isUppercase == true { return 1.2 }
                return 1.0
            }()
            return Scored(text: text, score: area * confidence * styleBonus)
        }
    }

    /// Rules that filter out phone numbers, addresses, menu items, hours, etc.
    private static func passesShape(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 40 else { return false }

        let letters = text.filter { $0.isLetter }.count
        guard letters >= 3 else { return false }

        let words = text.split(whereSeparator: { $0.isWhitespace })
        guard (1...6).contains(words.count) else { return false }

        // Reject obvious non-names.
        let lowered = text.lowercased()
        let rejectSubstrings = ["open", "closed", "hours", "welcome", "menu", "mon", "tue", "wed", "thu", "fri", "sat", "sun", "am", "pm", "$"]
        for token in rejectSubstrings {
            if lowered.contains(token), letters < 6 { return false }
        }
        // Reject strings that are mostly digits.
        let digits = text.filter { $0.isNumber }.count
        if Double(digits) / Double(text.count) > 0.4 { return false }

        return true
    }
}
