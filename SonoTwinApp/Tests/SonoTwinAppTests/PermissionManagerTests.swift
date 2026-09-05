import Foundation
import Testing
@testable import SonoTwinApp

@Suite
struct PermissionManagerTests {
    @Test @MainActor
    func acceptsCaptureAccessWhenCoreGraphicsPreflightIsStale() async {
        let manager = PermissionManager(
            screenRecordingProbe: .init(
                preflight: { false },
                request: { false },
                verifyCaptureAccess: {}
            )
        )

        await manager.refreshPermissions()

        #expect(manager.screenRecordingPermission == .authorized)
        #expect(manager.screenRecordingDiagnostic == nil)
    }

    @Test @MainActor
    func recheckObservesPermissionGrantedAfterSettingsChange() async {
        let access = PermissionAccessBox(false)
        let manager = PermissionManager(
            screenRecordingProbe: .init(
                preflight: { access.value },
                request: { false },
                verifyCaptureAccess: {
                    guard access.value else { throw PermissionTestError.denied }
                }
            )
        )

        await manager.refreshPermissions()
        #expect(manager.screenRecordingPermission == .denied)
        #expect(manager.screenRecordingDiagnostic == "capture denied")

        access.value = true
        await manager.refreshPermissions()

        #expect(manager.screenRecordingPermission == .authorized)
        #expect(manager.screenRecordingDiagnostic == nil)
    }
}

private enum PermissionTestError: Error, LocalizedError {
    case denied

    var errorDescription: String? { "capture denied" }
}

private final class PermissionAccessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        storedValue = value
    }

    var value: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
