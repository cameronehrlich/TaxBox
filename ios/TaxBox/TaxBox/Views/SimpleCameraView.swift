import SwiftUI
import AVFoundation
import Vision

struct SimpleCameraView: View {
    @StateObject private var camera = SimpleCameraManager()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            // Camera preview or error state
            if camera.isAuthorized {
                CameraPreview(session: camera.session)
                    .ignoresSafeArea()
                    .overlay(alignment: .bottom) {
                        statusBar
                    }
                    .overlay(alignment: .topLeading) {
                        cancelButton
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
        }
    }
    
    private var cancelButton: some View {
        Button("Cancel") {
            dismiss()
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }
    
    private var statusBar: some View {
        HStack {
            if camera.detectedRectangle != nil {
                Label("Document detected", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
            } else {
                Label("Position document in frame", systemImage: "doc.viewfinder")
                    .foregroundColor(.white)
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
        }
    }
}