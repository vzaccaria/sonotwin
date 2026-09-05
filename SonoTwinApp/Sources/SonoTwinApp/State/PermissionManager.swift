import AppKit
import AVFoundation
import CoreGraphics
import ScreenCaptureKit

struct ScreenRecordingPermissionProbe: Sendable {
    let preflight: @Sendable () -> Bool
    let request: @Sendable () -> Bool
    let verifyCaptureAccess: @Sendable () async throws -> Void

    static let live = ScreenRecordingPermissionProbe(
        preflight: { CGPreflightScreenCaptureAccess() },
        request: { CGRequestScreenCaptureAccess() },
        verifyCaptureAccess: {
            _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        }
    )
}

@Observable
@MainActor
final class PermissionManager {
    enum PermissionState: Equatable {
        case unknown
        case notDetermined
        case authorized
        case denied
    }

    private(set) var microphonePermission: PermissionState = .unknown
    private(set) var screenRecordingPermission: PermissionState = .unknown
    private(set) var screenRecordingDiagnostic: String?
    private(set) var isRefreshingScreenRecording = false

    private let screenRecordingProbe: ScreenRecordingPermissionProbe

    init(screenRecordingProbe: ScreenRecordingPermissionProbe = .live) {
        self.screenRecordingProbe = screenRecordingProbe
        Task { @MainActor [weak self] in
            await self?.refreshPermissions()
        }
    }

    func refreshPermissions() async {
        refreshMicrophonePermission()
        guard !isRefreshingScreenRecording else { return }

        isRefreshingScreenRecording = true
        defer { isRefreshingScreenRecording = false }
        await refreshScreenRecordingPermission()
    }

    func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
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
            microphonePermission = .unknown
            return false
        }
    }

    func requestScreenRecordingPermission() async -> Bool {
        if !screenRecordingProbe.preflight() {
            _ = screenRecordingProbe.request()
        }
        await refreshScreenRecordingPermission()
        return screenRecordingPermission == .authorized
    }

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

    private func refreshMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            microphonePermission = .authorized
        case .denied, .restricted:
            microphonePermission = .denied
        case .notDetermined:
            microphonePermission = .notDetermined
        @unknown default:
            microphonePermission = .unknown
        }
    }

    private func refreshScreenRecordingPermission() async {
        if screenRecordingProbe.preflight() {
            screenRecordingPermission = .authorized
            screenRecordingDiagnostic = nil
            return
        }

        do {
            try await screenRecordingProbe.verifyCaptureAccess()
            screenRecordingPermission = .authorized
            screenRecordingDiagnostic = nil
        } catch {
            screenRecordingPermission = .denied
            screenRecordingDiagnostic = error.localizedDescription
        }
    }
}
