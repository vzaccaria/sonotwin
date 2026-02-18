import AVFoundation
import ScreenCaptureKit
import CoreGraphics

/// Manages permission status and requests for microphone and screen recording
@Observable
final class PermissionManager {
    enum PermissionState: Equatable {
        case unknown
        case notDetermined
        case authorized
        case denied
    }

    private(set) var microphonePermission: PermissionState = .unknown
    private(set) var screenRecordingPermission: PermissionState = .unknown

    init() {
        Task { @MainActor in
            await refreshPermissions()
        }
    }

    /// Refresh current permission status
    @MainActor
    func refreshPermissions() async {
        // Check microphone permission
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        switch micStatus {
        case .authorized:
            microphonePermission = .authorized
        case .denied, .restricted:
            microphonePermission = .denied
        case .notDetermined:
            microphonePermission = .notDetermined
        @unknown default:
            microphonePermission = .unknown
        }

        // Check screen recording permission
        if CGPreflightScreenCaptureAccess() {
            screenRecordingPermission = .authorized
        } else {
            // Try to verify with ScreenCaptureKit
            do {
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                screenRecordingPermission = .authorized
            } catch {
                screenRecordingPermission = .denied
            }
        }
    }

    /// Request microphone permission
    @MainActor
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            microphonePermission = .authorized
            return true
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            microphonePermission = granted ? .authorized : .denied
            return granted
        case .denied, .restricted:
            microphonePermission = .denied
            return false
        @unknown default:
            return false
        }
    }

    /// Request screen recording permission (opens System Settings)
    @MainActor
    func requestScreenRecordingPermission() async -> Bool {
        // First try to request via CoreGraphics
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        // Verify with ScreenCaptureKit
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenRecordingPermission = .authorized
            return true
        } catch {
            screenRecordingPermission = .denied
            return false
        }
    }

    /// Open System Settings to the appropriate privacy pane
    func openSystemSettings(for permission: String) {
        let urlString: String
        switch permission {
        case "microphone":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        case "screenRecording":
            urlString = "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        default:
            urlString = "x-apple.systempreferences:com.apple.preference.security"
        }

        if let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
    }
}
