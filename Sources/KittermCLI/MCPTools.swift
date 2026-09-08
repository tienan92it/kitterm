import Foundation

/// The foreman toolset, as MCP tools that proxy kitterm's HTTP API. Zero
/// daemon knowledge of MCP: each tool is a small mapping to a request the
/// daemon already serves, so the bridge is a translator and nothing more.
///
/// Deliberately **no approve/deny tool**. Deciding a permission prompt is a
/// human privilege in kitterm's model — the watch grade exists precisely to
/// withhold it — so a foreman *surfaces* approvals (`list_approvals`,
/// `wait_for_events`) and the human answers in the fleet view.
enum MCPTools {
    /// One HTTP request a tool call turns into.
    struct Call {
        let method: String
        let path: String
        /// JSON body, or nil for a bodyless request. `rawBody` overrides this
        /// for the input route, which takes bytes, not JSON.
        var jsonBody: [String: Any]?
        var rawBody: Data?
        /// Set for `read_screen`: the bridge renders the response bytes at
        /// these dimensions instead of returning them as text.
        var screen: ScreenOptions?
    }

    /// How `read_screen` lays the bytes out. `cols`/`rows` nil means the
    /// pane's real size, from the response headers.
    struct ScreenOptions: Equatable {
        var cols: Int?
        var rows: Int?
        var styles: Bool
    }

    enum ToolError: Error { case badArguments(String) }

    /// The tool list for `tools/list`. Kept in one place so the schema a client
    /// caches and the dispatch below cannot drift.
    static func schemas() -> [[String: Any]] {
        [
            tool(
                "list_sessions",
                "List every live session — the crew — with each one's typed state (working / needs-input / needs-approval / completed / failed / idle / exited), name, cwd, last command, and foregroundProgram: the program that holds the terminal (claude, vim), absent when the shell is at its prompt. A row with `heldSince` (epoch ms) is one the linger clock kept past its window because a program held the terminal or output arrived; the daemon never ends such a session itself, so end the ones held longer than you tolerate with kill_session.",
                properties: [
                    "label": ["type": "string", "description": "Optional key:value filter, e.g. crew:alpha"],
                    "project": ["type": "string", "description": "Optional project id filter (see list_projects)"],
                ]
            ),
            tool(
                "get_session",
                "Read one session's full status row by id, including foregroundProgram (what holds the terminal, absent when the shell is at its prompt) and `heldSince` when the linger clock is holding it.",
                properties: ["session": idProp],
                required: ["session"]
            ),
            tool(
                "spawn_session",
                "Start a new crew session. Give it a name; optionally a cwd, a profile, labels, and an initial input line (e.g. \"claude\\n\") typed at its first prompt. Returns the id and the paths to open or attach it.",
                properties: [
                    "name": ["type": "string", "description": "Human name for the session (the fleet-view headline)"],
                    "cwd": ["type": "string", "description": "Working directory; must exist"],
                    "profile": ["type": "string", "description": "Named session profile from profiles.json"],
                    "note": ["type": "string", "description": "A short status note"],
                    "input": ["type": "string", "description": "Bytes typed at the first prompt; include the trailing newline to run it"],
                    "labels": labelsProp,
                ]
            ),
            tool(
                "rename_session",
                "Set a session's name, note, or labels.",
                properties: [
                    "session": idProp,
                    "name": ["type": "string"],
                    "note": ["type": "string"],
                    "labels": labelsProp,
                ],
                required: ["session"]
            ),
            tool(
                "send_input",
                "Type into a crew session — a message to its agent, an answer to a prompt, or a shell command. By default Enter is pressed after the text, as whatever reads the session expects it (a newline for the shell, a carriage return for an interactive claude), so the text is submitted wherever it lands. Set enter:false to send keystrokes only (send \"\\u0003\" as text for Ctrl-C). A text over 1 KiB is refused with a `cooked reader` error while the terminal is in cooked mode — a `sleep`, a program still starting, a shell in a here-doc — because the kernel cuts a cooked line at 1024 bytes and nothing typed would arrive whole. The error names the program (`foregroundProgram`): read the screen, wait for the program to take raw mode (an interactive claude does), then send again. Set force:true to type it anyway.",
                properties: [
                    "session": idProp,
                    "text": ["type": "string", "description": "The text to type; may be empty to press Enter alone"],
                    "enter": ["type": "boolean", "description": "Press Enter after the text so it is submitted (default true)"],
                    "force": ["type": "boolean", "description": "Type a text over 1 KiB even while a cooked reader holds the terminal (default false)"],
                ],
                required: ["session", "text"]
            ),
            tool(
                "list_commands",
                "List the commands a session has run, with exit codes and output offsets.",
                properties: ["session": idProp],
                required: ["session"]
            ),
            tool(
                "wait_for_command",
                "Block until command <n> in a session finishes, then return its exit code. A timeout is not an error — it returns running:true, ask again. This is the execute() half of the loop: send a command, wait for its exit, read its output.",
                properties: [
                    "session": idProp,
                    "command": ["type": "integer", "description": "The 1-based command index"],
                    "timeout": ["type": "integer", "description": "Seconds to wait (default 30, max 300)"],
                ],
                required: ["session", "command"]
            ),
            tool(
                "read_output",
                "Read the captured output of command <n> in a session (tail of large output).",
                properties: [
                    "session": idProp,
                    "command": ["type": "integer"],
                ],
                required: ["session", "command"]
            ),
            tool(
                "read_screen",
                "Read what a session's pane shows right now, rendered at its real size — the screen a human sees, not the raw byte stream. Use this before typing into a TUI such as Claude Code: it tells you whether the prompt is empty, what a dialog offers, and where the cursor is. Returns {cols, rows, cursor:{row,col}, lines}. By default a dim run is wrapped in {dim}…{/dim} (Claude Code's ghost suggestion on an empty prompt is dim, not typed text) and an inverse run in {inv}…{/inv}; pass styles:false for plain text.",
                properties: [
                    "session": idProp,
                    "tail": ["type": "integer", "description": "Bytes of recent output to render (default 65536, max 262144). Raise it if the screen looks incomplete."],
                    "cols": ["type": "integer", "description": "Override the pane width"],
                    "rows": ["type": "integer", "description": "Override the pane height"],
                    "styles": ["type": "boolean", "description": "Mark dim and inverse runs (default true)"],
                ],
                required: ["session"]
            ),
            tool(
                "wait_for_events",
                "The foreman's heartbeat: block until something changes across the whole crew — a status change (one `agent.status` event per transition: a session that stays `working` across many tool calls is silent, and a repeated `needs-input` is a new event only when its message changes), an approval, a spawn, an exit, a posted note, or a `session.lingered` (the linger clock kept a session past a window; its data says why: reason `foreground` with the `program` name, or `output`, and `heldSince`) — then return the events. Pass the `next` cursor from the previous call as `since` and its `epoch` as `epoch`. One call watches every session at once; re-invoke in a loop. A timeout returns no events, which just means \"still quiet\". A result whose `epoch` differs from the last one means the daemon restarted: every session id you held is gone, the first event is `daemon.started`, and `pruned` is true. Re-list the sessions and match them by labels and cwd. A `daemon.started` whose data has `takeover` set to \"true\" in the same epoch is an upgrade in place: every session id is still good, so continue. A connection error mid-wait is that upgrade's socket closing; call again with the same cursor and epoch.",
                properties: [
                    "since": ["type": "integer", "description": "Cursor from the previous call's `next` (0 to start)"],
                    "epoch": ["type": "string", "description": "The previous call's `epoch`; omit on the first call. A mismatch is answered at once with `pruned` true"],
                    "session": ["type": "string", "description": "Optional: only this session's events"],
                    "timeout": ["type": "integer", "description": "Seconds to wait (default 25, max 300)"],
                ]
            ),
            tool(
                "post_note",
                "Post a status note about a session onto the event feed, so a watching foreman or human sees it (e.g. \"plan ready for review\").",
                properties: [
                    "session": idProp,
                    "message": ["type": "string"],
                ],
                required: ["session", "message"]
            ),
            tool(
                "list_approvals",
                "List the tool calls currently blocked waiting for a human to allow or deny. A foreman surfaces these; a human answers them in the fleet view.",
                properties: [:]
            ),
            tool(
                "kill_session",
                "End a session and its shell now.",
                properties: ["session": idProp],
                required: ["session"]
            ),
            tool(
                "archive_session",
                "Archive a finished session: save its commands, exit codes, and output to disk, then end it. kitterm keeps what the session did, not a live process — to \"resume\", spawn a new session with the same name and cwd and read the archive for context.",
                properties: ["session": idProp],
                required: ["session"]
            ),
            tool(
                "list_archives",
                "List archived sessions — finished work whose evidence was kept.",
                properties: [:]
            ),
            tool(
                "list_projects",
                "List every project the daemon has seen: registered in ~/.kitterm/projects.json (kitterm project add) or discovered from a session's cwd by its .git. Each row carries id, name, root, registered, knowledge (the goal package directory, docs/goals by default), live session counts by state, pending approvals, lastOutputAt, and archive count. A foreman scans this to find each project's docs/goals/STATE.md; filter list_sessions by project with its project argument.",
                properties: [:]
            ),
        ]
    }

    /// Map a tool call to the HTTP request that serves it. Throws
    /// `badArguments` for a missing or malformed argument, which the bridge
    /// reports as an MCP tool error.
    static func call(named name: String, arguments: [String: Any]) throws -> Call {
        switch name {
        case "list_sessions":
            var query: [String] = []
            if let label = arguments["label"] as? String, !label.isEmpty {
                query.append("label=\(escape(label))")
            }
            if let project = arguments["project"] as? String, !project.isEmpty {
                query.append("project=\(escape(project))")
            }
            let path = "/api/sessions" + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
            return Call(method: "GET", path: path)

        case "get_session":
            return Call(method: "GET", path: "/api/sessions/\(try id(arguments))")

        case "spawn_session":
            var body: [String: Any] = [:]
            for key in ["name", "cwd", "profile", "note", "input"] {
                if let value = arguments[key] as? String, !value.isEmpty { body[key] = value }
            }
            if let labels = arguments["labels"] as? [String: Any] { body["labels"] = labels }
            return Call(method: "POST", path: "/api/sessions", jsonBody: body)

        case "rename_session":
            var body: [String: Any] = [:]
            for key in ["name", "note"] {
                if let value = arguments[key] as? String { body[key] = value }
            }
            if let labels = arguments["labels"] as? [String: Any] { body["labels"] = labels }
            guard !body.isEmpty else { throw ToolError.badArguments("give a name, note, or labels") }
            return Call(method: "PATCH", path: "/api/sessions/\(try id(arguments))", jsonBody: body)

        case "send_input":
            guard let text = arguments["text"] as? String else {
                throw ToolError.badArguments("text is required")
            }
            let enter = (arguments["enter"] as? Bool) ?? true
            // The daemon refuses a large text while a cooked reader holds the
            // terminal; `force` is the caller's word that it knows better.
            let force = (arguments["force"] as? Bool) ?? false
            var query: [String] = []
            if enter { query.append("enter=1") }
            if force { query.append("force=1") }
            let route = "/api/sessions/\(try id(arguments))/input"
                + (query.isEmpty ? "" : "?" + query.joined(separator: "&"))
            guard enter else {
                guard !text.isEmpty else { throw ToolError.badArguments("text is required") }
                return Call(method: "POST", path: route, rawBody: Data(text.utf8))
            }
            // The daemon presses Enter with the byte the session's foreground
            // reads — the bridge cannot know whether a shell or a claude is
            // listening. A trailing newline in the text is the caller's own
            // Enter, so it is folded into the request rather than sent as a
            // line feed that an interactive program would keep as text.
            let line = text.hasSuffix("\n") ? String(text.dropLast()) : text
            return Call(method: "POST", path: route, rawBody: Data(line.utf8))

        case "list_commands":
            return Call(method: "GET", path: "/api/sessions/\(try id(arguments))/commands")

        case "wait_for_command":
            let n = try commandIndex(arguments)
            var path = "/api/sessions/\(try id(arguments))/commands/\(n)/wait"
            if let timeout = arguments["timeout"] as? Int { path += "?timeout=\(timeout)" }
            return Call(method: "GET", path: path)

        case "read_output":
            let n = try commandIndex(arguments)
            return Call(method: "GET", path: "/api/sessions/\(try id(arguments))/commands/\(n)/output")

        case "read_screen":
            var path = "/api/sessions/\(try id(arguments))/output"
            if let tail = arguments["tail"] as? Int {
                guard tail >= 1 else { throw ToolError.badArguments("tail must be positive") }
                path += "?tail=\(tail)"
            }
            var options = ScreenOptions(styles: (arguments["styles"] as? Bool) ?? true)
            for (key, keyPath) in [("cols", \ScreenOptions.cols), ("rows", \ScreenOptions.rows)] {
                guard let raw = arguments[key] else { continue }
                guard let value = raw as? Int, value >= 1, value <= 1000 else {
                    throw ToolError.badArguments("\(key) must be an integer from 1 to 1000")
                }
                options[keyPath: keyPath] = value
            }
            return Call(method: "GET", path: path, screen: options)

        case "wait_for_events":
            var query: [String] = []
            query.append("since=\((arguments["since"] as? Int) ?? 0)")
            if let epoch = arguments["epoch"] as? String, !epoch.isEmpty {
                query.append("epoch=\(escape(epoch))")
            }
            if let timeout = arguments["timeout"] as? Int { query.append("timeout=\(timeout)") }
            if let session = arguments["session"] as? String, !session.isEmpty {
                query.append("session=\(escape(session))")
            }
            return Call(method: "GET", path: "/api/events?" + query.joined(separator: "&"))

        case "post_note":
            guard let message = arguments["message"] as? String, !message.isEmpty else {
                throw ToolError.badArguments("message is required")
            }
            return Call(
                method: "POST",
                path: "/api/sessions/\(try id(arguments))/events",
                jsonBody: ["message": message]
            )

        case "list_approvals":
            return Call(method: "GET", path: "/api/approvals")

        case "kill_session":
            return Call(method: "DELETE", path: "/api/sessions/\(try id(arguments))")

        case "archive_session":
            return Call(method: "POST", path: "/api/sessions/\(try id(arguments))/archive")

        case "list_archives":
            return Call(method: "GET", path: "/api/archives")

        case "list_projects":
            return Call(method: "GET", path: "/api/projects")

        default:
            throw ToolError.badArguments("unknown tool: \(name)")
        }
    }

    // MARK: - argument helpers

    private static func id(_ arguments: [String: Any]) throws -> String {
        guard let session = arguments["session"] as? String, !session.isEmpty else {
            throw ToolError.badArguments("session id is required")
        }
        // A path segment: reject anything that could escape the route.
        guard session.allSatisfy({ $0.isHexDigit || $0 == "-" }) else {
            throw ToolError.badArguments("session id must be a UUID")
        }
        return session
    }

    private static func commandIndex(_ arguments: [String: Any]) throws -> Int {
        guard let n = arguments["command"] as? Int, n >= 1 else {
            throw ToolError.badArguments("command must be a 1-based index")
        }
        return n
    }

    private static func escape(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryValueAllowed) ?? value
    }

    // MARK: - schema helpers

    // Computed, not stored: a stored `[String: Any]` global is not
    // concurrency-safe, and these are read-only schema fragments anyway.
    private static var idProp: [String: Any] { ["type": "string", "description": "Session id (UUID)"] }
    private static var labelsProp: [String: Any] {
        [
            "type": "object",
            "description": "key:value tags, e.g. {\"crew\":\"alpha\",\"task\":\"retry-bug\"}",
            "additionalProperties": ["type": "string"],
        ]
    }

    private static func tool(
        _ name: String,
        _ description: String,
        properties: [String: Any],
        required: [String] = []
    ) -> [String: Any] {
        var schema: [String: Any] = ["type": "object", "properties": properties]
        if !required.isEmpty { schema["required"] = required }
        return ["name": name, "description": description, "inputSchema": schema]
    }
}

private extension CharacterSet {
    /// Query-value safe: the general query set still allows `&` and `=`, which
    /// would split a value across parameters.
    static let urlQueryValueAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&=?")
        return set
    }()
}
