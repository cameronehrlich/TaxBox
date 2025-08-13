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
                        // Enhanced detection overlay with smooth animations
                        if let rect = camera.smoothRectangle ?? camera.detectedRectangle {
                            PremiumDetectionOverlay(
                                rectangle: rect,
                                detectionState: camera.detectionState,
                                captureProgress: camera.captureProgress
                            )
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
                // Premium status messaging based on detection state
                switch camera.detectionState {
                case .searching:
                    if !camera.capturedImages.isEmpty {
                        Label("\(camera.capturedImages.count) document(s) captured", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    } else {
                        Label("Position document in frame", systemImage: "doc.viewfinder")
                            .foregroundColor(.white)
                    }
                    
                case .found:
                    Label("Document found - hold steady", systemImage: "target")
                        .foregroundColor(.yellow)
                    
                case .stable:
                    if camera.autoCapture {
                        HStack {
                            Label("Auto-capturing", systemImage: "camera.fill")
                                .foregroundColor(.green)
                            
                            // Elegant progress indicator
                            if camera.captureProgress > 0 {
                                ProgressView(value: camera.captureProgress)
                                    .frame(width: 40)
                                    .accentColor(.green)
                            }
                        }
                    } else {
                        Label("Ready to capture", systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                    }
                    
                case .capturing:
                    Label("Capturing...", systemImage: "camera.fill")
                        .foregroundColor(.blue)
                    
                case .processing:
                    Label("Enhancing document...", systemImage: "wand.and.rays")
                        .foregroundColor(.purple)
                    
                case .success:
                    Label("Captured successfully!", systemImage: "checkmark.circle.fill")
                        .foregroundColor(.green)
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

// MARK: - Premium Document Detection Overlay
struct PremiumDetectionOverlay: View {
    let rectangle: VNRectangleObservation
    let detectionState: DetectionState
    let captureProgress: Double
    
    @State private var pulseOpacity: Double = 0.3
    @State private var cornerPulse: Double = 1.0
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Main rectangle outline with state-based styling
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
                .stroke(strokeColor, lineWidth: strokeWidth)
                .background(
                    Path { path in
                        let size = geometry.size
                        
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
                    .fill(fillColor.opacity(pulseOpacity))
                )
                .animation(.easeInOut(duration: 0.3), value: detectionState)
                .animation(.easeInOut(duration: 0.3), value: rectangle.confidence)
                
                // Corner indicators for stable detection
                if detectionState == .stable {
                    cornerIndicators(in: geometry.size)
                        .scaleEffect(cornerPulse)
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: cornerPulse)
                }
                
                // Capture progress ring for auto-capture
                if detectionState == .stable && captureProgress > 0 {
                    captureProgressRing(in: geometry.size)
                }
            }
        }
        .onAppear {
            startAnimations()
        }
        .onChange(of: detectionState) { _, newState in
            updateAnimationForState(newState)
        }
    }
    
    private var strokeColor: Color {
        switch detectionState {
        case .searching: return Color.white.opacity(0.5)
        case .found: return Color.yellow
        case .stable: return Color.green
        case .capturing: return Color.blue
        case .processing: return Color.purple
        case .success: return Color.green
        }
    }
    
    private var fillColor: Color {
        switch detectionState {
        case .searching: return Color.clear
        case .found: return Color.yellow
        case .stable: return Color.green
        case .capturing: return Color.blue
        case .processing: return Color.purple
        case .success: return Color.green
        }
    }
    
    private var strokeWidth: CGFloat {
        switch detectionState {
        case .searching: return 2
        case .found: return 3
        case .stable: return 4
        case .capturing: return 5
        case .processing: return 4
        case .success: return 6
        }
    }
    
    private func cornerIndicators(in size: CGSize) -> some View {
        let cornerSize: CGFloat = 20
        let corners = [
            CGPoint(x: rectangle.topLeft.x * size.width, y: (1 - rectangle.topLeft.y) * size.height),
            CGPoint(x: rectangle.topRight.x * size.width, y: (1 - rectangle.topRight.y) * size.height),
            CGPoint(x: rectangle.bottomLeft.x * size.width, y: (1 - rectangle.bottomLeft.y) * size.height),
            CGPoint(x: rectangle.bottomRight.x * size.width, y: (1 - rectangle.bottomRight.y) * size.height)
        ]
        
        return ForEach(0..<corners.count, id: \.self) { index in
            RoundedRectangle(cornerRadius: 3)
                .stroke(Color.green, lineWidth: 3)
                .frame(width: cornerSize, height: cornerSize)
                .position(corners[index])
        }
    }
    
    private func captureProgressRing(in size: CGSize) -> some View {
        let center = CGPoint(
            x: size.width / 2,
            y: size.height / 2
        )
        
        return Circle()
            .trim(from: 0, to: captureProgress)
            .stroke(Color.green, style: StrokeStyle(lineWidth: 6, lineCap: .round))
            .frame(width: 60, height: 60)
            .rotationEffect(.degrees(-90))
            .position(center)
            .animation(.easeInOut(duration: 0.1), value: captureProgress)
    }
    
    private func startAnimations() {
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            pulseOpacity = 0.1
        }
        
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
            cornerPulse = 1.1
        }
    }
    
    private func updateAnimationForState(_ state: DetectionState) {
        switch state {
        case .found:
            pulseOpacity = 0.2
        case .stable:
            pulseOpacity = 0.15
        case .capturing, .success:
            pulseOpacity = 0.3
        default:
            pulseOpacity = 0.1
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