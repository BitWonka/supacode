# SSH Notifications Over SSH

## Goal

Show Supacode notifications when a coding agent is running on a remote machine over `ssh`.

## Decision

This is feasible.

The simplest path is to support remote notifications by emitting terminal notification escape sequences from the remote host and letting the existing local Ghostty -> Supacode notification path handle them.

Structured remote hook parity with the current local socket-based integration is also feasible, but it is a larger feature and should be treated as a second phase.

## Current Supacode Behavior

### Local terminal notifications already work

Supacode already receives terminal desktop notifications from Ghostty:

- `ThirdParty/ghostty/src/terminal/osc.zig`
- `ThirdParty/ghostty/src/terminal/osc/parsers/osc9.zig`
- `ThirdParty/ghostty/src/terminal/osc/parsers/rxvt_extension.zig`
- `ThirdParty/ghostty/src/Surface.zig`
- `supacode/Infrastructure/Ghostty/GhosttySurfaceBridge.swift`
- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
- `supacode/Features/Terminal/BusinessLogic/WorktreeTerminalManager.swift`
- `supacode/Features/App/Reducer/AppFeature.swift`
- `supacode/Clients/Notifications/SystemNotificationClient.swift`

The flow is:

1. A process inside the terminal emits `OSC 9` or `OSC 777`.
2. Ghostty parses the escape sequence into a desktop notification action.
3. `GhosttySurfaceBridge` forwards the title/body into `WorktreeTerminalState`.
4. `WorktreeTerminalState` stores the in-app notification and emits a terminal event.
5. `AppFeature` decides whether to show a macOS system notification and/or sound.

This path is transport-agnostic. If the bytes arrive through a local shell or through a remote `ssh` PTY, the local Ghostty surface sees the same terminal stream.

### Local structured coding-agent hooks do not work remotely

The current Claude/Codex integrations are local-only.

Each terminal surface injects:

- `SUPACODE_WORKTREE_ID`
- `SUPACODE_TAB_ID`
- `SUPACODE_SURFACE_ID`
- `SUPACODE_SOCKET_PATH`

Relevant files:

- `supacode/Features/Terminal/Models/WorktreeTerminalState.swift`
- `supacode/Features/Settings/BusinessLogic/AgentHookSettingsCommand.swift`
- `supacode/Infrastructure/AgentHookSocketServer.swift`

The installed hook commands send either busy-state updates or raw JSON payloads to a local Unix domain socket under `/tmp/supacode-<uid>/pid-<pid>`.

That cannot work from a remote host:

- the remote process cannot access the local Unix socket
- the remote shell does not automatically inherit the local `SUPACODE_*` environment
- the current hook command shape assumes local socket connectivity

## Existing Signals In The Repo

There is already a local helper for the terminal-notification path:

- `bins/osc9-notify.sh`

There are already tests that verify the deduplication behavior between hook notifications and OSC notifications:

- `supacodeTests/AgentBusyStateTests.swift`

This means the local app side is already prepared to accept terminal-originated notifications and coalesce them against richer hook notifications.

## Recommended Implementation

## Phase 1

Add an SSH-safe remote notification mode that uses terminal escape sequences instead of the local Unix socket.

### Why this is the right first step

- It reuses the existing app-side pipeline.
- It avoids new transport infrastructure.
- It solves the user-visible problem in `SUP-39`.
- It keeps the change narrow and forward-only.

### Notification protocol choice

Use `OSC 777` for agent hooks.

Why:

- `OSC 9` only gives a body in the current Ghostty path.
- `OSC 777` supports both title and body.
- Supacode already receives both title and body from Ghostty for desktop notifications.

`OSC 9` can remain useful for smoke testing and manual scripts, but `OSC 777` is the better hook transport.

### Implementation shape

Add a second hook command builder that emits terminal notifications instead of writing to the local socket.

The hook command should:

1. Read the raw JSON payload from `stdin`.
2. Extract:
   - `title`
   - `message`
   - `last_assistant_message`
   - `hook_event_name`
3. Choose a title/body:
   - title = payload title if present, otherwise agent name
   - body = `message` or `last_assistant_message`
4. Sanitize terminal control characters and delimiters.
5. Emit `OSC 777`.

The easiest portable implementation is a small helper script that uses `python3` to parse JSON and print the escape sequence.

### Command selection

The hook installer should generate commands using this rule:

- if `SUPACODE_SOCKET_PATH` exists, use the current local socket command
- otherwise, if the process is running in an SSH session, use the remote OSC command

Remote detection should prefer explicit signal over inference:

- first: `SUPACODE_REMOTE_NOTIFICATIONS=1`
- second: `SSH_CONNECTION` or `SSH_TTY`

This avoids changing local behavior and keeps the new path opt-in or clearly scoped to remote sessions.

### Scope

Phase 1 should only cover notifications.

It should not try to preserve:

- local hook busy-state updates
- tab/surface targeting parity beyond the active remote terminal stream
- remote install automation

### Acceptance criteria

- a remote Claude/Codex hook can emit a Supacode notification over `ssh`
- the local app records the notification in the worktree list
- the local app can show a macOS system notification
- the existing hook-vs-OSC deduplication still works
- local non-SSH hook behavior is unchanged

### Tests

Add tests for:

- remote helper payload parsing
- `OSC 777` title/body delivery through the existing bridge callback
- command selection logic between local socket and remote OSC modes
- sanitization of control characters

## Phase 2

Add a real remote relay for structured hook parity.

This is the path if Supacode needs:

- busy-state rings for remote agents
- richer remote targeting semantics
- remote commands that land in the local socket transport instead of going through terminal escape sequences
- remote installation/bootstrap owned by Supacode

### Architecture

The relay shape should be:

1. Supacode starts a local authenticated relay server.
2. Supacode opens an SSH reverse tunnel back to that local relay.
3. Supacode installs remote metadata or helper wrappers on the remote host.
4. Remote hook commands talk to the tunneled relay endpoint.
5. The local relay forwards the request into the existing local Unix socket or directly into app state.

### What this unlocks

- remote busy-state updates with the existing structured model
- remote notifications without shell JSON parsing in the app-specific hook command
- future remote agent commands beyond notifications

### Why this is not phase 1

- it introduces authentication, bootstrap, lifecycle, and reconnect behavior
- it is a larger surface area than the problem requires
- it should be justified by remote busy-state or broader remote orchestration goals

## Risks And Open Questions

### tmux and nested terminal layers

Plain `ssh` PTY delivery should work. Nested layers such as `tmux` may require validation because escape-sequence passthrough behavior depends on terminal configuration.

This should be treated as a compatibility matrix item for phase 1 validation, not as a blocker to the first implementation.

### Remote helper availability

The simplest JSON parser is `python3`. If remote environments without Python need to be supported, Supacode should ship a tiny helper binary or install a standalone script during remote bootstrap.

### Automatic installation on the remote host

Phase 1 does not require Supacode to edit remote config files automatically. If product requirements demand a one-click remote install, that belongs with the relay/bootstrap work in phase 2.

## Proposed Work Split

### Issue 1

Implement SSH-safe remote notifications via `OSC 777`.

### Issue 2

Add a remote relay for structured hook parity and busy-state updates.

## Summary

Supacode can show notifications over `ssh` today if the remote process emits terminal notification escape sequences.

The missing piece is not the app-side notification pipeline. The missing piece is the remote integration path.

The recommended order is:

1. ship SSH-safe hook notifications over `OSC 777`
2. add a real remote relay only if remote structured parity is needed
