import ComposableArchitecture
import Foundation

struct MCPServerInstallerClient: Sendable {
  var isClaudeInstalled: @Sendable () -> Bool
  var isCodexInstalled: @Sendable () -> Bool
  var installClaude: @Sendable () throws -> Void
  var installCodex: @Sendable () throws -> Void
  var uninstallClaude: @Sendable () throws -> Void
  var uninstallCodex: @Sendable () throws -> Void
}

extension MCPServerInstallerClient: DependencyKey {
  static let liveValue = Self(
    isClaudeInstalled: { MCPServerInstaller().isClaudeInstalled() },
    isCodexInstalled: { MCPServerInstaller().isCodexInstalled() },
    installClaude: { try MCPServerInstaller().installClaude() },
    installCodex: { try MCPServerInstaller().installCodex() },
    uninstallClaude: { try MCPServerInstaller().uninstallClaude() },
    uninstallCodex: { try MCPServerInstaller().uninstallCodex() }
  )
  static let testValue = Self(
    isClaudeInstalled: { false },
    isCodexInstalled: { false },
    installClaude: {},
    installCodex: {},
    uninstallClaude: {},
    uninstallCodex: {}
  )
}

extension DependencyValues {
  var mcpServerInstallerClient: MCPServerInstallerClient {
    get { self[MCPServerInstallerClient.self] }
    set { self[MCPServerInstallerClient.self] = newValue }
  }
}
