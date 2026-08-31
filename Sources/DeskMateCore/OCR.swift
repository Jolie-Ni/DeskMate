import CoreGraphics
import Vision

/// Lives in Core rather than the daemon so the capture pipeline has exactly one
/// implementation. A fixture builder that reimplemented this would drift from
/// production and quietly stop testing it.
public final class OCR {

    public init() {}

    /// Run on-device OCR via the Vision framework. Free, fast, no network.
    public func recognize(image: CGImage) -> String {
        var output = ""
        let request = VNRecognizeTextRequest { request, _ in
            guard let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }
            output = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
        }
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return ""
        }
        return output
    }
}
