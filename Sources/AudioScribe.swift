import ArgumentParser
import Foundation

@main
struct AudioScribe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Record system audio and microphone to a WAV file",
        version: "1.0.0"
    )

    @Option(name: .shortAndLong, help: "Recording duration in seconds")
    var duration: Int = 60

    @Option(name: .shortAndLong, help: "Output file path")
    var output: String = "recording.wav"

    @Flag(name: .long, help: "Record microphone only")
    var micOnly: Bool = false

    @Flag(name: .long, help: "Record system audio only")
    var systemOnly: Bool = false

    func run() async throws {
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL

        print("AudioScribe - Recording for \(duration) seconds")
        print("Output: \(outputURL.path)")

        let sampleRate: UInt32 = 48000
        let channels: UInt16 = 2

        let writer = try WAVWriter(outputPath: outputURL, sampleRate: sampleRate, channels: channels)

        let systemCapture = SystemAudioCapture(sampleRate: Double(sampleRate), channels: Int(channels))
        let micCapture = MicrophoneCapture(sampleRate: Double(sampleRate), channels: UInt32(channels))

        let recordBoth = !micOnly && !systemOnly

        if recordBoth {
            let mixer = AudioMixer(writer: writer, channels: Int(channels))

            // Request permissions
            print("Requesting permissions...")

            let micPermission = await micCapture.requestPermission()
            if !micPermission {
                print("Warning: Microphone permission denied, recording system audio only")
            }

            let systemPermission = await systemCapture.requestPermission()
            if !systemPermission {
                print("Warning: Screen recording permission denied, recording microphone only")
            }

            guard micPermission || systemPermission else {
                print("Error: No audio sources available")
                throw ExitCode.failure
            }

            // Set up callbacks
            if systemPermission {
                systemCapture.onSamples = { buffer in
                    mixer.addSystemAudio(buffer)
                }
            }

            if micPermission {
                micCapture.onSamples = { buffer in
                    mixer.addMicAudio(buffer)
                }
            }

            // Start capture
            print("Starting recording...")

            if systemPermission {
                try await systemCapture.start()
            }

            if micPermission {
                try micCapture.start()
            }

            // Wait for duration
            try await Task.sleep(for: .seconds(duration))

            // Stop capture
            print("Stopping recording...")

            micCapture.stop()
            await systemCapture.stop()

            mixer.flush()

        } else if micOnly {
            print("Recording microphone only...")

            let permission = await micCapture.requestPermission()
            guard permission else {
                print("Error: Microphone permission denied")
                throw ExitCode.failure
            }

            let mixer = AudioMixer(writer: writer, channels: Int(channels))
            micCapture.onSamples = { buffer in
                mixer.addAudioDirect(buffer)
            }

            try micCapture.start()
            try await Task.sleep(for: .seconds(duration))
            micCapture.stop()
            mixer.flush()

        } else if systemOnly {
            print("Recording system audio only...")

            let permission = await systemCapture.requestPermission()
            guard permission else {
                print("Error: Screen recording permission denied")
                throw ExitCode.failure
            }

            let mixer = AudioMixer(writer: writer, channels: Int(channels))
            systemCapture.onSamples = { buffer in
                mixer.addAudioDirect(buffer)
            }

            try await systemCapture.start()
            try await Task.sleep(for: .seconds(duration))
            await systemCapture.stop()
            mixer.flush()
        }

        try writer.finalize()
        print("Recording saved to: \(outputURL.path)")
    }
}
