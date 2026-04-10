import Foundation

/// Log to stderr — stdout is the MCP transport.
package func mcpLog(_ message: String) {
  FileHandle.standardError.write(Data("[supacode-mcp] \(message)\n".utf8))
}
