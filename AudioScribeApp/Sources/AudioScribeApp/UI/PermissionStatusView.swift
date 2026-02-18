import SwiftUI

/// Shows permission status indicators
struct PermissionStatusView: View {
    @Bindable var permissionManager: PermissionManager

    var body: some View {
        HStack(spacing: 12) {
            PermissionIndicator(
                label: "Microphone",
                state: permissionManager.microphonePermission,
                onRequest: {
                    Task {
                        await permissionManager.requestMicrophonePermission()
                    }
                },
                onOpenSettings: {
                    permissionManager.openSystemSettings(for: "microphone")
                }
            )

            PermissionIndicator(
                label: "Screen Recording",
                state: permissionManager.screenRecordingPermission,
                onRequest: {
                    Task {
                        await permissionManager.requestScreenRecordingPermission()
                    }
                },
                onOpenSettings: {
                    permissionManager.openSystemSettings(for: "screenRecording")
                }
            )
        }
    }
}

struct PermissionIndicator: View {
    let label: String
    let state: PermissionManager.PermissionState
    let onRequest: () -> Void
    let onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Circle()
                    .fill(stateColor)
                    .frame(width: 8, height: 8)

                Text(label)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            if state == .notDetermined {
                Button("Grant") {
                    onRequest()
                }
                .buttonStyle(.link)
                .font(.caption2)
            } else if state == .denied {
                Button("Settings") {
                    onOpenSettings()
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
        }
    }

    private var stateColor: Color {
        switch state {
        case .authorized:
            return .green
        case .denied:
            return .red
        case .notDetermined:
            return .yellow
        case .unknown:
            return .gray
        }
    }
}
