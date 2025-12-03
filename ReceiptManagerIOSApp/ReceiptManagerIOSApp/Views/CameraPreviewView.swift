import SwiftUI
import AVFoundation

// Displays an AVCaptureSession's live camera feed.
struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    
    //Create the UIKit view
    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        // Attach the capture session to the preview layer
        v.videoPreviewLayer.session = session
        // Fill the view
        v.videoPreviewLayer.videoGravity = .resizeAspectFill
        return v
    }
    // Keep the preview's session up to date if it changes
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.videoPreviewLayer.session = session
    }
}
// UIView backed by AVCapturePreviewLayer
final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var videoPreviewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}
