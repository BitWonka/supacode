import Foundation

// MARK: - Agent Kind

nonisolated enum AgentKind: String {
  case claude
  case codex

  init?(_ name: String?) {
    guard let name else { return nil }
    self.init(rawValue: name.lowercased())
  }
}

// MARK: - Wire Protocol

/// Requests sent from the MCP binary to the Supacode app.
nonisolated enum MCPSocketRequest: Codable {
  case listWorktrees
  case getWorktreeStatus(worktreeID: String)
  case spawnAgent(worktreeID: String, prompt: String?, agent: String?)
  case sendMessage(worktreeID: String, text: String, wait: Bool?, tabID: String?, surfaceID: String?)
  case readScreen(worktreeID: String, tabID: String?, surfaceID: String?)
  case listNotifications(worktreeID: String?)
}

/// Responses sent from the Supacode app back to the MCP binary.
nonisolated enum MCPSocketResponse: Codable {
  case worktrees([MCPWorktreeInfo])
  case worktreeStatus(MCPWorktreeStatusInfo)
  case spawned(surfaceID: String)
  case ok
  case screenContent(String)
  case notifications([MCPNotificationInfo])
  case error(String)
}

/// Events pushed from the Supacode app to the MCP binary (unsolicited).
nonisolated enum MCPSocketEvent: Codable {
  case agentBusyChanged(worktreeID: String, surfaceID: String, active: Bool)
  case agentNotification(worktreeID: String, surfaceID: String, agent: String, event: String, title: String?, body: String?)
}

/// Envelope for multiplexing requests, responses, and events on one socket.
nonisolated enum MCPSocketMessage: Codable {
  case request(id: Int, MCPSocketRequest)
  case response(id: Int, MCPSocketResponse)
  case event(MCPSocketEvent)
}

// MARK: - Data Types

nonisolated enum MCPTaskStatus: String, Codable {
  case running
  case idle
}

nonisolated struct MCPWorktreeInfo: Codable {
  let id: String
  let name: String
  let repositoryName: String
  let repositoryID: String
  let workingDirectory: String
  let taskStatus: MCPTaskStatus
  let agentBusy: Bool
  let tabs: [MCPTabInfo]
}

nonisolated struct MCPTabInfo: Codable {
  let tabID: String
  let title: String
  let isRunning: Bool
  let focusedSurfaceID: String?
  let surfaces: [MCPSurfaceInfo]
}

nonisolated struct MCPSurfaceInfo: Codable {
  let surfaceID: String
  let title: String?
  let agentName: String?
  let agentBusy: Bool
}

nonisolated struct MCPWorktreeStatusInfo: Codable {
  let id: String
  let name: String
  let repositoryName: String
  let workingDirectory: String
  let taskStatus: MCPTaskStatus
  let agentBusy: Bool
  let tabs: [MCPTabInfo]
  let notificationCount: Int
}

nonisolated struct MCPNotificationInfo: Codable {
  let worktreeID: String
  let worktreeName: String
  let title: String
  let body: String
  let isRead: Bool
}
