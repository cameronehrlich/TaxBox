import AVFoundation
import Vision
import SwiftUI

@MainActor
class SimpleCameraManager: NSObject, ObservableObject {
    @Published var isAuthorized = false
    @Published var error: String?
    @Published var detectedRectangle: VNRectangleObservation?
    
    let session = AVCaptureSession()
    let videoOutput = AVCaptureVideoDataOutput()
    private let videoQueue = DispatchQueue(label: "video.queue")
    
    override init() {
        super.init()
        
        // Check authorization synchronously
        isAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        
        // Setup video output delegate
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
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
        // Do configuration on background thread
        await withCheckedContinuation { continuation in
            videoQueue.async { [weak self] in
                guard let self = self else {
                    continuation.resume()
                    return
                }
                
                self.session.beginConfiguration()
                defer { 
                    self.session.commitConfiguration()
                    continuation.resume()
                }
                
                // Add video input
                guard let camera = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: camera) else {
                    Task { @MainActor in
                        self.error = "No camera available"
                    }
                    return
                }
                
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }
                
                // Add video output
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }
                
                // Set quality
                if self.session.canSetSessionPreset(.high) {
                    self.session.sessionPreset = .high
                }
            }
        }
    }
    
    func start() {
        videoQueue.async { [weak self] in
            self?.session.startRunning()
        }
    }
    
    func stop() {
        videoQueue.async { [weak self] in
            self?.session.stopRunning()
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
            guard let rectangles = request.results as? [VNRectangleObservation],
                  let best = rectangles.max(by: { $0.confidence < $1.confidence }),
                  best.confidence > 0.5 else { return }
            
            Task { @MainActor in
                self?.detectedRectangle = best
            }
        }
        
        request.minimumConfidence = 0.5
        request.minimumSize = 0.2
        
        try? VNImageRequestHandler(cvPixelBuffer: pixelBuffer).perform([request])
    }
}