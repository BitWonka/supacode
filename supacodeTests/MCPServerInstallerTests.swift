import Foundation
import Testing

@testable import supacode

struct MCPServerInstallerTests {
  private func makeTempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func makeInstaller(home: URL) -> MCPServerInstaller {
    MCPServerInstaller(homeDirectoryURL: home, mcpBinaryPath: "/usr/local/bin/supacode-mcp")
  }

  // MARK: - Claude Code (~/.claude.json)

  @Test func claudeInstallCreatesConfig() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    try installer.installClaude()
    #expect(installer.isClaudeInstalled())

    let data = try Data(contentsOf: home.appendingPathComponent(".claude.json"))
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let servers = try #require(root["mcpServers"] as? [String: Any])
    let supacode = try #require(servers["supacode"] as? [String: Any])
    #expect(supacode["command"] as? String == "/usr/local/bin/supacode-mcp")
  }

  @Test func claudeUninstallRemovesEntry() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    try installer.installClaude()
    #expect(installer.isClaudeInstalled())

    try installer.uninstallClaude()
    #expect(!installer.isClaudeInstalled())
  }

  @Test func claudeInstallPreservesExistingKeys() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    // Write existing config
    let existing: [String: Any] = ["mcpServers": ["other-server": ["command": "other"]], "someKey": true]
    let data = try JSONSerialization.data(withJSONObject: existing, options: .prettyPrinted)
    try data.write(to: home.appendingPathComponent(".claude.json"))

    try installer.installClaude()
    #expect(installer.isClaudeInstalled())

    let updated = try Data(contentsOf: home.appendingPathComponent(".claude.json"))
    let root = try #require(try JSONSerialization.jsonObject(with: updated) as? [String: Any])
    #expect(root["someKey"] as? Bool == true)
    let servers = try #require(root["mcpServers"] as? [String: Any])
    #expect(servers["other-server"] != nil)
    #expect(servers["supacode"] != nil)
  }

  @Test func claudeNotInstalledByDefault() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    #expect(!installer.isClaudeInstalled())
  }

  // MARK: - Codex (~/.codex/config.toml)

  @Test func codexInstallCreatesConfig() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    try installer.installCodex()
    #expect(installer.isCodexInstalled())

    let content = try String(
      contentsOf: home.appendingPathComponent(".codex/config.toml"),
      encoding: .utf8
    )
    #expect(content.contains("[mcp_servers.supacode]"))
    #expect(content.contains("command = \"/usr/local/bin/supacode-mcp\""))
  }

  @Test func codexUninstallRemovesSection() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    try installer.installCodex()
    #expect(installer.isCodexInstalled())

    try installer.uninstallCodex()
    #expect(!installer.isCodexInstalled())
  }

  @Test func codexInstallPreservesExistingSections() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    // Write existing config with another section
    let configDir = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    try "[other_section]\nkey = \"value\"\n".write(
      to: configDir.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    try installer.installCodex()
    let content = try String(
      contentsOf: configDir.appendingPathComponent("config.toml"),
      encoding: .utf8
    )
    #expect(content.contains("[other_section]"))
    #expect(content.contains("[mcp_servers.supacode]"))
  }

  @Test func codexUninstallPreservesOtherSections() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    let configDir = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    let original = """
      [mcp_servers.other]
      command = "other-binary"

      [mcp_servers.supacode]
      command = "/usr/local/bin/supacode-mcp"

      [some_other_section]
      key = "value"

      """
    try original.write(
      to: configDir.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    try installer.uninstallCodex()
    let content = try String(
      contentsOf: configDir.appendingPathComponent("config.toml"),
      encoding: .utf8
    )
    #expect(!content.contains("[mcp_servers.supacode]"))
    #expect(!content.contains("supacode-mcp"))
    #expect(content.contains("[mcp_servers.other]"))
    #expect(content.contains("[some_other_section]"))
  }

  @Test func codexUninstallHandlesBlankLinesWithinSection() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    let configDir = home.appendingPathComponent(".codex")
    try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
    // Blank line within section (user hand-edited)
    let original = """
      [mcp_servers.supacode]
      command = "/usr/local/bin/supacode-mcp"

      extra_key = "should also be removed"

      [other]
      key = "keep"

      """
    try original.write(
      to: configDir.appendingPathComponent("config.toml"),
      atomically: true,
      encoding: .utf8
    )

    try installer.uninstallCodex()
    let content = try String(
      contentsOf: configDir.appendingPathComponent("config.toml"),
      encoding: .utf8
    )
    #expect(!content.contains("supacode"))
    #expect(!content.contains("extra_key"))
    #expect(content.contains("[other]"))
    #expect(content.contains("key = \"keep\""))
  }

  @Test func codexNotInstalledByDefault() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)
    #expect(!installer.isCodexInstalled())
  }

  @Test func codexInstallIsIdempotent() throws {
    let home = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: home) }
    let installer = makeInstaller(home: home)

    try installer.installCodex()
    try installer.installCodex()

    let content = try String(
      contentsOf: home.appendingPathComponent(".codex/config.toml"),
      encoding: .utf8
    )
    let count = content.components(separatedBy: "[mcp_servers.supacode]").count - 1
    #expect(count == 1)
  }
}
