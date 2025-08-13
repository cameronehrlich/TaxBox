import CoreImage
import CoreImage.CIFilterBuiltins
import Vision
import AppKit
import UniformTypeIdentifiers

/// Handles document image processing for camera capture
class DocumentProcessor {
    
    private let context = CIContext()
    
    /// Applies perspective correction to straighten a document based on detected rectangle
    func correctPerspective(image: CGImage, rectangle: VNRectangleObservation) -> CGImage? {
        let inputImage = CIImage(cgImage: image)
        
        // Convert normalized Vision coordinates to CIImage coordinates
        let imageSize = inputImage.extent.size
        
        // Vision uses bottom-left origin, CIImage uses bottom-left origin too
        let topLeft = CGPoint(
            x: rectangle.topLeft.x * imageSize.width,
            y: rectangle.topLeft.y * imageSize.height
        )
        let topRight = CGPoint(
            x: rectangle.topRight.x * imageSize.width,
            y: rectangle.topRight.y * imageSize.height
        )
        let bottomRight = CGPoint(
            x: rectangle.bottomRight.x * imageSize.width,
            y: rectangle.bottomRight.y * imageSize.height
        )
        let bottomLeft = CGPoint(
            x: rectangle.bottomLeft.x * imageSize.width,
            y: rectangle.bottomLeft.y * imageSize.height
        )
        
        // Calculate target dimensions for the corrected document
        let width = max(
            distance(from: topLeft, to: topRight),
            distance(from: bottomLeft, to: bottomRight)
        )
        let _ = max(
            distance(from: topLeft, to: bottomLeft),
            distance(from: topRight, to: bottomRight)
        )
        
        // Create perspective correction filter
        guard let perspectiveFilter = CIFilter(name: "CIPerspectiveCorrection") else {
            print("Failed to create CIPerspectiveCorrection filter")
            return nil
        }
        
        perspectiveFilter.setValue(inputImage, forKey: kCIInputImageKey)
        perspectiveFilter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        perspectiveFilter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        perspectiveFilter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")
        perspectiveFilter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        
        guard let correctedImage = perspectiveFilter.outputImage else {
            print("Perspective correction failed")
            return nil
        }
        
        // Scale to reasonable document size (min 300 DPI equivalent)
        let targetWidth: CGFloat = max(1200, width)  // Minimum 1200px width for good quality
        let scale = targetWidth / correctedImage.extent.width
        let scaledImage = correctedImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        
        return context.createCGImage(scaledImage, from: scaledImage.extent)
    }
    
    /// Enhances document image for better readability
    func enhanceDocument(image: CGImage) -> CGImage? {
        let inputImage = CIImage(cgImage: image)
        
        // Apply enhancement filters in sequence
        guard let enhanced = applyDocumentEnhancement(to: inputImage) else {
            return nil
        }
        
        return context.createCGImage(enhanced, from: enhanced.extent)
    }
    
    /// Processes a captured document: applies perspective correction and enhancement
    func processDocument(image: CGImage, rectangle: VNRectangleObservation) -> CGImage? {
        // First apply perspective correction
        guard let corrected = correctPerspective(image: image, rectangle: rectangle) else {
            print("Perspective correction failed")
            return nil
        }
        
        // Then enhance the document
        guard let enhanced = enhanceDocument(image: corrected) else {
            print("Document enhancement failed, returning corrected version")
            return corrected
        }
        
        return enhanced
    }
    
    // MARK: - Private Helpers
    
    private func distance(from point1: CGPoint, to point2: CGPoint) -> CGFloat {
        let dx = point1.x - point2.x
        let dy = point1.y - point2.y
        return sqrt(dx * dx + dy * dy)
    }
    
    private func applyDocumentEnhancement(to image: CIImage) -> CIImage? {
        var currentImage = image
        
        // 1. Adjust exposure for better lighting
        if let exposureFilter = CIFilter(name: "CIExposureAdjust") {
            exposureFilter.setValue(currentImage, forKey: kCIInputImageKey)
            exposureFilter.setValue(0.3, forKey: kCIInputEVKey) // Slight brightness boost
            if let output = exposureFilter.outputImage {
                currentImage = output
            }
        }
        
        // 2. Increase contrast for better text readability
        if let contrastFilter = CIFilter(name: "CIColorControls") {
            contrastFilter.setValue(currentImage, forKey: kCIInputImageKey)
            contrastFilter.setValue(1.2, forKey: kCIInputContrastKey) // 20% more contrast
            contrastFilter.setValue(1.0, forKey: kCIInputSaturationKey) // Keep saturation
            contrastFilter.setValue(0.0, forKey: kCIInputBrightnessKey) // No brightness change
            if let output = contrastFilter.outputImage {
                currentImage = output
            }
        }
        
        // 3. Apply unsharp mask for text clarity
        if let unsharpFilter = CIFilter(name: "CIUnsharpMask") {
            unsharpFilter.setValue(currentImage, forKey: kCIInputImageKey)
            unsharpFilter.setValue(0.5, forKey: kCIInputRadiusKey)
            unsharpFilter.setValue(0.8, forKey: kCIInputIntensityKey)
            if let output = unsharpFilter.outputImage {
                currentImage = output
            }
        }
        
        // 4. Optional: Convert to grayscale for smaller file size and better OCR
        // Uncomment the next block if grayscale is preferred
        /*
        if let monoFilter = CIFilter(name: "CIPhotoEffectMono") {
            monoFilter.setValue(currentImage, forKey: kCIInputImageKey)
            if let output = monoFilter.outputImage {
                currentImage = output
            }
        }
        */
        
        return currentImage
    }
}

/// Extension to save processed images as high-quality JPEG
extension DocumentProcessor {
    
    /// Saves a CGImage as high-quality JPEG to temporary directory accessible for import
    func saveAsJPEG(image: CGImage, quality: CGFloat = 0.9) -> URL? {
        // Use temporary directory with better access characteristics
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("TaxBox-Camera", isDirectory: true)
        
        // Create directory if it doesn't exist with proper permissions
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o755
            ])
        } catch {
            print("Failed to create temp directory: \(error)")
            return nil
        }
        
        let filename = "scanned_document_\(UUID().uuidString).jpg"
        let url = tempDir.appendingPathComponent(filename)
        
        print("Saving image to: \(url.path)")
        
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            print("Failed to create image destination for: \(url.path)")
            return nil
        }
        
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            print("Failed to finalize image destination for: \(url.path)")
            return nil
        }
        
        // Set proper file permissions and verify creation
        do {
            try fileManager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            
            // Verify file exists and is readable
            guard fileManager.fileExists(atPath: url.path) && fileManager.isReadableFile(atPath: url.path) else {
                print("File was created but is not accessible: \(url.path)")
                return nil
            }
            
            print("File successfully created and verified at: \(url.path)")
            return url
        } catch {
            print("Failed to set file permissions: \(error)")
            // Still return URL if file was created, just log the permission issue
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
            return nil
        }
    }
    
    /// Clean up temporary camera files
    func cleanupTempFiles() {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory.appendingPathComponent("TaxBox-Camera", isDirectory: true)
        
        do {
            if fileManager.fileExists(atPath: tempDir.path) {
                let contents = try fileManager.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                for url in contents {
                    try fileManager.removeItem(at: url)
                }
                print("Cleaned up \(contents.count) temporary camera files")
            }
        } catch {
            print("Failed to cleanup temp files: \(error)")
        }
    }
}