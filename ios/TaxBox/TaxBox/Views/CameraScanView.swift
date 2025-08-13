import SwiftUI
import AVFoundation
import Vision

struct CameraScanView: View {
    @StateObject private var cameraManager = CameraManager()
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            
            if cameraManager.permissionGranted {
                cameraPreviewContent
            } else {
                permissionView
            }
            
            // Top overlay with cancel button
            VStack {
                HStack {
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    Spacer()
                }
                .padding()
                Spacer()
            }
            
            // Bottom overlay with status and instructions
            VStack {
                Spacer()
                statusOverlay
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            cameraManager.startSession()
        }
        .onDisappear {
            cameraManager.stopSession()
        }
    }
    
    @ViewBuilder
    private var cameraPreviewContent: some View {
        GeometryReader { geometry in
            ZStack {
                // Camera preview layer
                if let previewLayer = cameraManager.previewLayer {
                    CameraPreviewView(previewLayer: previewLayer)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .onAppear {
                            print("CameraPreviewView appeared with layer")
                        }
                } else {
                    Rectangle()
                        .fill(Color.black)
                        .overlay(
                            VStack {
                                ProgressView("Starting camera...")
                                    .foregroundColor(.white)
                                if let error = cameraManager.errorMessage {
                                    Text(error)
                                        .foregroundColor(.red)
                                        .padding()
                                }
                            }
                        )
                }
                
                // Document detection overlay
                if let rectangle = cameraManager.detectedRectangle {
                    DocumentOverlayView(
                        rectangle: rectangle,
                        frameSize: geometry.size,
                        isReadyToCapture: cameraManager.isReadyToCapture
                    )
                }
            }
        }
    }
    
    @ViewBuilder
    private var permissionView: some View {
        VStack(spacing: 20) {
            Image(systemName: "camera.fill")
                .font(.system(size: 60))
                .foregroundColor(.secondary)
            
            Text("Camera Access Required")
                .font(.title2)
                .fontWeight(.semibold)
            
            if let errorMessage = cameraManager.errorMessage {
                Text(errorMessage)
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            } else {
                Text("TaxBox needs camera access to scan documents. Please grant permission to continue.")
                    .multilineTextAlignment(.center)
                    .foregroundColor(.secondary)
            }
            
            if cameraManager.errorMessage?.contains("denied") == true {
                Button("Open System Settings") {
                    if let settingsUrl = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(settingsUrl)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(maxWidth: 400)
    }
    
    @ViewBuilder
    private var statusOverlay: some View {
        VStack(spacing: 12) {
            if cameraManager.isReadyToCapture {
                HStack {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                    Text("Document detected - ready to capture")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(20)
            } else if cameraManager.detectedRectangle != nil {
                HStack {
                    Image(systemName: "viewfinder")
                        .foregroundColor(.orange)
                    Text("Hold document steady")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(20)
            } else {
                HStack {
                    Image(systemName: "doc.viewfinder")
                        .foregroundColor(.white)
                    Text("Position document in frame")
                        .fontWeight(.medium)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.7))
                .foregroundColor(.white)
                .cornerRadius(20)
            }
        }
        .padding(.bottom, 50)
    }
}

// MARK: - Camera Preview NSViewRepresentable

struct CameraPreviewView: NSViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer
    
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        
        // Set up the layer hierarchy properly
        let rootLayer = CALayer()
        rootLayer.backgroundColor = NSColor.black.cgColor
        view.layer = rootLayer
        
        // Add preview layer as sublayer
        rootLayer.addSublayer(previewLayer)
        
        // Set initial frame
        previewLayer.frame = view.bounds
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Update preview layer frame when the view size changes
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = nsView.bounds
        CATransaction.commit()
    }
}

// MARK: - Document Detection Overlay

struct DocumentOverlayView: View {
    let rectangle: VNRectangleObservation
    let frameSize: CGSize
    let isReadyToCapture: Bool
    
    var body: some View {
        let path = createRectanglePath()
        
        path
            .stroke(
                isReadyToCapture ? Color.green : Color.orange,
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round)
            )
            .animation(.easeInOut(duration: 0.3), value: isReadyToCapture)
    }
    
    private func createRectanglePath() -> Path {
        Path { path in
            // Convert Vision coordinates (bottom-left origin) to SwiftUI coordinates (top-left origin)
            let topLeft = CGPoint(
                x: rectangle.topLeft.x * frameSize.width,
                y: (1 - rectangle.topLeft.y) * frameSize.height
            )
            let topRight = CGPoint(
                x: rectangle.topRight.x * frameSize.width,
                y: (1 - rectangle.topRight.y) * frameSize.height
            )
            let bottomRight = CGPoint(
                x: rectangle.bottomRight.x * frameSize.width,
                y: (1 - rectangle.bottomRight.y) * frameSize.height
            )
            let bottomLeft = CGPoint(
                x: rectangle.bottomLeft.x * frameSize.width,
                y: (1 - rectangle.bottomLeft.y) * frameSize.height
            )
            
            path.move(to: topLeft)
            path.addLine(to: topRight)
            path.addLine(to: bottomRight)
            path.addLine(to: bottomLeft)
            path.closeSubpath()
        }
    }
}

#Preview {
    CameraScanView()
}