import Foundation
import Testing

@testable import SupacodeMCPLib

// MARK: - Test Helpers

/// Creates a Unix socketpair and returns (clientFD, testFD).
/// The client reads from clientFD; tests write events to testFD.
private func makeSocketPair() -> (clientFD: Int32, testFD: Int32) {
  var fds: [Int32] = [0, 0]
  let result = socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
  precondition(result == 0, "socketpair failed")
  return (clientFD: fds[0], testFD: fds[1])
}

/// Write a JSON-encoded MCPSocketMessage to a file descriptor.
private func writeMessage(
  _ message: MCPSocketMessage, to socketFD: Int32
) throws {
  var data = try JSONEncoder().encode(message)
  data.append(UInt8(ascii: "\n"))
  data.withUnsafeBytes { bytes in
    _ = write(socketFD, bytes.baseAddress!, bytes.count)
  }
}

private func writeEvent(
  _ event: MCPSocketEvent, to socketFD: Int32
) throws {
  try writeMessage(.event(event), to: socketFD)
}

private func writeResponse(
  id: Int, _ response: MCPSocketResponse, to socketFD: Int32
) throws {
  try writeMessage(.response(id: id, response), to: socketFD)
}

// MARK: - Tests

struct SocketClientCompletionTests {

  @Test func prepareCompletionCreatesCorrectKey() {
    let client = SocketClient(socketPath: "/unused")
    let key = client.prepareCompletion(worktreeID: "/path/to/worktree", surfaceID: "abc-123")
    #expect(key == "/path/to/worktree|abc-123")
  }

  @Test func prepareCompletionDecodesPercentEncoding() {
    let client = SocketClient(socketPath: "/unused")
    let key = client.prepareCompletion(worktreeID: "/path/to/my%20project", surfaceID: "surf-1")
    #expect(key == "/path/to/my project|surf-1")
  }

  @Test func completionResolvesOnIdleAndNotification() async throws {
    let (clientFD, testFD) = makeSocketPair()
    defer { close(clientFD); close(testFD) }

    let client = SocketClient(socketPath: "/unused")
    Task.detached { client.readLoop(fd: clientFD) }

    let key = client.prepareCompletion(
      worktreeID: "/wt", surfaceID: "s1"
    )

    // Send notification then busy=false
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s1",
        agent: "claude", event: "Stop",
        title: nil, body: "hello world"
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s1", active: false
      ),
      to: testFD
    )

    let result = await client.waitForCompletion(canonical: key)
    #expect(result.messages == ["hello world"])
    #expect(result.surfaceID == "s1")

    close(testFD)
  }

  @Test func completionResolvesWithNilBody() async throws {
    let (clientFD, testFD) = makeSocketPair()
    defer { close(clientFD); close(testFD) }

    let client = SocketClient(socketPath: "/unused")
    Task.detached { client.readLoop(fd: clientFD) }

    let key = client.prepareCompletion(
      worktreeID: "/wt", surfaceID: "s1"
    )

    // Notification with no body — should still resolve (hasNotification = true)
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s1",
        agent: "claude", event: "Stop",
        title: nil, body: nil
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s1", active: false
      ),
      to: testFD
    )

    let result = await client.waitForCompletion(canonical: key)
    #expect(result.messages.isEmpty)
    #expect(result.surfaceID == "s1")

    close(testFD)
  }

  @Test func eventsFromWrongSurfaceAreIgnored() async throws {
    let (clientFD, testFD) = makeSocketPair()
    defer { close(clientFD); close(testFD) }

    let client = SocketClient(socketPath: "/unused")
    Task.detached { client.readLoop(fd: clientFD) }

    let key = client.prepareCompletion(
      worktreeID: "/wt", surfaceID: "s1"
    )

    // Events for a different surface — should not match
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s2",
        agent: "claude", event: "Stop",
        title: nil, body: "wrong"
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s2", active: false
      ),
      to: testFD
    )

    // Now send correct events
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s1",
        agent: "claude", event: "Stop",
        title: nil, body: "correct"
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s1", active: false
      ),
      to: testFD
    )

    let result = await client.waitForCompletion(canonical: key)
    #expect(result.messages == ["correct"])

    close(testFD)
  }

  @Test func concurrentSurfacesInSameWorktreeAreIsolated() async throws {
    let (clientFD, testFD) = makeSocketPair()
    defer { close(clientFD); close(testFD) }

    let client = SocketClient(socketPath: "/unused")
    Task.detached { client.readLoop(fd: clientFD) }

    let key1 = client.prepareCompletion(
      worktreeID: "/wt", surfaceID: "s1"
    )
    let key2 = client.prepareCompletion(
      worktreeID: "/wt", surfaceID: "s2"
    )

    // Complete s2 first
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s2",
        agent: "claude", event: "Stop",
        title: nil, body: "from s2"
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s2", active: false
      ),
      to: testFD
    )

    let result2 = await client.waitForCompletion(canonical: key2)
    #expect(result2.messages == ["from s2"])

    // Then complete s1
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s1",
        agent: "claude", event: "Stop",
        title: nil, body: "from s1"
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s1", active: false
      ),
      to: testFD
    )

    let result1 = await client.waitForCompletion(canonical: key1)
    #expect(result1.messages == ["from s1"])

    close(testFD)
  }

  @Test func cancelCompletionCleansUp() {
    let client = SocketClient(socketPath: "/unused")
    let key = client.prepareCompletion(worktreeID: "/wt", surfaceID: "s1")
    client.cancelCompletion(canonical: key)

    // Prepare same key again — should work without issues (no stale state)
    let key2 = client.prepareCompletion(worktreeID: "/wt", surfaceID: "s1")
    #expect(key == key2)
    client.cancelCompletion(canonical: key2)
  }

  @Test func multipleNotificationsAccumulate() async throws {
    let (clientFD, testFD) = makeSocketPair()
    defer { close(clientFD); close(testFD) }

    let client = SocketClient(socketPath: "/unused")
    Task.detached { client.readLoop(fd: clientFD) }

    let key = client.prepareCompletion(
      worktreeID: "/wt", surfaceID: "s1"
    )

    // Multiple notifications before idle
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s1",
        agent: "claude", event: "Notification",
        title: nil, body: "first"
      ),
      to: testFD
    )
    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s1",
        agent: "claude", event: "Stop",
        title: nil, body: "second"
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s1", active: false
      ),
      to: testFD
    )

    let result = await client.waitForCompletion(canonical: key)
    #expect(result.messages == ["first", "second"])

    close(testFD)
  }

  @Test func emptyBodyNotAppendedToMessages() async throws {
    let (clientFD, testFD) = makeSocketPair()
    defer { close(clientFD); close(testFD) }

    let client = SocketClient(socketPath: "/unused")
    Task.detached { client.readLoop(fd: clientFD) }

    let key = client.prepareCompletion(
      worktreeID: "/wt", surfaceID: "s1"
    )

    try writeEvent(
      .agentNotification(
        worktreeID: "/wt", surfaceID: "s1",
        agent: "claude", event: "Stop",
        title: nil, body: ""
      ),
      to: testFD
    )
    try writeEvent(
      .agentBusyChanged(
        worktreeID: "/wt", surfaceID: "s1", active: false
      ),
      to: testFD
    )

    let result = await client.waitForCompletion(canonical: key)
    #expect(result.messages.isEmpty)

    close(testFD)
  }
}
