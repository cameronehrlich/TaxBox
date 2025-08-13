import Foundation
import AVFoundation
import Vision
import AppKit

@MainActor
final class CameraManager: NSObject, ObservableObject {
    @Published var previewLayer: AVCaptureVideoPreviewLayer?
    @Published var detectedRectangle: VNRectangleObservation?
    @Published var isReadyToCapture = false
    @Published var permissionGranted = false
    @Published var errorMessage: String?
    
    private let captureSession = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let videoDataQueue = DispatchQueue(label: "camera.video.queue", qos: .userInitiated)
    private var currentDevice: AVCaptureDevice?
    
    // Document detection configuration
    private let minimumConfidence: Float = 0.7
    private let minimumSize: Float = 0.2
    private let aspectRatioRange: ClosedRange<Float> = 0.3...3.0
    
    override init() {
        super.init()
        setupVideoOutput()
        // Check permission synchronously first
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        self.permissionGranted = (status == .authorized)
        print("Init: Camera permission status: \(status.rawValue), granted: \(permissionGranted)")
        
        // Then do async setup if needed
        checkCameraPermission()
    }
    
    private func setupVideoOutput() {
        videoOutput.setSampleBufferDelegate(self, queue: videoDataQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
    }
    
    private func checkCameraPermission() {
        Task { @MainActor in
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            print("Camera authorization status: \(status.rawValue)")
            
            switch status {
            case .authorized:
                print("Camera already authorized")
                self.permissionGranted = true
                await self.setupCameraSession()
            case .notDetermined:
                print("Camera permission not determined, requesting...")
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                print("Camera permission granted: \(granted)")
                self.permissionGranted = granted
                if granted {
                    await self.setupCameraSession()
                } else {
                    self.errorMessage = "Camera access is required to scan documents"
                }
            case .denied:
                print("Camera access denied")
                self.permissionGranted = false
                self.errorMessage = "Camera access was denied. Please enable it in System Settings to scan documents."
            case .restricted:
                print("Camera access restricted")
                self.permissionGranted = false
                self.errorMessage = "Camera access is restricted on this device."
            @unknown default:
                print("Camera access unknown")
                self.permissionGranted = false
                self.errorMessage = "Camera access status unknown"
            }
        }
    }
    
    private func setupCameraSession() async {
        await Task.detached { [weak self] in
            guard let self = self else { return }
            
            // Find the best camera device
            guard let device = await self.findBestCameraDevice() else {
                await MainActor.run {
                    self.errorMessage = "No camera available on this device"
                }
                return
            }
            
            do {
                let input = try AVCaptureDeviceInput(device: device)
                
                await MainActor.run {
                    self.captureSession.beginConfiguration()
                    
                    // Remove existing inputs and outputs
                    for input in self.captureSession.inputs {
                        self.captureSession.removeInput(input)
                    }
                    for output in self.captureSession.outputs {
                        self.captureSession.removeOutput(output)
                    }
                    
                    // Add new input and output
                    if self.captureSession.canAddInput(input) {
                        self.captureSession.addInput(input)
                        self.currentDevice = device
                    }
                    
                    if self.captureSession.canAddOutput(self.videoOutput) {
                        self.captureSession.addOutput(self.videoOutput)
                    }
                    
                    // Set session quality
                    if self.captureSession.canSetSessionPreset(.photo) {
                        self.captureSession.sessionPreset = .photo
                    } else if self.captureSession.canSetSessionPreset(.high) {
                        self.captureSession.sessionPreset = .high
                    }
                    
                    self.captureSession.commitConfiguration()
                    
                    // Create preview layer
                    let previewLayer = AVCaptureVideoPreviewLayer(session: self.captureSession)
                    previewLayer.videoGravity = .resizeAspectFill
                    self.previewLayer = previewLayer
                    
                    // Start the session now that it's configured
                    print("Setup complete, starting session immediately")
                    self.captureSession.startRunning()
                    print("Session is running: \(self.captureSession.isRunning)")
                }
                
            } catch {
                await MainActor.run {
                    self.errorMessage = "Failed to setup camera: \(error.localizedDescription)"
                }
            }
        }.value
    }
    
    private func findBestCameraDevice() async -> AVCaptureDevice? {
        // For macOS, we need to use the default device or discover devices differently
        // First try to get the default video device
        if let defaultDevice = AVCaptureDevice.default(for: .video) {
            print("Using default camera: \(defaultDevice.localizedName)")
            return defaultDevice
        }
        
        // If no default, try discovery session with all device types
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video,
            position: .unspecified
        )
        
        // Log available devices for debugging
        print("Available cameras: \(discoverySession.devices.map { $0.localizedName })")
        
        // Prefer external cameras if available, then built-in
        for device in discoverySession.devices {
            if device.deviceType == .external {
                print("Using external camera: \(device.localizedName)")
                return device
            }
        }
        
        // Fall back to any available camera
        if let firstDevice = discoverySession.devices.first {
            print("Using camera: \(firstDevice.localizedName)")
            return firstDevice
        }
        
        print("No camera devices found")
        return nil
    }
    
    func startSession() {
        print("startSession called, permissionGranted: \(permissionGranted)")
        
        if !permissionGranted {
            // Re-check permission status
            checkCameraPermission()
            return
        }
        
        // If session is already running, do nothing
        if captureSession.isRunning {
            print("Session already running")
            return
        }
        
        // If session needs setup, do it
        if captureSession.inputs.isEmpty {
            print("No inputs, setting up camera session")
            Task {
                await setupCameraSession()
                // Session will be started automatically in setupCameraSession
            }
        } else {
            // Session already configured, just restart it
            print("Restarting existing session")
            Task.detached { [captureSession] in
                captureSession.startRunning()
                print("Capture session running: \(captureSession.isRunning)")
            }
        }
    }
    
    func stopSession() {
        let session = captureSession
        Task.detached {
            session.stopRunning()
        }
    }
    
    private nonisolated func processVideoFrame(_ sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        
        let request = VNDetectRectanglesRequest { [weak self] request, error in
            guard let self = self else { return }
            
            if let error = error {
                print("Document detection error: \(error)")
                return
            }
            
            guard let observations = request.results as? [VNRectangleObservation] else { return }
            
            // Find the best rectangle that meets our criteria
            let validRectangles = observations.filter { observation in
                self.isValidDocumentRectangle(observation)
            }
            
            let bestRectangle = validRectangles.max { first, second in
                first.confidence < second.confidence
            }
            
            Task { @MainActor in
                self.detectedRectangle = bestRectangle
                self.isReadyToCapture = bestRectangle != nil && bestRectangle!.confidence > self.minimumConfidence
            }
        }
        
        // Configure the request for document detection
        request.minimumAspectRatio = VNAspectRatio(aspectRatioRange.lowerBound)
        request.maximumAspectRatio = VNAspectRatio(aspectRatioRange.upperBound)
        request.minimumSize = minimumSize
        request.minimumConfidence = minimumConfidence
        request.maximumObservations = 5
        
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        
        do {
            try handler.perform([request])
        } catch {
            print("Failed to perform document detection: \(error)")
        }
    }
    
    private nonisolated func isValidDocumentRectangle(_ observation: VNRectangleObservation) -> Bool {
        // Check confidence
        guard observation.confidence >= minimumConfidence else { return false }
        
        // Calculate size of the rectangle
        let width = abs(observation.topRight.x - observation.topLeft.x)
        let height = abs(observation.topLeft.y - observation.bottomLeft.y)
        let area = width * height
        
        // Check minimum size
        guard area >= CGFloat(minimumSize) else { return false }
        
        // Check aspect ratio
        let aspectRatio = Float(width / height)
        guard aspectRatioRange.contains(aspectRatio) || aspectRatioRange.contains(1.0 / aspectRatio) else { return false }
        
        return true
    }
    
    deinit {
        // Synchronously stop the capture session 
        captureSession.stopRunning()
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        processVideoFrame(sampleBuffer)
    }
    
    nonisolated func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        // Frame was dropped, no action needed
    }
}