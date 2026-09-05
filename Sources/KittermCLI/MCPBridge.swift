#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import KittermDaemon

/// `kitterm mcp` — a stdio MCP server that turns kitterm's HTTP API into a
/// foreman toolset for any MCP-capable agent (`claude mcp add kitterm --
/// kitterm mcp`).
///
/// JSON-RPC 2.0 over stdio, newline-delimited (one message per line, the MCP
/// stdio transport). Blocking reads and a synchronous HTTP client are fine
/// here: this is a short-lived CLI process, not the daemon's event loop.
enum MCPBridge {
    static let protocolVersion = "2025-06-18"

    /// Run until stdin closes. `port` is the daemon's HTTP port.
    static func run(port: Int) {
        let client = MCPHTTPClient(port: port)
        while let line = readLine(strippingNewline: true) {
            if line.isEmpty { continue }
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            else {
                // A line we cannot parse has no id to answer to; the spec says
                // ignore it rather than guess.
                continue
            }
            handle(message, client: client)
        }
    }

    private static func handle(_ message: [String: Any], client: MCPHTTPClient) {
        let method = message["method"] as? String
        // A request has an id; a notification does not and gets no reply.
        let id = message["id"]

        switch method {
        case "initialize":
            respond(id: id, result: [
                "protocolVersion": protocolVersion,
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "kitterm", "version": BuildVersion.running],
            ])
        case "notifications/initialized", "notifications/cancelled":
            break  // notifications: no response
        case "ping":
            respond(id: id, result: [:] as [String: Any])
        case "tools/list":
            respond(id: id, result: ["tools": MCPTools.schemas()])
        case "tools/call":
            handleToolCall(id: id, params: message["params"] as? [String: Any] ?? [:], client: client)
        default:
            if id != nil {
                respondError(id: id, code: -32601, message: "method not found: \(method ?? "nil")")
            }
        }
    }

    private static func handleToolCall(id: Any?, params: [String: Any], client: MCPHTTPClient) {
        guard let name = params["name"] as? String else {
            respondError(id: id, code: -32602, message: "missing tool name")
            return
        }
        let arguments = params["arguments"] as? [String: Any] ?? [:]
        let call: MCPTools.Call
        do {
            call = try MCPTools.call(named: name, arguments: arguments)
        } catch let MCPTools.ToolError.badArguments(reason) {
            respond(id: id, result: toolResult(text: "invalid arguments: \(reason)", isError: true))
            return
        } catch {
            respond(id: id, result: toolResult(text: "invalid arguments", isError: true))
            return
        }

        let result = client.send(call)
        switch result {
        case .success(let status, let headers, let data):
            // 2xx is a tool success; anything else is a tool error whose body
            // carries the reason — including the daemon's own 403 that names
            // `--agent-control`, so the agent reads the fix verbatim.
            let ok = (200..<300).contains(status)
            if ok, let screen = call.screen {
                // The one tool whose answer is not the daemon's body: the
                // bytes are rendered here, in the bridge, never in the daemon.
                do {
                    let text = try ScreenReport.text(data: data, headers: headers, options: screen)
                    respond(id: id, result: toolResult(text: text, isError: false))
                } catch {
                    respond(
                        id: id,
                        result: toolResult(
                            text: "the daemon did not report the pane size; upgrade kitterm (kitterm upgrade)",
                            isError: true
                        )
                    )
                }
                return
            }
            let body = String(decoding: data, as: UTF8.self)
            let text = body.isEmpty ? "(\(status))" : body
            respond(id: id, result: toolResult(text: text, isError: !ok))
        case .failure(let reason):
            respond(
                id: id,
                result: toolResult(
                    text: "cannot reach the kitterm daemon: \(reason). Is it running? (kitterm status)",
                    isError: true
                )
            )
        }
    }

    // MARK: - JSON-RPC framing

    private static func toolResult(text: String, isError: Bool) -> [String: Any] {
        [
            "content": [["type": "text", "text": text]],
            "isError": isError,
        ]
    }

    private static func respond(id: Any?, result: [String: Any]) {
        guard let id else { return }  // never answer a notification
        writeMessage(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private static func respondError(id: Any?, code: Int, message: String) {
        guard let id else { return }
        writeMessage(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    /// One JSON object per line on stdout. `withoutEscapingSlashes` keeps paths
    /// readable; the object must never contain a raw newline, which
    /// `JSONSerialization` guarantees for string values.
    private static func writeMessage(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.withoutEscapingSlashes]
        ) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

/// A minimal synchronous HTTP client for the loopback daemon. `URLSession`
/// plus a semaphore, the same shape `KittermMain.isHealthy` uses.
struct MCPHTTPClient {
    let port: Int

    enum Result {
        /// Headers keyed as the server sent them; look them up
        /// case-insensitively. The body stays bytes: the output routes serve
        /// `application/octet-stream`, and a screen render must see them all.
        case success(status: Int, headers: [String: String], data: Data)
        case failure(String)
    }

    func send(_ call: MCPTools.Call) -> Result {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(call.path)") else {
            return .failure("bad path")
        }
        var request = URLRequest(url: url, timeoutInterval: 320)
        request.httpMethod = call.method
        request.setValue("127.0.0.1:\(port)", forHTTPHeaderField: "Host")
        if let raw = call.rawBody {
            request.httpBody = raw
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        } else if let json = call.jsonBody {
            request.httpBody = try? JSONSerialization.data(withJSONObject: json)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Result = .failure("no response")
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            defer { sem.signal() }
            if let error {
                outcome = .failure(error.localizedDescription)
                return
            }
            guard let http = response as? HTTPURLResponse else {
                outcome = .failure("no HTTP response")
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name] = value }
            }
            outcome = .success(status: http.statusCode, headers: headers, data: data ?? Data())
        }
        task.resume()
        // Just past the daemon's own long-poll ceiling (300s), so a
        // wait_for_command / wait_for_events that runs to its deadline still
        // gets its answer rather than a client-side cancellation.
        if sem.wait(timeout: .now() + 330) == .timedOut {
            task.cancel()
            return .failure("request timed out")
        }
        return outcome
    }
}
