import Foundation

// MARK: - SocketServer
// A Unix domain socket server that allows external control via CLI.
// The ascribe-ctl script connects to this socket to start/stop recording.
//
// Unix sockets are like network sockets but for local communication only.
// They appear as files (e.g., /tmp/audioscribe.sock) and are faster than TCP.
//
// @unchecked Sendable: We manually ensure thread safety. The accept loop
// runs on a background thread while the main app runs on the main thread.

final class SocketServer: @unchecked Sendable {

    // MARK: - Properties

    /// Path where the socket file will be created.
    /// /tmp is a standard location for temporary files on Unix systems.
    private let socketPath = "/tmp/audioscribe.sock"

    /// File descriptor for the server socket.
    /// -1 indicates the socket isn't open yet.
    private var serverSocket: Int32 = -1

    /// Flag to control the accept loop.
    private var isRunning = false

    /// Reference to the recording state for handling commands.
    private let recordingState: RecordingState

    /// Background thread running the accept loop.
    private var acceptThread: Thread?

    // MARK: - Initialization

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
    }

    // MARK: - Server Control

    /// Start the socket server and begin accepting connections.
    func start() {
        // Remove any leftover socket file from a previous crash.
        // unlink() deletes a file by path (POSIX function).
        unlink(socketPath)

        // MARK: Create Socket
        // socket() creates a communication endpoint.
        // AF_UNIX = Unix domain (local), SOCK_STREAM = reliable byte stream (like TCP).
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("SocketServer: Failed to create socket")
            return
        }

        // MARK: Bind to Path
        // sockaddr_un is the address structure for Unix sockets.
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)  // Set address family

        // Copy the socket path into the address structure.
        // This is tricky because sun_path is a fixed-size C array.
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { path in
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), path, pathSize - 1)
            }
        }

        // bind() associates the socket with the address (path).
        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            // strerror() converts error number to human-readable string.
            print("SocketServer: Failed to bind socket: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        // MARK: Listen for Connections
        // listen() marks the socket as passive (accepting connections).
        // 5 is the backlog - max queued connections waiting to be accepted.
        guard listen(serverSocket, 5) == 0 else {
            print("SocketServer: Failed to listen: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        isRunning = true
        print("SocketServer: Listening on \(socketPath)")

        // MARK: Start Accept Thread
        // Run the accept loop on a background thread so it doesn't block the main thread.
        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.start()
    }

    /// Stop the server and clean up resources.
    func stop() {
        isRunning = false

        // Close the socket (this also makes accept() return with an error).
        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        // Remove the socket file.
        unlink(socketPath)
    }

    // MARK: - Accept Loop

    /// Runs on a background thread, accepting client connections.
    private func acceptLoop() {
        while isRunning && serverSocket >= 0 {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            // accept() blocks until a client connects.
            // It returns a new socket for that specific client.
            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            // accept() returns -1 on error (e.g., server socket was closed).
            guard clientSocket >= 0 else {
                if isRunning {
                    // Unexpected error - wait a bit before retrying.
                    Thread.sleep(forTimeInterval: 0.1)
                }
                continue
            }

            // Handle the client connection asynchronously.
            Task {
                await self.handleClient(clientSocket)
            }
        }
    }

    // MARK: - Client Handler

    /// Handle a single client connection - read command, process, send response.
    private func handleClient(_ clientSocket: Int32) async {
        // defer ensures close() is called even if we return early.
        defer {
            close(clientSocket)
        }

        // MARK: Read Command
        // Read up to 4KB from the client.
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)

        guard bytesRead > 0 else { return }

        // Convert bytes to Data for JSON parsing.
        let data = Data(buffer[0..<bytesRead])

        // MARK: Process Command
        // Create handler on MainActor since RecordingState is @MainActor.
        let handler = await MainActor.run {
            CommandHandler(recordingState: recordingState)
        }

        let response = await handler.handle(data)

        // MARK: Send Response
        // Write the JSON response back to the client.
        response.withUnsafeBytes { ptr in
            _ = write(clientSocket, ptr.baseAddress, response.count)
        }
    }
}
