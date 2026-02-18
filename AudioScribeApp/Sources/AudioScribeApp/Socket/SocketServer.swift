import Foundation

/// Unix socket server for CLI control
final class SocketServer: @unchecked Sendable {
    private let socketPath = "/tmp/audioscribe.sock"
    private var serverSocket: Int32 = -1
    private var isRunning = false
    private let recordingState: RecordingState
    private var acceptThread: Thread?

    init(recordingState: RecordingState) {
        self.recordingState = recordingState
    }

    func start() {
        // Remove existing socket file
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            print("SocketServer: Failed to create socket")
            return
        }

        // Bind to path
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        // Copy socket path to sun_path
        let pathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = socketPath.withCString { path in
            withUnsafeMutableBytes(of: &addr.sun_path) { ptr in
                strncpy(ptr.baseAddress!.assumingMemoryBound(to: CChar.self), path, pathSize - 1)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            print("SocketServer: Failed to bind socket: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        // Listen
        guard listen(serverSocket, 5) == 0 else {
            print("SocketServer: Failed to listen: \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        isRunning = true
        print("SocketServer: Listening on \(socketPath)")

        // Start accept thread
        acceptThread = Thread { [weak self] in
            self?.acceptLoop()
        }
        acceptThread?.start()
    }

    func stop() {
        isRunning = false

        if serverSocket >= 0 {
            close(serverSocket)
            serverSocket = -1
        }

        unlink(socketPath)
    }

    private func acceptLoop() {
        while isRunning && serverSocket >= 0 {
            var clientAddr = sockaddr_un()
            var addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

            let clientSocket = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    accept(serverSocket, sockaddrPtr, &addrLen)
                }
            }

            guard clientSocket >= 0 else {
                if isRunning {
                    // Accept error, but we're still running
                    Thread.sleep(forTimeInterval: 0.1)
                }
                continue
            }

            // Handle client in a separate task
            Task {
                await self.handleClient(clientSocket)
            }
        }
    }

    private func handleClient(_ clientSocket: Int32) async {
        defer {
            close(clientSocket)
        }

        // Read data
        var buffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientSocket, &buffer, buffer.count)

        guard bytesRead > 0 else { return }

        let data = Data(buffer[0..<bytesRead])

        // Process command
        let handler = await MainActor.run {
            CommandHandler(recordingState: recordingState)
        }

        let response = await handler.handle(data)

        // Send response
        response.withUnsafeBytes { ptr in
            _ = write(clientSocket, ptr.baseAddress, response.count)
        }
    }
}
