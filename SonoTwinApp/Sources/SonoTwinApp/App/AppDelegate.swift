import AppKit
import SwiftUI

// MARK: - AppDelegate
// The AppDelegate is a design pattern from Apple frameworks.
// It receives notifications about app lifecycle events (launch, terminate, etc.).
// We inherit from NSObject (required for Objective-C interop) and adopt
// NSApplicationDelegate (the protocol defining lifecycle methods).

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {

    // MARK: - Properties

    // NSStatusItem represents the icon in the menu bar.
    // It's optional (?) because it's created after app launch.
    private var statusItem: NSStatusItem?

    // NSPopover is the floating panel that appears when clicking the menu bar icon.
    // Think of it like a speech bubble attached to the menu bar.
    private var popover: NSPopover?

    // Our custom state and engine objects.
    // These are optional because they're initialized in applicationDidFinishLaunching.
    private var recordingState: RecordingState?
    private var recordingEngine: RecordingEngine?
    private var socketServer: SocketServer?

    // MARK: - NSApplicationDelegate Methods

    // This method is called once the app has finished launching.
    // It's the ideal place to set up your UI and services.
    func applicationDidFinishLaunching(_ notification: Notification) {

        // MARK: Create Status Item (Menu Bar Icon)
        // NSStatusBar.system is the system's menu bar.
        // .squareLength creates an icon-sized item (as opposed to variable width).
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        // Configure the button that appears in the menu bar.
        // SF Symbols (like "waveform") are Apple's built-in icon library.
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "SonoTwin")
            // #selector references an @objc method by name (Objective-C interop).
            button.action = #selector(togglePopover)
            // 'target = self' means this object receives the action when clicked.
            button.target = self
        }

        // MARK: Initialize State and Engine
        // RecordingState holds all observable UI state.
        // RecordingEngine handles the actual audio capture.
        let state = RecordingState()
        let engine = RecordingEngine()
        let transcriptionRuntime = TranscriptionRuntime { [weak state] snapshot in
            Task { @MainActor in
                state?.updateTranscriptionStatus(snapshot)
            }
        }

        self.recordingState = state
        self.recordingEngine = engine
        state.setRecordingEngine(engine)
        state.setTranscriptionRuntime(transcriptionRuntime)

        Task {
            do {
                let result = try await WhisperServerOwnershipRegistry.shared.reclaimOrphanedServer()
                if case .terminated(let processIdentifier) = result {
                    print("WhisperServerSupervisor: Reclaimed orphaned process \(processIdentifier)")
                }
            } catch {
                print("WhisperServerSupervisor: Orphan cleanup failed: \(error.localizedDescription)")
            }
            await state.recoverTranscriptionSession()
        }

        // MARK: Connect Engine to State
        // Task creates an asynchronous context for async/await code.
        // @MainActor ensures this runs on the main thread (required for UI).
        Task { @MainActor in
            // Set up a callback to receive audio level updates.
            // [weak state] prevents a retain cycle (memory leak).
            // The callback receives 4 floats: system RMS, system peak, mic RMS, mic peak.
            // 'await' is required because RecordingEngine is an actor.
            await engine.setLevelUpdateCallback { [weak state] sysRMS, sysPeak, micRMS, micPeak in
                Task { @MainActor in
                    state?.updateLevels(systemRMS: sysRMS, systemPeak: sysPeak, micRMS: micRMS, micPeak: micPeak)
                }
            }
        }

        // MARK: Create Popover
        // The popover displays our SwiftUI UI when the menu bar icon is clicked.
        let popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 620)
        // .transient means clicking outside closes the popover automatically.
        popover.behavior = .transient
        popover.delegate = self

        // NSHostingController bridges SwiftUI views into AppKit.
        // This lets us use SwiftUI for our UI while using AppKit for the menu bar.
        popover.contentViewController = NSHostingController(rootView: PopoverContentView(state: state))
        self.popover = popover

        // MARK: Start Socket Server
        // The socket server allows external control via the sonotwin-ctl script.
        socketServer = SocketServer(recordingState: state)
        socketServer?.start()

        refreshPermissions()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        refreshPermissions()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = recordingState else { return .terminateNow }

        Task { @MainActor in
            if state.isRecording {
                await state.stopRecording()
            }
            await state.shutdownTranscription()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        socketServer?.stop()
    }

    // MARK: - Actions

    // @objc exposes this method to the Objective-C runtime.
    // This is required because NSButton's action/target mechanism uses Objective-C.
    @objc private func togglePopover() {
        guard let button = statusItem?.button, let popover = popover else { return }

        if popover.isShown {
            popover.performClose(nil)
        } else {
            refreshPermissions()
            // Show the popover attached to the menu bar button.
            // .minY means it appears below the button.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Bring our app to the front so the popover can receive keyboard focus.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func refreshPermissions() {
        guard let state = recordingState else { return }
        Task { @MainActor in
            await state.permissionManager.refreshPermissions()
        }
    }

    // MARK: - NSPopoverDelegate

    // This delegate method controls whether the popover can be "torn off"
    // into a separate window. We return false to keep it attached.
    func popoverShouldDetach(_ popover: NSPopover) -> Bool {
        return false
    }
}
