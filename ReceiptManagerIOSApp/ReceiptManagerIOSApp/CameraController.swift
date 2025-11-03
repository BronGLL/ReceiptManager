import Foundation
@preconcurrency import AVFoundation
import UIKit
import Combine

@MainActor
final class CameraController: NSObject, ObservableObject {
    enum CameraError: LocalizedError {
        case unauthorized
        case configurationFailed
        case noCameraAvailable
        case sessionInterrupted
        case unknown

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

    @Published var isSessionRunning = false
    @Published var isAuthorized = false
    @Published var lastError: CameraError?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "CameraController.sessionQueue")
    private let photoOutput = AVCapturePhotoOutput()
    private var videoDeviceInput: AVCaptureDeviceInput?
    override init() {
        super.init()
        session.sessionPreset = .photo
    }

    func checkPermissions() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            isAuthorized = true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            isAuthorized = granted
        default:
            isAuthorized = false
            lastError = .unauthorized
        }
    }

    func configureSession() async {
        guard isAuthorized else { return }

        // Capture the session reference on the main actor to avoid isolation warnings
        let session = self.session
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else { continuation.resume(); return }

                session.beginConfiguration()

                // Input
                do {
                    guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) ??
                            AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .unspecified)
                    else {
                        Task { @MainActor in self.lastError = .noCameraAvailable }
                        session.commitConfiguration()
                        continuation.resume()
                        return
                    }
                    let input = try AVCaptureDeviceInput(device: device)
                    if session.canAddInput(input) {
                        session.addInput(input)
                        // Safe to assign captured input back on main actor
                        Task { @MainActor in self.videoDeviceInput = input }
                    } else {
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
                // Output
                if session.canAddOutput(self.photoOutput) {
                    session.addOutput(self.photoOutput)
                    self.photoOutput.isHighResolutionCaptureEnabled = true
                } else {
                    Task { @MainActor in self.lastError = .configurationFailed }
                    session.commitConfiguration()
                    continuation.resume()
                    return
                }
                session.commitConfiguration()
                continuation.resume()
            }
        }
    }

    func startSession() {
        guard isAuthorized else { return }
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if !session.isRunning {
                session.startRunning()
                Task { @MainActor in self.isSessionRunning = true }
            }
        }
    }

    func stopSession() {
        let session = self.session
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning {
                session.stopRunning()
                Task { @MainActor in self.isSessionRunning = false }
            }
        }
    }

    func capturePhoto() async throws -> UIImage {
        guard isAuthorized else { throw CameraError.unauthorized }

        return try await withCheckedThrowingContinuation { continuation in
            let settings = AVCapturePhotoSettings()
            settings.isHighResolutionPhotoEnabled = true

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
            self.photoOutput.capturePhoto(with: settings, delegate: delegate)
        }
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let completion: (Result<UIImage, Error>) -> Void

    init(completion: @escaping (Result<UIImage, Error>) -> Void) {
        self.completion = completion
    }

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
        completion(.success(image))
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        // Release retention
        objc_removeAssociatedObjects(output)
    }
}
