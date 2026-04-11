import Foundation
import Synchronization

/// Persistent POSIX Unix domain socket client.
/// Connects to Supacode's MCP socket, sends requests, receives responses and events.
/// Reconnects with exponential backoff if the connection drops.
package final class SocketClient: Sendable {
  /// Delay before resolving a completion to handle idle→busy→idle cycles during tool use.
  private static let completionDebounce: Duration = .milliseconds(500)
  private let socketPath: String
  private let nextID = Mutex(0)
  private let pendingRequests = Mutex<
    [Int: CheckedContinuation<MCPSocketResponse, any Error>]
  >([:])
  package struct NotificationResult: Sendable {
    package let surfaceID: String?
    package let messages: [String]
  }
  package struct PendingCompletion: Sendable {
    var surfaceID: String?
    var messages: [String]
    var hasNotification: Bool
    var isIdle: Bool
    var lastEventTime: ContinuousClock.Instant
  }
  private let completionWaiters = Mutex<
    [String: [CheckedContinuation<NotificationResult, Never>]]
  >([:])
  private let pendingMessages = Mutex<[String: PendingCompletion]>([:])
  private let eventContinuation: AsyncStream<MCPSocketEvent>.Continuation
  package let eventStream: AsyncStream<MCPSocketEvent>

  package init(socketPath: String) {
    self.socketPath = socketPath
    let (stream, continuation) = AsyncStream.makeStream(of: MCPSocketEvent.self)
    self.eventStream = stream
    self.eventContinuation = continuation
  }

  /// Connect and start the background read loop. Returns when connected.
  package func connect() throws -> Int32 {
    let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
    guard socketFD >= 0 else {
      throw SocketError.connectionFailed("Failed to create socket")
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = socketPath.utf8CString
    guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
      close(socketFD)
      throw SocketError.connectionFailed("Socket path too long")
    }
    _ = withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
      pathBytes.withUnsafeBufferPointer { buffer in
        memcpy(sunPath, buffer.baseAddress!, buffer.count)
      }
    }
    let addrLen = socklen_t(
      MemoryLayout<sa_family_t>.size + pathBytes.count
    )
    let result = withUnsafePointer(to: &addr) { ptr in
      ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
        Foundation.connect(socketFD, sockaddrPtr, addrLen)
      }
    }
    guard result == 0 else {
      close(socketFD)
      throw SocketError.connectionFailed(
        "Cannot connect to Supacode (is the app running?)"
      )
    }
    return socketFD
  }

  /// Start the read loop on a connected FD. Call from a detached Task.
  package func readLoop(fd socketFD: Int32) {
    var buffer = Data()
    var readBuf = [UInt8](repeating: 0, count: 8192)

    while true {
      let bytesRead = read(socketFD, &readBuf, readBuf.count)
      if bytesRead <= 0 { break }
      buffer.append(contentsOf: readBuf[0..<bytesRead])

      while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
        let lineData = Data(buffer[buffer.startIndex..<newlineIndex])
        buffer = Data(buffer[buffer.index(after: newlineIndex)...])
        handleMessage(lineData)
      }
    }

    // Connection lost — fail all pending requests
    let pending = pendingRequests.withLock { reqs in
      let copy = reqs
      reqs.removeAll()
      return copy
    }
    for (_, continuation) in pending {
      continuation.resume(throwing: SocketError.disconnected)
    }
    eventContinuation.finish()
  }

  /// Send a request and await the response.
  package func send(fd socketFD: Int32, _ request: MCPSocketRequest) async throws -> MCPSocketResponse {
    let id = nextID.withLock { value in
      let current = value
      value += 1
      return current
    }
    let message = MCPSocketMessage.request(id: id, request)
    var data = try JSONEncoder().encode(message)
    data.append(UInt8(ascii: "\n"))

    return try await withCheckedThrowingContinuation { continuation in
      pendingRequests.withLock { $0[id] = continuation }
      let written = data.withUnsafeBytes { bytes in
        write(socketFD, bytes.baseAddress!, bytes.count)
      }
      if written != data.count {
        let removed = pendingRequests.withLock {
          $0.removeValue(forKey: id)
        }
        removed?.resume(
          throwing: SocketError.connectionFailed(
            "Write failed (\(written)/\(data.count))"
          )
        )
      }
    }
  }

  /// Start tracking completion events. Pass surfaceID to scope tracking per-surface
  /// and avoid cross-matching concurrent agents in the same worktree.
  package func prepareCompletion(worktreeID: String, surfaceID: String) -> String {
    let canonical = worktreeID.removingPercentEncoding ?? worktreeID
    let key = "\(canonical)|\(surfaceID)"
    pendingMessages.withLock {
      $0[key] = PendingCompletion(
        surfaceID: nil,
        messages: [],
        hasNotification: false,
        isIdle: false,
        lastEventTime: .now
      )
    }
    return key
  }

  /// Wait until the agent goes idle, collecting all notification messages along the way.
  /// Times out after 5 minutes of inactivity (resets on each event).
  package func waitForCompletion(canonical: String) async -> NotificationResult {
    return await withTaskGroup(of: NotificationResult.self) { group in
      group.addTask {
        await withCheckedContinuation { continuation in
          self.completionWaiters.withLock { waiters in
            waiters[canonical, default: []].append(continuation)
          }
        }
      }
      group.addTask {
        while true {
          try? await Task.sleep(for: .seconds(30))
          let pending = self.pendingMessages.withLock { $0[canonical] }
          guard let pending else { break }
          let elapsed = ContinuousClock.now - pending.lastEventTime
          if elapsed > .seconds(300) { break }
        }
        // Drain waiters to avoid leaking continuations
        let waiters = self.completionWaiters.withLock {
          $0.removeValue(forKey: canonical) ?? []
        }
        let pending = self.pendingMessages.withLock {
          $0.removeValue(forKey: canonical)
        }
        let result = NotificationResult(
          surfaceID: pending?.surfaceID,
          messages: pending?.messages ?? []
        )
        for waiter in waiters { waiter.resume(returning: result) }
        return result
      }
      let result = await group.next()!
      group.cancelAll()
      return result
    }
  }

  /// Cancel a prepared completion and drain any waiting continuations.
  package func cancelCompletion(canonical: String) {
    pendingMessages.withLock {
      _ = $0.removeValue(forKey: canonical)
    }
    let waiters = completionWaiters.withLock {
      $0.removeValue(forKey: canonical) ?? []
    }
    let empty = NotificationResult(surfaceID: nil, messages: [])
    for waiter in waiters { waiter.resume(returning: empty) }
  }

  // MARK: - Message Handling

  private func handleMessage(_ data: Data) {
    guard let message = try? JSONDecoder().decode(MCPSocketMessage.self, from: data) else {
      mcpLog("Failed to decode socket message")
      return
    }
    switch message {
    case .response(let id, let response):
      let continuation = pendingRequests.withLock { $0.removeValue(forKey: id) }
      continuation?.resume(returning: response)
    case .event(let event):
      mcpLog("Received event: \(event)")
      // Match events to pending completions by exact surfaceID key.
      if case .supagentNotification(
        let worktreeID, let surfaceID, _, _, _, let body
      ) = event {
        let decoded = worktreeID.removingPercentEncoding ?? worktreeID
        let key = "\(decoded)|\(surfaceID)"
        let matched = pendingMessages.withLock { pending in
          guard pending[key] != nil else { return false }
          pending[key]?.surfaceID = surfaceID
          pending[key]?.hasNotification = true
          pending[key]?.lastEventTime = .now
          if let body, !body.isEmpty {
            pending[key]?.messages.append(body)
          }
          return true
        }
        if matched { tryResolveCompletion(canonical: key) }
      }
      if case .supagentBusyChanged(
        let worktreeID, let surfaceID, let active
      ) = event {
        let decoded = worktreeID.removingPercentEncoding ?? worktreeID
        let key = "\(decoded)|\(surfaceID)"
        let matched = pendingMessages.withLock { pending in
          guard pending[key] != nil else { return false }
          pending[key]?.isIdle = !active
          pending[key]?.lastEventTime = .now
          return !active
        }
        if matched { tryResolveCompletion(canonical: key) }
      }
      eventContinuation.yield(event)
    case .request:
      break
    }
  }

  /// Resolve waiters when agent is idle and has fired at least one notification.
  /// Debounces to handle idle→busy→idle cycles during tool use.
  private func tryResolveCompletion(canonical: String) {
    Task {
      try? await Task.sleep(for: Self.completionDebounce)
      let pending = self.pendingMessages.withLock { $0[canonical] }
      guard let pending, pending.isIdle, pending.hasNotification else {
        return
      }
      self.pendingMessages.withLock {
        _ = $0.removeValue(forKey: canonical)
      }
      let result = NotificationResult(
        surfaceID: pending.surfaceID,
        messages: pending.messages
      )
      let waiters = self.completionWaiters.withLock {
        $0.removeValue(forKey: canonical) ?? []
      }
      for waiter in waiters {
        waiter.resume(returning: result)
      }
    }
  }

  enum SocketError: Error, CustomStringConvertible {
    case connectionFailed(String)
    case disconnected

    var description: String {
      switch self {
      case .connectionFailed(let msg): return msg
      case .disconnected: return "Disconnected from Supacode"
      }
    }
  }
}
