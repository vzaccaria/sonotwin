import AppKit
import SwiftUI

/// App delegate managing NSStatusItem and popover
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var recordingState: RecordingState?
    private var recordingEngine: RecordingEngine?
    private var socketServer: SocketServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "AudioScribe")
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Initialize state and engine
        let state = RecordingState()
        let engine = RecordingEngine()

        self.recordingState = state
        self.recordingEngine = engine

        // Connect engine to state
        Task { @MainActor in
            state.setRecordingEngine(engine)

            // Set up level update callback
            await engine.setLevelUpdateCallback { [weak state] sysRMS, sysPeak, micRMS, micPeak in
                Task { @MainActor in
                    state?.updateLevels(systemRMS: sysRMS, systemPeak: sysPeak, micRMS: micRMS, micPeak: micPeak)
                }
            }
        }

        // Create popover
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 400)
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(state: state))
        self.popover = popover

        // Start socket server
        socketServer = SocketServer(recordingState: state)
        socketServer?.start()

        // Request permissions on first launch
        Task {
            await state.permissionManager.refreshPermissions()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()

        // Stop any ongoing recording
        if let state = recordingState, state.isRecording {
            Task {
                await state.stopRecording()
            }
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Activate app to ensure popover gets focus
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    // NSPopoverDelegate
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        return false
    }
}
