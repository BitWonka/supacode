import Foundation
import MCP
import SupacodeMCPLib

// MARK: - Socket Path Discovery

func discoverSocketPath() -> String? {
  let uid = getuid()
  let path = "/tmp/supacode-\(uid)/mcp.sock"
  if FileManager.default.fileExists(atPath: path) {
    return path
  }
  return nil
}

// MARK: - Tool Definitions

let listWorktreesTool = Tool(
  name: "list_worktrees",
  description:
    "List all repositories and worktrees managed by Supacode, "
    + "with their current task status, supagent busy state, and tab/surface info.",
  inputSchema: .object([
    "type": .string("object"),
    "properties": .object([:]),
    "additionalProperties": .bool(false),
  ]),
  annotations: .init(readOnlyHint: true)
)

let getWorktreeStatusTool = Tool(
  name: "get_worktree_status",
  description:
    "Get detailed status for a specific worktree "
    + "including tabs, notifications, task status, and supagent busy state.",
  inputSchema: .object([
    "type": .string("object"),
    "properties": .object([
      "worktree_id": .object([
        "type": .string("string"),
        "description": .string("The worktree ID (filesystem path)"),
      ]),
    ]),
    "required": .array([.string("worktree_id")]),
    "additionalProperties": .bool(false),
  ]),
  annotations: .init(readOnlyHint: true)
)

let spawnSupagentTool = Tool(
  name: "spawn_supagent",
  description:
    "Spawn a coding supagent in a new terminal tab. "
    + "You MUST specify which agent to use ('claude' or 'codex'). "
    + "Blocks until the supagent finishes its initial task and returns "
    + "the response along with surface_id for further interaction "
    + "via send_message/read_screen.",
  inputSchema: .object([
    "type": .string("object"),
    "properties": .object([
      "worktree_id": .object([
        "type": .string("string"),
        "description": .string("The worktree ID to spawn the supagent in"),
      ]),
      "prompt": .object([
        "type": .string("string"),
        "description": .string("Optional prompt/task for the supagent"),
      ]),
      "agent": .object([
        "type": .string("string"),
        "description": .string("Which agent to run: 'claude' or 'codex'. Required."),
      ]),
    ]),
    "required": .array([.string("worktree_id"), .string("agent")]),
    "additionalProperties": .bool(false),
  ]),
  annotations: .init(destructiveHint: false)
)

let sendMessageTool = Tool(
  name: "send_message",
  description:
    "Send a message to a running supagent's terminal. "
    + "You MUST provide surface_id (get it from list_worktrees or spawn_supagent). "
    + "With wait=true, blocks until the supagent finishes and returns its response "
    + "— use this from a subagent for background execution. "
    + "With wait=false (default), returns immediately.",
  inputSchema: .object([
    "type": .string("object"),
    "properties": .object([
      "worktree_id": .object([
        "type": .string("string"),
        "description": .string("The worktree ID"),
      ]),
      "surface_id": .object([
        "type": .string("string"),
        "description": .string(
          "The surface ID to send to "
          + "(from list_worktrees tabs[].surfaces[].surfaceID or spawn_supagent response)."
        ),
      ]),
      "text": .object([
        "type": .string("string"),
        "description": .string("Message to send to the supagent"),
      ]),
      "wait": .object([
        "type": .string("boolean"),
        "description": .string(
          "If true, wait for the supagent to finish and return its response. Default false."
        ),
      ]),
    ]),
    "required": .array([
      .string("worktree_id"), .string("surface_id"), .string("text"),
    ]),
    "additionalProperties": .bool(false),
  ]),
  annotations: .init(destructiveHint: false)
)

let readScreenTool = Tool(
  name: "read_screen",
  description:
    "Read the terminal screen content for a specific surface. "
    + "You MUST provide surface_id (get it from list_worktrees or spawn_supagent).",
  inputSchema: .object([
    "type": .string("object"),
    "properties": .object([
      "worktree_id": .object([
        "type": .string("string"),
        "description": .string("The worktree ID"),
      ]),
      "surface_id": .object([
        "type": .string("string"),
        "description": .string(
          "The surface ID to read "
          + "(from list_worktrees tabs[].surfaces[].surfaceID or spawn_supagent response)."
        ),
      ]),
    ]),
    "required": .array([.string("worktree_id"), .string("surface_id")]),
    "additionalProperties": .bool(false),
  ]),
  annotations: .init(readOnlyHint: true)
)

let listNotificationsTool = Tool(
  name: "list_notifications",
  description: "Read notification history for agents. Optionally filter by worktree.",
  inputSchema: .object([
    "type": .string("object"),
    "properties": .object([
      "worktree_id": .object([
        "type": .string("string"),
        "description": .string("Optional worktree ID to filter notifications"),
      ]),
    ]),
    "additionalProperties": .bool(false),
  ]),
  annotations: .init(readOnlyHint: true)
)

let allTools = [
  listWorktreesTool,
  getWorktreeStatusTool,
  spawnSupagentTool,
  sendMessageTool,
  readScreenTool,
  listNotificationsTool,
]

// MARK: - Degraded Server (Supacode not running)

func runDegradedServer() async throws -> Never {
  mcpLog("Supacode is not running (no socket found)")
  let server = Server(
    name: "supacode",
    version: "0.1.0",
    capabilities: .init(tools: .init()),
  )
  await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: allTools)
  }
  await server.withMethodHandler(CallTool.self) { _ in
    .init(
      content: [
        .text(
          text: "Supacode is not running. Launch the app first.",
          annotations: nil,
          _meta: nil
        ),
      ],
      isError: true,
    )
  }
  let transport = StdioTransport()
  try await server.start(transport: transport)
  await server.waitUntilCompleted()
  exit(0)
}

// MARK: - Main

guard let socketPath = discoverSocketPath() else {
  try await runDegradedServer()
}

mcpLog("Connecting to Supacode at \(socketPath)")
let client = SocketClient(socketPath: socketPath)
let socketFD: Int32
do {
  socketFD = try client.connect()
} catch {
  try await runDegradedServer()
}
mcpLog("Connected")

Task.detached {
  client.readLoop(fd: socketFD)
}

let server = Server(
  name: "supacode",
  version: "0.1.0",
  capabilities: .init(logging: .init(), tools: .init()),
)

await server.withMethodHandler(ListTools.self) { _ in
  ListTools.Result(tools: allTools)
}

await server.withMethodHandler(CallTool.self) { params in
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

  func txt(_ string: String) -> Tool.Content {
    .text(text: string, annotations: nil, _meta: nil)
  }

  do {
    switch params.name {
    case "list_worktrees":
      let response = try await client.send(fd: socketFD, .listWorktrees)
      guard case .worktrees(let worktrees) = response else {
        return errorResult(response)
      }
      let json = String(
        bytes: try encoder.encode(worktrees), encoding: .utf8
      ) ?? ""
      return .init(content: [txt(json)])

    case "get_worktree_status":
      guard let worktreeID = params.arguments?["worktree_id"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: worktree_id")],
          isError: true
        )
      }
      let response = try await client.send(
        fd: socketFD, .getWorktreeStatus(worktreeID: worktreeID)
      )
      guard case .worktreeStatus(let status) = response else {
        return errorResult(response)
      }
      let json = String(
        bytes: try encoder.encode(status), encoding: .utf8
      ) ?? ""
      return .init(content: [txt(json)])

    case "spawn_supagent":
      guard let worktreeID = params.arguments?["worktree_id"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: worktree_id")],
          isError: true
        )
      }
      let prompt = params.arguments?["prompt"]?.stringValue
      guard let agent = params.arguments?["agent"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: agent")],
          isError: true
        )
      }
      let response = try await client.send(
        fd: socketFD,
        .spawnSupagent(worktreeID: worktreeID, prompt: prompt, agent: agent)
      )
      guard case .spawned(let surfaceID) = response else {
        return errorResult(response)
      }
      let key = client.prepareCompletion(
        worktreeID: worktreeID, surfaceID: surfaceID
      )
      let completion = await client.waitForCompletion(canonical: key)
      var result =
        "Supagent spawned in worktree \(worktreeID). surface_id: \(surfaceID)"
      if !completion.messages.isEmpty {
        let joined = completion.messages.joined(separator: "\n\n")
        result += "\n\nSupagent response:\n\(joined)"
      }
      return .init(content: [txt(result)])

    case "send_message":
      guard let worktreeID = params.arguments?["worktree_id"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: worktree_id")],
          isError: true
        )
      }
      guard let text = params.arguments?["text"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: text")],
          isError: true
        )
      }
      let shouldWait = params.arguments?["wait"]?.boolValue ?? false
      guard let surfaceID = params.arguments?["surface_id"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: surface_id")],
          isError: true
        )
      }
      let canonical: String?
      if shouldWait {
        canonical = client.prepareCompletion(
          worktreeID: worktreeID, surfaceID: surfaceID
        )
      } else {
        canonical = nil
      }
      let response: MCPSocketResponse
      do {
        response = try await client.send(
          fd: socketFD,
          .sendMessage(
            worktreeID: worktreeID,
            text: text,
            wait: shouldWait,
            tabID: nil,
            surfaceID: surfaceID
          ),
        )
      } catch {
        if let canonical { client.cancelCompletion(canonical: canonical) }
        throw error
      }
      if case .error(let msg) = response {
        if let canonical { client.cancelCompletion(canonical: canonical) }
        return .init(content: [txt(msg)], isError: true)
      }
      if shouldWait, let canonical {
        let completion = await client.waitForCompletion(
          canonical: canonical
        )
        if !completion.messages.isEmpty {
          let joined = completion.messages.joined(separator: "\n\n")
          return .init(content: [txt(joined)])
        }
        return .init(
          content: [txt("Supagent finished in worktree \(worktreeID)")]
        )
      }
      return .init(
        content: [txt("Message sent to supagent in worktree \(worktreeID)")]
      )

    case "read_screen":
      guard let worktreeID = params.arguments?["worktree_id"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: worktree_id")],
          isError: true
        )
      }
      guard let surfaceID = params.arguments?["surface_id"]?.stringValue else {
        return .init(
          content: [txt("Missing required parameter: surface_id")],
          isError: true
        )
      }
      let response = try await client.send(
        fd: socketFD,
        .readScreen(
          worktreeID: worktreeID, tabID: nil, surfaceID: surfaceID
        )
      )
      guard case .screenContent(let content) = response else {
        return errorResult(response)
      }
      return .init(content: [txt(content)])

    case "list_notifications":
      let worktreeID = params.arguments?["worktree_id"]?.stringValue
      let response = try await client.send(
        fd: socketFD, .listNotifications(worktreeID: worktreeID)
      )
      guard case .notifications(let notifications) = response else {
        return errorResult(response)
      }
      let json = String(
        bytes: try encoder.encode(notifications), encoding: .utf8
      ) ?? ""
      return .init(content: [txt(json)])

    default:
      return .init(content: [txt("Unknown tool: \(params.name)")], isError: true)
    }
  } catch {
    return .init(
      content: [txt("Error communicating with Supacode: \(error)")],
      isError: true,
    )
  }
}

@Sendable func errorResult(_ response: MCPSocketResponse) -> CallTool.Result {
  if case .error(let msg) = response {
    return .init(
      content: [.text(text: msg, annotations: nil, _meta: nil)],
      isError: true,
    )
  }
  return .init(
    content: [.text(text: "Unexpected response from Supacode", annotations: nil, _meta: nil)],
    isError: true,
  )
}

// Forward events from Supacode to MCP client via server.log()
Task {
  let encoder = JSONEncoder()
  for await event in client.eventStream {
    guard let data = try? encoder.encode(event),
      let json = String(bytes: data, encoding: .utf8)
    else { continue }
    try? await server.log(
      level: .info, logger: "supacode.events", data: json
    )
  }
}

let transport = StdioTransport()
try await server.start(transport: transport)
mcpLog("MCP server started")
await server.waitUntilCompleted()
