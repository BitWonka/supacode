import Foundation

// Duplicated from supacode/Infrastructure/MCP/MCPSocketProtocol.swift — keep in sync.

// MARK: - Wire Protocol

package enum MCPSocketRequest: Codable {
  case listWorktrees
  case getWorktreeStatus(worktreeID: String)
  case spawnAgent(worktreeID: String, prompt: String?, agent: String?)
  case sendMessage(worktreeID: String, text: String, wait: Bool?, tabID: String?, surfaceID: String?)
  case readScreen(worktreeID: String, tabID: String?, surfaceID: String?)
  case listNotifications(worktreeID: String?)
}

package enum MCPSocketResponse: Codable {
  case worktrees([MCPWorktreeInfo])
  case worktreeStatus(MCPWorktreeStatusInfo)
  case spawned(surfaceID: String)
  case success
  case screenContent(String)
  case notifications([MCPNotificationInfo])
  case error(String)
}

package enum MCPSocketEvent: Codable {
  case agentBusyChanged(worktreeID: String, surfaceID: String, active: Bool)
  case agentNotification(worktreeID: String, surfaceID: String, agent: String, event: String, title: String?, body: String?)
}

package enum MCPSocketMessage: Codable {
  case request(id: Int, MCPSocketRequest)
  case response(id: Int, MCPSocketResponse)
  case event(MCPSocketEvent)
}

// MARK: - Data Types

package enum MCPTaskStatus: String, Codable {
  case running
  case idle
}

package struct MCPWorktreeInfo: Codable {
  package let id: String
  package let name: String
  package let repositoryName: String
  package let repositoryID: String
  package let workingDirectory: String
  package let taskStatus: MCPTaskStatus
  package let agentBusy: Bool
  package let tabs: [MCPTabInfo]
}

package struct MCPTabInfo: Codable {
  package let tabID: String
  package let title: String
  package let isRunning: Bool
  package let focusedSurfaceID: String?
  package let surfaces: [MCPSurfaceInfo]
}

package struct MCPSurfaceInfo: Codable {
  package let surfaceID: String
  package let title: String?
  package let agentName: String?
  package let agentBusy: Bool
}

package struct MCPWorktreeStatusInfo: Codable {
  package let id: String
  package let name: String
  package let repositoryName: String
  package let workingDirectory: String
  package let taskStatus: MCPTaskStatus
  package let agentBusy: Bool
  package let tabs: [MCPTabInfo]
  package let notificationCount: Int
}

package struct MCPNotificationInfo: Codable {
  package let worktreeID: String
  package let worktreeName: String
  package let title: String
  package let body: String
  package let isRead: Bool
}
