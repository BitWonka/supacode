import Foundation

private nonisolated let mcpInstallerLogger = SupaLogger("MCPInstaller")

/// Installs/uninstalls the MCP server registration in Claude Code and Codex configs.
nonisolated struct MCPServerInstaller {
  let homeDirectoryURL: URL
  let fileManager: FileManager
  let mcpBinaryPath: String

  init(
    homeDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default,
    mcpBinaryPath: String? = nil
  ) {
    self.homeDirectoryURL = homeDirectoryURL
    self.fileManager = fileManager
    self.mcpBinaryPath =
      mcpBinaryPath
      ?? Bundle.main.url(forResource: "supacode-mcp", withExtension: nil)?
        .path(percentEncoded: false)
      ?? "supacode-mcp"
  }

  // MARK: - Claude Code (~/.claude.json)

  private var claudeConfigURL: URL {
    homeDirectoryURL.appendingPathComponent(".claude.json", isDirectory: false)
  }

  func isClaudeInstalled() -> Bool {
    guard let root = readJSON(at: claudeConfigURL) else { return false }
    guard let servers = root["mcpServers"] as? [String: Any] else { return false }
    return servers["supacode"] != nil
  }

  func installClaude() throws {
    var root = readJSON(at: claudeConfigURL) ?? [:]
    var servers = root["mcpServers"] as? [String: Any] ?? [:]
    servers["supacode"] = ["command": mcpBinaryPath]
    root["mcpServers"] = servers
    try writeJSON(root, to: claudeConfigURL)
    mcpInstallerLogger.info("MCP registered in Claude Code")
  }

  func uninstallClaude() throws {
    guard var root = readJSON(at: claudeConfigURL) else { return }
    guard var servers = root["mcpServers"] as? [String: Any] else { return }
    servers.removeValue(forKey: "supacode")
    root["mcpServers"] = servers
    try writeJSON(root, to: claudeConfigURL)
    mcpInstallerLogger.info("MCP unregistered from Claude Code")
  }

  // MARK: - Codex (~/.codex/config.toml)

  private var codexConfigURL: URL {
    homeDirectoryURL
      .appendingPathComponent(".codex", isDirectory: true)
      .appendingPathComponent("config.toml", isDirectory: false)
  }

  func isCodexInstalled() -> Bool {
    guard let content = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return false }
    return content.contains("[mcp_servers.supacode]")
  }

  func installCodex() throws {
    var content = (try? String(contentsOf: codexConfigURL, encoding: .utf8)) ?? ""
    guard !content.contains("[mcp_servers.supacode]") else { return }
    if !content.isEmpty && !content.hasSuffix("\n") {
      content += "\n"
    }
    content += """
      [mcp_servers.supacode]
      command = "\(mcpBinaryPath)"

      """
    let directory = codexConfigURL.deletingLastPathComponent()
    try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    try content.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    mcpInstallerLogger.info("MCP registered in Codex")
  }

  func uninstallCodex() throws {
    guard let original = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return }
    let lines = original.split(separator: "\n", omittingEmptySubsequences: false)
    var filtered: [Substring] = []
    var skipping = false
    for line in lines {
      if line.trimmingCharacters(in: .whitespaces) == "[mcp_servers.supacode]" {
        skipping = true
        continue
      }
      if skipping {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("[") {
          skipping = false
          filtered.append(line)
        }
        continue
      }
      filtered.append(line)
    }
    var content = filtered.joined(separator: "\n")
    if original.hasSuffix("\n") && !content.hasSuffix("\n") {
      content += "\n"
    }
    try content.write(to: codexConfigURL, atomically: true, encoding: .utf8)
    mcpInstallerLogger.info("MCP unregistered from Codex")
  }

  // MARK: - JSON Helpers

  private func readJSON(at url: URL) -> [String: Any]? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func writeJSON(_ object: [String: Any], to url: URL) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])
    try data.write(to: url, options: .atomic)
  }
}
