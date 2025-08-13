@preconcurrency import AVFoundation
import Vision
import SwiftUI
import CoreImage
import UniformTypeIdentifiers

/// Represents a captured document with processing state
struct CapturedDocument: Identifiable, Equatable {
    let id = UUID()
    let originalImage: CGImage
    let correctedImage: CGImage?
    let detectedRectangle: VNRectangleObservation
    let timestamp: Date
    let tempURL: URL?
    
    static func == (lhs: CapturedDocument, rhs: CapturedDocument) -> Bool {
        lhs.id == rhs.id
    }
}

@MainActor
class SimpleCameraManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var error: String?
    @Published var detectedRectangle: VNRectangleObservation?
    @Published var availableCameras: [AVCaptureDevice] = []
    @Published var selectedCamera: AVCaptureDevice?
    
    // Capture functionality
    @Published var capturedImages: [CapturedDocument] = []
    @Published var isCapturing = false
    @Published var showCaptureButton = false
    @Published var autoCapture = false
    @Published var processingStatus: String? = nil
    
    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    let photoOutput = AVCapturePhotoOutput()
    private let videoQueue = DispatchQueue(label: "video.queue")
    private let photoQueue = DispatchQueue(label: "photo.queue")
    
    // Keep strong reference to photo capture delegate
    var currentCaptureDelegate: PhotoCaptureDelegate?
    
    // Document processor
    let documentProcessor = DocumentProcessor()
    
    // Document detection stability
    private var recentDetections: [VNRectangleObservation] = []
    private var stableRectangle: VNRectangleObservation?
    private var lastDetectionTime = Date()
    
    // Auto-capture timing
    private var stableDetectionStart: Date?
    private let autoCaptureDuration: TimeInterval = 2.0
    
    override init() {
        super.init()
        
        // Check authorization synchronously
        isAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        
        // Discover available cameras
        discoverCameras()
        
        // Setup video output delegate
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
    }
    
    private func discoverCameras() {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        
        availableCameras = discoverySession.devices
        
        // Select default camera (prefer built-in, then external)
        selectedCamera = availableCameras.first { $0.deviceType == .builtInWideAngleCamera }
                       ?? availableCameras.first { $0.deviceType == .external } 
                       ?? availableCameras.first
        
        print("Found \(availableCameras.count) cameras:")
        for camera in availableCameras {
            print("  - \(camera.localizedName) (\(camera.deviceType.rawValue))")
        }
    }
    
    func setup() async {
        // Request permission if needed
        guard await checkAuthorization() else { return }
        
        // Configure session on background queue
        await configureSession()
    }
    
    private func checkAuthorization() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            return true
        case .notDetermined:
            isAuthorized = await AVCaptureDevice.requestAccess(for: .video)
            if !isAuthorized {
                error = "Camera access denied"
            }
            return isAuthorized
        case .denied, .restricted:
            error = "Camera access denied. Enable in Settings."
            isAuthorized = false
            return false
        @unknown default:
            return false
        }
    }
    
    private func configureSession() async {
        // Capture references to avoid actor isolation issues
        let captureSession = session
        let captureVideoOutput = videoOutput
        let capturePhotoOutput = photoOutput
        let captureSelectedCamera = selectedCamera
        
        // Do configuration on background thread
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            videoQueue.async {
                captureSession.beginConfiguration()
                defer { 
                    captureSession.commitConfiguration()
                    continuation.resume()
                }
                
                // Remove existing inputs
                captureSession.inputs.forEach { captureSession.removeInput($0) }
                
                // Add video input from selected camera
                guard let camera = captureSelectedCamera,
                      let input = try? AVCaptureDeviceInput(device: camera) else {
                    Task { @MainActor in
                        self.error = "Cannot access selected camera"
                    }
                    return
                }
                
                if captureSession.canAddInput(input) {
                    captureSession.addInput(input)
                }
                
                // Add video output (only if not already added)
                if !captureSession.outputs.contains(captureVideoOutput) {
                    if captureSession.canAddOutput(captureVideoOutput) {
                        captureSession.addOutput(captureVideoOutput)
                    }
                }
                
                // Add photo output (only if not already added)
                if !captureSession.outputs.contains(capturePhotoOutput) {
                    if captureSession.canAddOutput(capturePhotoOutput) {
                        captureSession.addOutput(capturePhotoOutput)
                        
                        // Configure for high quality
                        if #available(macOS 13.0, *) {
                            // Modern configuration uses maxPhotoDimensions in capture settings
                        } else {
                            capturePhotoOutput.isHighResolutionCaptureEnabled = true
                        }
                    }
                }
                
                // Set quality
                if captureSession.canSetSessionPreset(.high) {
                    captureSession.sessionPreset = .high
                }
            }
        }
    }
    
    func switchCamera(to camera: AVCaptureDevice) async {
        guard camera != selectedCamera else { return }
        
        selectedCamera = camera
        await configureSession()
        
        // Restart session if it was running
        if session.isRunning {
            stop()
            start()
        }
    }
    
    func start() {
        let captureSession = session
        videoQueue.async {
            captureSession.startRunning()
        }
    }
    
    func stop() {
        let captureSession = session
        videoQueue.async {
            captureSession.stopRunning()
        }
    }
    
    // MARK: - Document Capture
    
    /// Enables or disables auto-capture mode
    func enableAutoCapture(_ enabled: Bool) {
        autoCapture = enabled
        if enabled {
            stableDetectionStart = nil
        }
    }
    
    /// Manually capture the currently detected document
    func captureDocument() {
        print("captureDocument() called")
        
        guard let rectangle = detectedRectangle else { 
            print("No detected rectangle - aborting capture")
            return 
        }
        
        guard !isCapturing else { 
            print("Already capturing - ignoring request")
            return 
        }
        
        print("Starting capture process...")
        isCapturing = true
        processingStatus = "Capturing..."
        
        // Use JPEG for compatibility
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
        
        // Enable high resolution if available  
        if #available(macOS 13.0, *) {
            // Use the highest supported photo dimensions from the output
            let maxDimensions = photoOutput.maxPhotoDimensions
            print("Max photo dimensions: \(maxDimensions.width)x\(maxDimensions.height)")
            if maxDimensions.width > 0 && maxDimensions.height > 0 {
                settings.maxPhotoDimensions = maxDimensions
            } else {
                // Fallback: Use default high resolution dimensions
                print("Max photo dimensions is 0x0, using fallback dimensions")
                // Set a reasonable high resolution fallback (4K)
                settings.maxPhotoDimensions = CMVideoDimensions(width: 3840, height: 2160)
            }
        } else {
            // For macOS < 13.0, use the legacy property
            settings.isHighResolutionPhotoEnabled = true
        }
        
        print("Photo settings configured, creating delegate...")
        
        // Store the rectangle for use in the delegate callback
        // Keep strong reference to prevent deallocation
        currentCaptureDelegate = PhotoCaptureDelegate(manager: self, rectangle: rectangle)
        print("Calling photoOutput.capturePhoto...")
        
        photoOutput.capturePhoto(with: settings, delegate: currentCaptureDelegate!)
        print("capturePhoto called - waiting for delegate callback")
    }
    
    /// Clear all captured documents and temporary files
    func clearCapturedDocuments() {
        // Clean up temporary files individually
        for document in capturedImages {
            if let tempURL = document.tempURL {
                do {
                    try FileManager.default.removeItem(at: tempURL)
                    print("Removed temp file: \(tempURL.path)")
                } catch {
                    print("Failed to remove temp file \(tempURL.path): \(error)")
                }
            }
        }
        
        
        capturedImages.removeAll()
        processingStatus = nil
    }
    
    /// Get URLs of all successfully processed documents with verification
    func getCapturedDocumentURLs() -> [URL] {
        let urls = capturedImages.compactMap { $0.tempURL }
        let fileManager = FileManager.default
        
        print("getCapturedDocumentURLs returning \(urls.count) URLs:")
        for (index, url) in urls.enumerated() {
            let fileExists = fileManager.fileExists(atPath: url.path)
            let isReadable = fileManager.isReadableFile(atPath: url.path)
            let fileSize: Int64
            
            do {
                let attributes = try fileManager.attributesOfItem(atPath: url.path)
                fileSize = attributes[.size] as? Int64 ?? 0
            } catch {
                fileSize = 0
            }
            
            print("  [\(index)]: \(url.path) (exists: \(fileExists), readable: \(isReadable), size: \(fileSize) bytes)")
            
            // Warn about potential issues
            if fileExists && !isReadable {
                print("  WARNING: File exists but is not readable!")
            }
            if fileExists && fileSize == 0 {
                print("  WARNING: File exists but has zero size!")
            }
        }
        
        // Only return URLs for files that exist and are readable
        return urls.filter { url in
            fileManager.fileExists(atPath: url.path) && fileManager.isReadableFile(atPath: url.path)
        }
    }
}

// MARK: - Video Capture Delegate
extension SimpleCameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, 
                                   didOutput sampleBuffer: CMSampleBuffer, 
                                   from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let request = VNDetectRectanglesRequest { [weak self] request, _ in
            guard let self = self,
                  let rectangles = request.results as? [VNRectangleObservation] else { return }
            
            // Filter for document-like rectangles
            let documentCandidates = rectangles.filter { rect in
                return self.isDocumentLikeRectangle(rect)
            }
            
            guard let best = documentCandidates.max(by: { $0.confidence < $1.confidence }) else {
                // No good candidates, clear detection after delay
                Task { @MainActor in
                    self.clearDetectionIfStale()
                }
                return
            }
            
            Task { @MainActor in
                self.updateDetectionWithStability(best)
            }
        }
        
        // Stricter detection parameters for better accuracy
        request.minimumConfidence = 0.7
        request.minimumSize = 0.15  // At least 15% of screen
        request.maximumObservations = 5  // Limit to best candidates
        
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
    }
    
    private func updateDetectionWithStability(_ rectangle: VNRectangleObservation) {
        let now = Date()
        
        // Add to recent detections
        recentDetections.append(rectangle)
        
        // Keep only recent detections (last 0.5 seconds)  
        recentDetections.removeAll { _ in now.timeIntervalSince(lastDetectionTime) > 0.5 }
        
        // Check if we have enough stable detections
        if recentDetections.count >= 3 {
            // Find average rectangle from recent detections
            let averageRect = averageRectangle(from: recentDetections)
            
            // Only update if the rectangle is significantly different or we don't have one
            if stableRectangle == nil || !rectanglesAreSimilar(averageRect, stableRectangle!) {
                stableRectangle = averageRect
                detectedRectangle = averageRect
                showCaptureButton = true
                
                // Reset auto-capture timer when rectangle changes
                stableDetectionStart = now
            } else if let startTime = stableDetectionStart,
                      autoCapture && !isCapturing && 
                      now.timeIntervalSince(startTime) >= autoCaptureDuration {
                // Auto-capture if rectangle has been stable long enough
                captureDocument()
            }
        } else {
            // Not enough stable detections
            showCaptureButton = false
        }
        
        lastDetectionTime = now
    }
    
    private func clearDetectionIfStale() {
        let now = Date()
        if now.timeIntervalSince(lastDetectionTime) > 1.0 {
            detectedRectangle = nil
            stableRectangle = nil
            recentDetections.removeAll()
            showCaptureButton = false
            stableDetectionStart = nil
        }
    }
    
    private nonisolated func isDocumentLikeRectangle(_ rect: VNRectangleObservation) -> Bool {
        // Calculate aspect ratio
        let width = max(rect.topRight.x - rect.topLeft.x, rect.bottomRight.x - rect.bottomLeft.x)
        let height = max(rect.topLeft.y - rect.bottomLeft.y, rect.topRight.y - rect.bottomRight.y)
        
        guard width > 0, height > 0 else { return false }
        
        let aspectRatio = width / height
        
        // Accept document-like aspect ratios (roughly 0.5 to 2.0)
        // This covers portrait/landscape documents, receipts, business cards
        guard aspectRatio > 0.3 && aspectRatio < 3.0 else { return false }
        
        // Must have good confidence
        guard rect.confidence > 0.7 else { return false }
        
        // Must be reasonably large (at least 15% of frame)
        let area = width * height
        guard area > 0.15 else { return false }
        
        return true
    }
    
    private nonisolated func averageRectangle(from rectangles: [VNRectangleObservation]) -> VNRectangleObservation {
        // For stability, use the most recent rectangle with highest confidence
        // This avoids the deprecated initializer while still providing stable detection
        return rectangles.max(by: { $0.confidence < $1.confidence }) ?? rectangles.first!
    }
    
    private nonisolated func rectanglesAreSimilar(_ rect1: VNRectangleObservation, _ rect2: VNRectangleObservation) -> Bool {
        let threshold: CGFloat = 0.05  // 5% threshold
        
        return abs(rect1.topLeft.x - rect2.topLeft.x) < threshold &&
               abs(rect1.topLeft.y - rect2.topLeft.y) < threshold &&
               abs(rect1.bottomRight.x - rect2.bottomRight.x) < threshold &&
               abs(rect1.bottomRight.y - rect2.bottomRight.y) < threshold
    }
}

// MARK: - Photo Capture Delegate
class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private weak var manager: SimpleCameraManager?
    private let rectangle: VNRectangleObservation
    
    init(manager: SimpleCameraManager, rectangle: VNRectangleObservation) {
        self.manager = manager
        self.rectangle = rectangle
    }
    
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        print("PhotoCaptureDelegate: didFinishProcessingPhoto called")
        
        Task { @MainActor in
            guard let manager = self.manager else { 
                print("PhotoCaptureDelegate: Manager is nil")
                return
            }
            
            if let error = error {
                print("Photo capture error: \(error)")
                manager.processingStatus = "Capture failed"
                manager.isCapturing = false
                manager.currentCaptureDelegate = nil
                return
            }
            
            guard let imageData = photo.fileDataRepresentation() else {
                print("Failed to get image data from captured photo")
                manager.processingStatus = "Processing failed"
                manager.isCapturing = false
                manager.currentCaptureDelegate = nil
                return
            }
            
            guard let image = NSImage(data: imageData) else {
                print("Failed to create NSImage from data")
                manager.processingStatus = "Processing failed"
                manager.isCapturing = false
                manager.currentCaptureDelegate = nil
                return
            }
            
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("Failed to get CGImage from NSImage")
                manager.processingStatus = "Processing failed"
                manager.isCapturing = false
                manager.currentCaptureDelegate = nil
                return
            }
            
            print("Successfully got CGImage, starting processing...")
            manager.processingStatus = "Processing document..."
            
            // Capture processor reference to avoid actor isolation issues
            let processor = manager.documentProcessor
            let captureRectangle = self.rectangle
            
            // Process the document on background queue
            Task.detached {
                print("Processing document in background...")
                let processedImage = processor.processDocument(
                    image: cgImage,
                    rectangle: captureRectangle
                )
                
                // Save to temporary file
                var tempURL: URL? = nil
                if let processed = processedImage {
                    print("Document processed successfully, saving to temp file...")
                    tempURL = processor.saveAsJPEG(image: processed)
                    if tempURL != nil {
                        print("Saved to temp file: \(tempURL!)")
                    } else {
                        print("Failed to save to temp file")
                    }
                } else {
                    print("Document processing failed")
                }
                
                // Create captured document
                let capturedDoc = CapturedDocument(
                    originalImage: cgImage,
                    correctedImage: processedImage,
                    detectedRectangle: captureRectangle,
                    timestamp: Date(),
                    tempURL: tempURL
                )
                
                print("Created CapturedDocument, updating UI...")
                
                // Update UI on main actor
                await MainActor.run {
                    manager.capturedImages.append(capturedDoc)
                    manager.isCapturing = false
                    manager.processingStatus = nil
                    manager.currentCaptureDelegate = nil  // Clear delegate reference
                    
                    print("Updated UI - capture complete")
                    
                    // Flash effect - briefly show capture success
                    Task {
                        manager.processingStatus = "Captured!"
                        try? await Task.sleep(for: .seconds(0.5))
                        manager.processingStatus = nil
                        print("Flash effect complete")
                    }
                }
            }
        }
    }
    
    /// Save processed image to accessible temporary location
    static func saveImageToTempFile(image: CGImage) -> URL? {
        // Use NSTemporaryDirectory() for better sandboxing compatibility
        let tempPath = NSTemporaryDirectory() + "TaxBox-Camera/"
        let tempDir = URL(fileURLWithPath: tempPath)
        
        // Create directory if needed
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: nil)
        } catch {
            print("Failed to create temp directory: \(error)")
            return nil
        }
        
        let filename = "scanned_document_\(UUID().uuidString).jpg"
        let url = tempDir.appendingPathComponent(filename)
        
        print("Saving image to: \(url.path)")
        
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            print("Failed to create image destination")
            return nil
        }
        
        let properties: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ]
        
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        
        guard CGImageDestinationFinalize(destination) else {
            print("Failed to finalize image destination")
            return nil
        }
        
        // Verify file was created and is accessible
        if FileManager.default.fileExists(atPath: url.path) && FileManager.default.isReadableFile(atPath: url.path) {
            print("File successfully created and verified at: \(url.path)")
            return url
        } else {
            print("File was not created or is not accessible: \(url.path)")
            return nil
        }
    }
    
    /// Clean up temporary camera files
    private func cleanupTempFiles() {
        let tempPath = NSTemporaryDirectory() + "TaxBox-Camera/"
        let tempDir = URL(fileURLWithPath: tempPath)
        
        do {
            if FileManager.default.fileExists(atPath: tempDir.path) {
                let contents = try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
                for url in contents {
                    try FileManager.default.removeItem(at: url)
                }
                print("Cleaned up \(contents.count) temporary camera files")
            }
        } catch {
            print("Failed to cleanup temp files: \(error)")
        }
    }
}