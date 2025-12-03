    import Foundation
@preconcurrency import AVFoundation
import UIKit
import Combine

@MainActor
final class CameraController: NSObject, ObservableObject {
    // Error cases for camera usage
    enum CameraError: LocalizedError {
        case unauthorized
        case configurationFailed
        case noCameraAvailable
        case sessionInterrupted
        case unknown
        // User-facing descriptions for each error
        var errorDescription: String? {
            switch self {
            case .unauthorized: return "Camera access is denied. Please enable it in Settings."
            case .configurationFailed: return "Failed to configure the camera."
            case .noCameraAvailable: return "No camera is available on this device."
            case .sessionInterrupted: return "Camera session was interrupted."
            case .unknown: return "Unknown camera error."
            }
        }
    }
    // Is the AVCaptureSession running?
    @Published var isSessionRunning = false
    // Has the user allowed camera access?
    @Published var isAuthorized = false
    // Last error the camera controller encountered
    @Published var lastError: CameraError?
    // The capture session thats used for photo capture
    let session = AVCaptureSession()
    // Separate queue to relieve main thread
    private let sessionQueue = DispatchQueue(label: "CameraController.sessionQueue")
    // Output for capturing images
    private let photoOutput = AVCapturePhotoOutput()
    // The current input device
    private var videoDeviceInput: AVCaptureDeviceInput?
    override init() {
        super.init()
        // Use the .photo preset for quality
        session.sessionPreset = .photo
    }
    // Check / request camera permissions from the user
    func checkPermissions() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            // Already authorizee
            isAuthorized = true
        case .notDetermined:
            // First time: request access and update state
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
        default:
            // Denied access
            isAuthorized = false
            lastError = .unauthorized
        }
    }
    // Configure the capture session with camera (input) and photo (output)
    func configureSession() async {
        guard isAuthorized else { return }

        // Capture the session reference on the main actor to avoid isolation warnings
        let session = self.session
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }

                session.beginConfiguration()

                // Input (camera device)
                do {
                    // Find the best camera
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ??
                            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    else {
                        // No suitable camera found
                        Task { @MainActor in self.lastError = .noCameraAvailable }
                        session.commitConfiguration()
                        continuation.resume()
                        return
                    }
                    // Wrap the device in an AVCaptureDeviceInput
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) {
                        session.addInput(input)
                        // Safe to assign captured input back on main actor
                        Task { @MainActor in self.videoDeviceInput = input }
                    } else {
                        // Session refused the input
                        Task { @MainActor in self.lastError = .configurationFailed }
                        session.commitConfiguration()
                        continuation.resume()
                        return
                    }
                } catch {
                    Task { @MainActor in self.lastError = .configurationFailed }
                    session.commitConfiguration()
                    continuation.resume()
                    return
                }
                // Output (photo capture)
                if session.canAddOutput(self.photoOutput) {
                    session.addOutput(self.photoOutput)
                    self.photoOutput
                        // Enable high-resolution capture
                        .isHighResolutionCaptureEnabled = true
                } else {
                    // Unable to add the photo output
                    Task { @MainActor in self.lastError = .configurationFailed }
                    session.commitConfiguration()
                    continuation.resume()
                    return
                }
                // All is good, configure
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }
    // Start the capture session if auuthorized
    func startSession() {
        guard isAuthorized else { return }
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Only start if not already running
            if !session.isRunning {
                session.startRunning()
                Task { @MainActor in self.isSessionRunning = true }
            }
        }
    }
    // Stop the capture session if it's running
    func stopSession() {
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning {
                session.stopRunning()
                // Update published state
                Task { @MainActor in self.isSessionRunning = false }
            }
        }
    }
    // Function for allowing zoom on the camera
    func setZoom(_ factor: CGFloat) {
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            
            // Get the device camera
            guard let device = self.videoDeviceInput?.device else { return }
            
            do {
                // Lock the device configuration changes
                try device.lockForConfiguration()
                
                // Allow the zoom factor to go up to 5x
                let maxZoomFactor = min(device.activeFormat.videoMaxZoomFactor, 5.0)
                let newScaleFactor = min(max(factor, 1.0), maxZoomFactor)
                
                // Apply the new zoom factor
                device.videoZoomFactor = newScaleFactor
                
                device.unlockForConfiguration()
            } catch {
                print("Error locking configuration for zoom: \(error)")
            }
        }
    }
    // Capture a single photo and return it as a UIImage
    func capturePhoto() async throws -> UIImage {
        guard isAuthorized else { throw CameraError.unauthorized }

        return try await withCheckedThrowingContinuation { continuation in
            let settings = AVCapturePhotoSettings()
            // Ask for high-resolution
            settings.isHighResolutionPhotoEnabled = true
            // Create a delegate that handles completion
            let delegate = PhotoCaptureDelegate { result in
                switch result {
                case .success(let image):
                    continuation.resume(returning: image)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            // Retain the delegate until capture completes.
            objc_setAssociatedObject(photoOutput, Unmanaged.passUnretained(delegate).toOpaque(), delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            // Kick off the capture
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}
// Delegate class responsible for handling photo capture callbacks
private final class PhotoCaptureDelegate: NSObject,AVCapturePhotoCaptureDelegate {
    // Completion that passes the result
    private let completion: (Result<UIImage, Error>) -> Void

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }
    // Called wen the photo has been processed into AVCapturePhoto
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            completion(.failure(error))
            return
        }
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            completion(.failure(NSError(domain: "CameraController", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image from photo data"])))
            return
        }
        // Successfully decoded image, return it
        completion(.success(image))
    }
    // Called after capture for this photo is completely finished
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // Release retention
        objc_removeAssociatedObjects(output)
    }
}
