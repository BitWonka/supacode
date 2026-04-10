import Darwin
import Foundation

private nonisolated let mcpLogger = SupaLogger("MCPSocket")

/// Unix domain socket server for MCP orchestrator communication.
/// Accepts one persistent bidirectional connection from the `supacode-mcp` binary.
/// Matches `AgentHookSocketServer` patterns for socket creation and lifecycle.
@MainActor
final class MCPSocketServer {
  private(set) var socketPath: String?
  private var listenTask: Task<Void, Never>?
  private var clients: [Int32: Task<Void, Never>] = [:]

  var getRepositories: (() -> [Repository])?
  var getWorktreeTaskStatus: ((Worktree.ID) -> WorktreeTaskStatus?)?
  var sendTerminalCommand: ((TerminalClient.Command) -> Void)?
  var findWorktree: ((String) -> (repository: Repository, worktree: Worktree)?)?
  var getWorktreeNotifications: ((Worktree.ID) -> [WorktreeTerminalNotification])?
  var getWorktreeTabInfo: ((Worktree.ID) -> [MCPTabInfo])?
  var readWorktreeScreen: ((Worktree.ID, String?, String?) -> String?)?
  /// Create an agent tab synchronously and return (tabID, surfaceID). Returns nil if creation fails.
  var spawnAgentTab: ((Worktree, String, AgentKind) -> (tabID: String, surfaceID: String)?)?
  var sendToWorktreeSurface: ((Worktree.ID, String, String?, String?) -> Bool)?

  func start() {
    let path = SupacodePaths.mcpSocketPath
    let directory = (path as NSString).deletingLastPathComponent

    do {
      try FileManager.default.createDirectory(
        atPath: directory,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700],
      )
    } catch {
      mcpLogger.warning("Failed to create socket directory: \(error)")
      return
    }

    unlink(path)
    guard startListening(path: path) else { return }
    socketPath = path
  }

  func stop() {
    listenTask?.cancel()
    listenTask = nil
    disconnectAllClients()
    if let socketPath {
      unlink(socketPath)
    }
    socketPath = nil
    mcpLogger.info("MCP socket server stopped")
  }

  /// Push a hook event to all connected MCP clients.
  func pushEvent(_ event: MCPSocketEvent) {
    guard !clients.isEmpty else { return }
    mcpLogger.debug("Pushing event to \(clients.count) MCP client(s)")
    broadcastToClients(.event(event))
  }

  // MARK: - Socket Lifecycle

  @discardableResult
  private func startListening(path: String) -> Bool {
    let socketFD = createUnixSocket(path: path)
    guard socketFD >= 0 else { return false }

    listenTask = Task.detached { [weak self] in
      mcpLogger.info("MCP socket listening on \(path)")
      defer { close(socketFD) }

      while !Task.isCancelled {
        var pollFD = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, 200)
        if ready < 0 {
          guard errno == EINTR else {
            mcpLogger.warning("poll() failed: \(String(cString: strerror(errno)))")
            break
          }
          continue
        }
        guard ready > 0 else { continue }

        let clientFD = accept(socketFD, nil, nil)
        guard clientFD >= 0 else { continue }

        await MainActor.run { [weak self] in
          self?.handleNewClient(clientFD)
        }
      }
    }
    return true
  }

  private func handleNewClient(_ fd: Int32) {
    mcpLogger.info("MCP client connected (fd=\(fd), total=\(clients.count + 1))")

    let task = Task.detached { [weak self] in
      defer {
        close(fd)
        Task { @MainActor [weak self] in
          self?.clients.removeValue(forKey: fd)
          mcpLogger.info("MCP client disconnected (fd=\(fd), remaining=\(self?.clients.count ?? 0))")
        }
      }

      var buffer = Data()
      var readBuf = [UInt8](repeating: 0, count: 8192)

      while !Task.isCancelled {
        var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pollFD, 1, 200)
        if ready < 0 {
          guard errno == EINTR else { break }
          continue
        }
        guard ready > 0 else { continue }

        let n = read(fd, &readBuf, readBuf.count)
        if n <= 0 { break }
        buffer.append(contentsOf: readBuf[0..<n])
        if buffer.count > 1_048_576 { break }  // 1 MB guard

        while let newlineIndex = buffer.firstIndex(of: UInt8(ascii: "\n")) {
          let lineData = Data(buffer[buffer.startIndex..<newlineIndex])
          buffer = Data(buffer[buffer.index(after: newlineIndex)...])

          guard let message = try? JSONDecoder().decode(MCPSocketMessage.self, from: lineData) else {
            mcpLogger.warning("Failed to decode MCP message")
            continue
          }

          if case .request(let id, let request) = message {
            let response = await { @MainActor [weak self] () async -> MCPSocketResponse in
              guard let self else { return .error("Server unavailable") }
              return await self.handleRequest(request)
            }()
            await MainActor.run { [weak self] in
              self?.sendToClient(fd, .response(id: id, response))
            }
          }
        }
      }
    }
    clients[fd] = task
  }

  private func disconnectAllClients() {
    for (fd, task) in clients {
      task.cancel()
      // Use shutdown to unblock poll/read — the task's defer handles close(fd)
      shutdown(fd, SHUT_RDWR)
    }
    clients.removeAll()
  }

  // MARK: - Request Handling

  private func handleRequest(_ request: MCPSocketRequest) async -> MCPSocketResponse {
    switch request {
    case .listWorktrees:
      return handleListWorktrees()
    case .getWorktreeStatus(let id):
      return handleGetWorktreeStatus(id)
    case .spawnAgent(let id, let prompt, let agent):
      return handleSpawnAgent(worktreeID: id, prompt: prompt, agent: agent)
    case .sendMessage(let id, let text, _, let tabID, let surfaceID):
      return handleSendMessage(worktreeID: id, text: text, tabID: tabID, surfaceID: surfaceID)
    case .readScreen(let id, let tabID, let surfaceID):
      return handleReadScreen(worktreeID: id, tabID: tabID, surfaceID: surfaceID)
    case .listNotifications(let id):
      return handleListNotifications(worktreeID: id)
    }
  }

  private func handleListWorktrees() -> MCPSocketResponse {
    guard let repos = getRepositories?() else { return .error("Not configured") }
    var infos: [MCPWorktreeInfo] = []
    for repo in repos {
      for worktree in repo.worktrees {
        let running = getWorktreeTaskStatus?(worktree.id) == .running
        let tabs = getWorktreeTabInfo?(worktree.id) ?? []
        infos.append(MCPWorktreeInfo(
          id: worktree.id,
          name: worktree.name,
          repositoryName: repo.name,
          repositoryID: repo.id,
          workingDirectory: worktree.workingDirectory.path(percentEncoded: false),
          taskStatus: running ? .running : .idle,
          agentBusy: running,
          tabs: tabs,
        ))
      }
    }
    return .worktrees(infos)
  }

  private func handleGetWorktreeStatus(_ worktreeID: String) -> MCPSocketResponse {
    guard let found = findWorktree?(worktreeID) else {
      return .error("Worktree not found: \(worktreeID)")
    }
    let running = getWorktreeTaskStatus?(worktreeID) == .running
    let tabs = getWorktreeTabInfo?(worktreeID) ?? []
    let notifications = getWorktreeNotifications?(worktreeID) ?? []
    return .worktreeStatus(MCPWorktreeStatusInfo(
      id: found.worktree.id,
      name: found.worktree.name,
      repositoryName: found.repository.name,
      workingDirectory: found.worktree.workingDirectory.path(percentEncoded: false),
      taskStatus: running ? .running : .idle,
      agentBusy: running,
      tabs: tabs,
      notificationCount: notifications.count,
    ))
  }

  private func handleSpawnAgent(worktreeID: String, prompt: String?, agent: String?) -> MCPSocketResponse {
    guard let found = findWorktree?(worktreeID) else {
      return .error("Worktree not found: \(worktreeID)")
    }
    guard let agent, let agentKind = AgentKind(agent) else {
      return .error("Invalid agent: must be 'claude' or 'codex'")
    }
    let resolvedPrompt = (prompt?.isEmpty ?? true) ? "hello" : prompt!
    let command = "\(agentKind.rawValue) \(shellQuote(resolvedPrompt))"
    guard let result = spawnAgentTab?(found.worktree, command, agentKind) else {
      return .error("Failed to create agent tab")
    }
    return .spawned(surfaceID: result.surfaceID)
  }

  private func handleSendMessage(worktreeID: String, text: String, tabID: String?, surfaceID: String?)
    -> MCPSocketResponse
  {
    guard findWorktree?(worktreeID) != nil else {
      return .error("Worktree not found: \(worktreeID)")
    }
    let sent = sendToWorktreeSurface?(worktreeID, text, tabID, surfaceID) ?? false

    if !sent {
      return .error(surfaceNotFoundMessage(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID))
    }
    return .ok
  }

  private func handleReadScreen(worktreeID: String, tabID: String?, surfaceID: String?) -> MCPSocketResponse {
    guard findWorktree?(worktreeID) != nil else {
      return .error("Worktree not found: \(worktreeID)")
    }
    guard let content = readWorktreeScreen?(worktreeID, tabID, surfaceID) else {
      return .error(surfaceNotFoundMessage(worktreeID: worktreeID, tabID: tabID, surfaceID: surfaceID))
    }
    return .screenContent(content)
  }

  private func handleListNotifications(worktreeID: String?) -> MCPSocketResponse {
    if let worktreeID {
      guard let found = findWorktree?(worktreeID) else {
        return .error("Worktree not found: \(worktreeID)")
      }
      let notifications = getWorktreeNotifications?(worktreeID) ?? []
      return .notifications(
        notifications.map {
          MCPNotificationInfo(
            worktreeID: worktreeID,
            worktreeName: found.worktree.name,
            title: $0.title,
            body: $0.body,
            isRead: $0.isRead,
          )
        }
      )
    }
    var all: [MCPNotificationInfo] = []
    for repo in getRepositories?() ?? [] {
      for worktree in repo.worktrees {
        for n in getWorktreeNotifications?(worktree.id) ?? [] {
          all.append(MCPNotificationInfo(
            worktreeID: worktree.id,
            worktreeName: worktree.name,
            title: n.title,
            body: n.body,
            isRead: n.isRead,
          ))
        }
      }
    }
    return .notifications(all)
  }

  // MARK: - Writing

  /// Send a response to a specific client.
  private func sendToClient(_ fd: Int32, _ message: MCPSocketMessage) {
    guard let encoded = try? JSONEncoder().encode(message) else { return }
    var data = encoded
    data.append(UInt8(ascii: "\n"))
    var offset = 0
    while offset < data.count {
      let written = data[offset...].withUnsafeBytes { bytes in
        write(fd, bytes.baseAddress!, bytes.count)
      }
      if written <= 0 {
        mcpLogger.warning("MCP write to fd=\(fd) failed: \(String(cString: strerror(errno)))")
        return
      }
      offset += written
    }
  }

  /// Broadcast a message to all connected clients.
  private func broadcastToClients(_ message: MCPSocketMessage) {
    for fd in clients.keys {
      sendToClient(fd, message)
    }
  }

  // MARK: - Helpers

  private func surfaceNotFoundMessage(
    worktreeID: String,
    tabID: String?,
    surfaceID: String?
  ) -> String {
    let tabs = getWorktreeTabInfo?(worktreeID) ?? []
    guard !tabs.isEmpty else {
      return "No terminal tabs in worktree. Use spawn_agent to create one."
    }
    let hasIDs = tabID != nil || surfaceID != nil
    let reason = hasIDs ? "The provided IDs did not match." : "You must provide surface_id."
    let available = tabs.flatMap(\.surfaces).map { s in
      let agent = s.agentName ?? "shell"
      let busy = s.agentBusy ? "busy" : "idle"
      return "surface_id=\(s.surfaceID) (\(agent), \(busy))"
    }
    return "Surface not found. \(reason) Available: \(available.joined(separator: ", "))"
  }

  private func shellQuote(_ string: String) -> String {
    "'" + string.replacing("'", with: "'\\''") + "'"
  }

}
