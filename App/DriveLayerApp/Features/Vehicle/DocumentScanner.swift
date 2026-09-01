import SwiftUI
import UIKit
import VisionKit
import Vision

/// Runs on-device text recognition over a scanned page.
///
/// Everything happens locally: no image and no recognised text leaves the device.
/// The recognised lines go straight to `DocumentFieldExtractor`, which is in the core
/// and unit tested, so the rules that decide "this is an expiry date" are the same
/// ones the test suite exercises.
enum DocumentTextRecogniser {

    /// Recognised lines, in reading order. Empty when nothing legible was found —
    /// which is a normal outcome for a blurred scan, not an error.
    static func recognise(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            PrivacyLog.error(.app, "Text recognition failed on a scanned document")
            return []
        }

        let observations = request.results ?? []
        return observations.compactMap { $0.topCandidates(1).first?.string }
    }
}

/// The system document camera, wrapped for SwiftUI.
///
/// Returns what it read *as a suggestion*: the caller pre-fills a form with it and
/// asks the driver to confirm. DriveLayer does not silently trust an OCR result about
/// someone's insurance expiry.
struct DocumentScannerView: UIViewControllerRepresentable {

    struct ScanResult {
        var extraction: DocumentExtraction
        var imageData: Data?
    }

    let onComplete: (ScanResult) -> Void
    let onCancel: () -> Void

    static var isSupported: Bool { VNDocumentCameraViewController.isSupported }

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {

        private let parent: DocumentScannerView

        init(_ parent: DocumentScannerView) {
            self.parent = parent
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount > 0 else {
                parent.onCancel()
                return
            }
            // Only the first page: a registration or insurance certificate carries its
            // key fields on page one, and scanning more pages costs storage for nothing.
            let image = scan.imageOfPage(at: 0)
            let imageData = image.jpegData(compressionQuality: 0.8)
            let cgImage = image.cgImage
            let completion = parent.onComplete

            // Recognition is slow enough to block the camera's dismissal, so it runs
            // off the main queue and reports back on it.
            DispatchQueue.global(qos: .userInitiated).async {
                let lines = cgImage.map { DocumentTextRecogniser.recognise(in: $0) } ?? []
                let extraction = DocumentFieldExtractor().extract(fromRecognisedLines: lines, now: Date())
                DispatchQueue.main.async {
                    completion(ScanResult(extraction: extraction, imageData: imageData))
                }
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            parent.onCancel()
        }

        func documentCameraViewController(_ controller: VNDocumentCameraViewController,
                                          didFailWithError error: Error) {
            PrivacyLog.error(.app, "The document scanner failed")
            parent.onCancel()
        }
    }
}
