import AVFoundation
import ScreenCaptureKit
import CoreGraphics

// MARK: - Permission Manager
// This class tracks and requests macOS permissions for microphone and screen recording.
// It uses @Observable so SwiftUI views automatically update when permission states change.
//
// macOS requires explicit user consent for sensitive capabilities.
// The app must declare why it needs these in Info.plist (NSMicrophoneUsageDescription, etc.).

@Observable
final class PermissionManager {

    // MARK: - Permission State Enum
    // Enums in Swift are powerful - they can have associated values, methods, and conform to protocols.
    // Equatable lets us compare states with == operator.

    enum PermissionState: Equatable {
        case unknown        // Haven't checked yet
        case notDetermined  // User hasn't been asked yet
        case authorized     // User granted permission
        case denied         // User denied or it's restricted by parental controls
    }

    // MARK: - Current Permission States
    // private(set) means external code can read but not write these properties.

    private(set) var microphonePermission: PermissionState = .unknown
    private(set) var screenRecordingPermission: PermissionState = .unknown

    // MARK: - Initialization

    init() {
        // Check permissions when the manager is created.
        // Task creates an async context since init can't be async.
        Task { @MainActor in
            await refreshPermissions()
        }
    }

    // MARK: - Refresh Permissions
    // @MainActor ensures this runs on the main thread (required for UI updates).
    // 'async' means this function can be suspended and resumed (non-blocking).

    @MainActor
    func refreshPermissions() async {
        // MARK: Check Microphone Permission
        // AVCaptureDevice.authorizationStatus returns the current state without prompting.
        let micStatus = AVCaptureDevice.authorizationStatus(for: .audio)

        // Swift's switch must be exhaustive - handle all cases.
        // @unknown default handles future enum cases Apple might add.
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

        // MARK: Check Screen Recording Permission
        // CGPreflightScreenCaptureAccess checks if we have screen recording permission.
        // Unlike microphone, there's no "notDetermined" state - it's either granted or not.
        if CGPreflightScreenCaptureAccess() {
            screenRecordingPermission = .authorized
        } else {
            // Double-check with ScreenCaptureKit - sometimes CGPreflight is wrong.
            do {
                // This call will fail if we don't have permission.
                _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                screenRecordingPermission = .authorized
            } catch {
                screenRecordingPermission = .denied
            }
        }
    }

    // MARK: - Request Microphone Permission
    // Returns true if permission was granted.

    @MainActor
    func requestMicrophonePermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)

        switch status {
        case .authorized:
            microphonePermission = .authorized
            return true

        case .notDetermined:
            // This triggers the system permission dialog.
            // The function suspends until the user responds.
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

    // MARK: - Request Screen Recording Permission
    // Screen recording permission can't be requested programmatically like microphone.
    // We can only check status and direct users to System Settings.

    @MainActor
    func requestScreenRecordingPermission() async -> Bool {
        // Try to trigger the permission prompt via CoreGraphics.
        // This shows a dialog asking the user to grant access.
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        // Verify with ScreenCaptureKit.
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            screenRecordingPermission = .authorized
            return true
        } catch {
            screenRecordingPermission = .denied
            return false
        }
    }

    // MARK: - Open System Settings
    // Opens the Privacy & Security pane in System Settings so users can grant permissions.
    // Uses the x-apple.systempreferences URL scheme.

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

        // URL(string:) returns optional because the string might be invalid.
        // 'if let' safely unwraps the optional.
        if let url = URL(string: urlString) {
            // NSWorkspace.shared is the singleton for interacting with the desktop.
            NSWorkspace.shared.open(url)
        }
    }
}
