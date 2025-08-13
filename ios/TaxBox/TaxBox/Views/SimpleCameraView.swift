import SwiftUI
import AVFoundation
import Vision

struct SimpleCameraView: View {
    @StateObject private var camera = SimpleCameraManager()
    @Environment(\.dismiss) private var dismiss
    
    // Completion handler for captured documents
    var onDocumentsCaptured: (([URL]) -> Void)? = nil
    
    @State private var showCapturedPreview = false
    
    var body: some View {
        ZStack {
            // Camera preview or error state
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        VStack(spacing: 12) {
                            // Captured images preview strip
                            if !camera.capturedImages.isEmpty {
                                capturedImagesStrip
                            }
                            
                            // Capture controls
                            captureControls
                            
                            statusBar
                        }
                    }
                    .overlay(alignment: .topLeading) {
                        HStack {
                            cancelButton
                            Spacer()
                            if camera.availableCameras.count > 1 {
                                cameraSelector
                            }
                        }
                    }
                    .overlay {
                        if let rect = camera.detectedRectangle {
                            DocumentDetectionOverlay(rectangle: rect)
                        }
                    }
            } else {
                VStack(spacing: 20) {
                    Image(systemName: "camera.fill")
                        .font(.system(size: 60))
                        .foregroundColor(.secondary)
                    
                    Text("Camera Access Required")
                        .font(.title2)
                    
                    if let error = camera.error {
                        Text(error)
                            .foregroundColor(.secondary)
                        
                        Button("Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                .frame(maxWidth: 400)
                .overlay(alignment: .topLeading) {
                    cancelButton
                }
            }
        }
        .frame(minWidth: 800, minHeight: 600)
        .background(Color.black)
        .task {
            await camera.setup()
            camera.start()
        }
        .onDisappear {
            camera.stop()
            // Don't immediately clean up temporary files - let the import process handle them
            // Only clean up if the user cancels without using the "Done" button
            if camera.capturedImages.isEmpty {
                Task {
                    try? await Task.sleep(for: .seconds(1))
                    camera.clearCapturedDocuments()
                }
            }
        }
    }
    
    private var cancelButton: some View {
        Button("Cancel") {
            dismiss()
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }
    
    private var cameraSelector: some View {
        Menu {
            ForEach(camera.availableCameras, id: \.uniqueID) { device in
                Button {
                    Task {
                        await camera.switchCamera(to: device)
                    }
                } label: {
                    HStack {
                        Text(device.localizedName)
                        if device == camera.selectedCamera {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "camera.rotate")
                Text("Camera")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.black.opacity(0.7))
            .foregroundColor(.white)
            .cornerRadius(8)
        }
        .menuStyle(.borderlessButton)
        .padding()
    }
    
    private var capturedImagesStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(camera.capturedImages) { document in
                    CapturedImageThumbnail(document: document)
                        .frame(width: 60, height: 80)
                }
            }
            .padding(.horizontal)
        }
        .frame(height: 80)
    }
    
    private var captureControls: some View {
        HStack(spacing: 16) {
            // Auto-capture toggle
            Button {
                camera.enableAutoCapture(!camera.autoCapture)
            } label: {
                Image(systemName: camera.autoCapture ? "timer.circle.fill" : "timer.circle")
                    .font(.title2)
                    .foregroundColor(camera.autoCapture ? .green : .white)
            }
            .help("Auto capture (2s timer)")
            
            // Manual capture button
            if camera.showCaptureButton {
                Button {
                    Task {
                        camera.captureDocument()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(.white)
                            .frame(width: 70, height: 70)
                        
                        if camera.isCapturing {
                            ProgressView()
                                .progressViewStyle(CircularProgressViewStyle(tint: .blue))
                        } else {
                            Circle()
                                .fill(.blue)
                                .frame(width: 60, height: 60)
                        }
                    }
                }
                .disabled(camera.isCapturing)
                .help("Capture document")
            }
            
            // Clear captured documents button  
            if !camera.capturedImages.isEmpty {
                Button {
                    camera.clearCapturedDocuments()
                } label: {
                    Image(systemName: "trash.circle")
                        .font(.title2)
                        .foregroundColor(.red)
                }
                .help("Clear captured documents")
            }
            
            // Done button (appears when documents captured)
            if !camera.capturedImages.isEmpty {
                Button {
                    let urls = camera.getCapturedDocumentURLs()
                    print("Done button tapped - passing \(urls.count) URLs to completion handler")
                    
                    if !urls.isEmpty {
                        if let onDocumentsCaptured = onDocumentsCaptured {
                            onDocumentsCaptured(urls)
                        }
                        dismiss()
                    } else {
                        print("No valid URLs to pass - keeping camera open")
                        // Could show an error message here
                    }
                } label: {
                    HStack {
                        Text("Done")
                        Text("(\(camera.capturedImages.count))")
                        if camera.capturedImages.contains(where: { $0.tempURL == nil }) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.orange)
                                .font(.caption)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.green)
                    .foregroundColor(.white)
                    .cornerRadius(20)
                }
                .help("Import \(camera.capturedImages.count) captured document(s)")
                .disabled(camera.capturedImages.allSatisfy { $0.tempURL == nil })
            }
        }
        .padding()
        .background(.black.opacity(0.7))
        .cornerRadius(25)
        .padding(.horizontal)
    }
    
    private var statusBar: some View {
        VStack(spacing: 8) {
            HStack {
                if let status = camera.processingStatus {
                    Label(status, systemImage: "doc.text.magnifyingglass")
                        .foregroundColor(.yellow)
                } else if !camera.capturedImages.isEmpty {
                    Label("\(camera.capturedImages.count) document(s) captured", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else if camera.detectedRectangle != nil {
                    Label("Document detected", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
                } else {
                    Label("Position document in frame", systemImage: "doc.viewfinder")
                        .foregroundColor(.white)
                }
            }
            
            if let selectedCamera = camera.selectedCamera {
                Text("Using: \(selectedCamera.localizedName)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if camera.autoCapture && camera.detectedRectangle != nil {
                Text("Auto-capture in 2 seconds...")
                    .font(.caption)
                    .foregroundColor(.green)
            }
        }
        .padding()
        .background(.black.opacity(0.7))
        .cornerRadius(20)
        .padding()
    }
}

// MARK: - Camera Preview
struct CameraPreview: NSViewRepresentable {
    let session: AVCaptureSession
    
    class PreviewView: NSView {
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            self.wantsLayer = true
            self.layer?.backgroundColor = NSColor.black.cgColor
        }
        
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }
        
        var previewLayer: AVCaptureVideoPreviewLayer {
            return layer as! AVCaptureVideoPreviewLayer
        }
        
        override func makeBackingLayer() -> CALayer {
            let layer = AVCaptureVideoPreviewLayer()
            layer.videoGravity = .resizeAspectFill
            return layer
        }
    }
    
    func makeNSView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        return view
    }
    
    func updateNSView(_ nsView: PreviewView, context: Context) {
        // Nothing to update
    }
}

// MARK: - Document Detection Overlay
struct DocumentDetectionOverlay: View {
    let rectangle: VNRectangleObservation
    
    var body: some View {
        GeometryReader { geometry in
            Path { path in
                let size = geometry.size
                
                // Convert normalized coordinates to view coordinates
                // Vision uses bottom-left origin, SwiftUI uses top-left
                let topLeft = CGPoint(
                    x: rectangle.topLeft.x * size.width,
                    y: (1 - rectangle.topLeft.y) * size.height
                )
                let topRight = CGPoint(
                    x: rectangle.topRight.x * size.width,
                    y: (1 - rectangle.topRight.y) * size.height
                )
                let bottomRight = CGPoint(
                    x: rectangle.bottomRight.x * size.width,
                    y: (1 - rectangle.bottomRight.y) * size.height
                )
                let bottomLeft = CGPoint(
                    x: rectangle.bottomLeft.x * size.width,
                    y: (1 - rectangle.bottomLeft.y) * size.height
                )
                
                path.move(to: topLeft)
                path.addLine(to: topRight)
                path.addLine(to: bottomRight)
                path.addLine(to: bottomLeft)
                path.closeSubpath()
            }
            .stroke(Color.green, lineWidth: 3)
            .animation(.easeInOut(duration: 0.2), value: rectangle.confidence)
        }
    }
}

// MARK: - Captured Image Thumbnail
struct CapturedImageThumbnail: View {
    let document: CapturedDocument
    
    var body: some View {
        Group {
            if let corrected = document.correctedImage {
                Image(nsImage: NSImage(cgImage: corrected, size: .zero))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSImage(cgImage: document.originalImage, size: .zero))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            }
        }
        .background(Color.black)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green, lineWidth: 2)
        )
        .overlay(alignment: .topTrailing) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundColor(.green)
                .background(Circle().fill(Color.black.opacity(0.7)))
                .offset(x: 4, y: -4)
        }
    }
}