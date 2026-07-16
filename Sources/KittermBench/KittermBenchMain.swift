import Foundation
import KittermProtocol

@main
enum KittermBenchMain {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        if args.contains("-h") || args.contains("--help") {
            printUsage()
            return
        }

        var scenario = "all"
        var port = readDefaultPort()

        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--scenario", i + 1 < args.count {
                scenario = args[i + 1]
                i += 2
                continue
            }
            if arg.hasPrefix("--scenario=") {
                scenario = String(arg.dropFirst("--scenario=".count))
                i += 1
                continue
            }
            if arg == "--port", i + 1 < args.count, let value = Int(args[i + 1]) {
                port = value
                i += 2
                continue
            }
            if arg.hasPrefix("--port="), let value = Int(arg.dropFirst("--port=".count)) {
                port = value
                i += 1
                continue
            }
            if !arg.hasPrefix("-") {
                scenario = arg
                i += 1
                continue
            }
            fputs("unknown argument: \(arg)\n", stderr)
            printUsage()
            exit(2)
        }

        guard isHealthy(port: port) else {
            fputs(
                """
                error: no healthy kitterm daemon on 127.0.0.1:\(port)
                Start one first:  swift run kitterm start --port \(port)

                """,
                stderr
            )
            exit(1)
        }

        fputs("KittermBench → ws://127.0.0.1:\(port)/ws  scenario=\(scenario)\n", stdout)
        fflush(stdout)

        let box = ResultBox()
        let sem = DispatchSemaphore(value: 0)
        // Detached so we don't deadlock: main thread waits on the semaphore.
        Task.detached {
            do {
                let result = try await Scenarios.run(scenario, port: port)
                box.result = .success(result)
            } catch {
                box.result = .failure(error)
            }
            sem.signal()
        }
        sem.wait()

        switch box.result {
        case .success(let result):
            for line in result.lines {
                print(line)
            }
            print(result.ok ? "RESULT: PASS" : "RESULT: FAIL")
            fflush(stdout)
            exit(result.ok ? 0 : 1)
        case .failure(let error):
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        case .none:
            fputs("error: bench produced no result\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print(
            """
            KittermBench — daemon binary-protocol regression harness

            Usage:
              swift run KittermBench [--port PORT] [--scenario NAME]
              swift run KittermBench interactive-echo
              swift run KittermBench TUI-redraw
              swift run KittermBench large-burst
              swift run KittermBench all

            Scenarios:
              interactive-echo  keystroke → echo RTT (p50/p95/p99)
              TUI-redraw        synthetic full-screen ANSI redraw throughput
              large-burst       megabyte flood + slow-drain backpressure
              all               run every scenario (default)

            Requires a running daemon (`kitterm start`). Default port: \(KittermConstants.defaultPort)
            (or ~/.kitterm/port when present).
            """
        )
    }

    private static func readDefaultPort() -> Int {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let portFile = home.appendingPathComponent(".kitterm/port")
        if let text = try? String(contentsOf: portFile, encoding: .utf8),
           let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return value
        }
        return KittermConstants.defaultPort
    }

    private static func isHealthy(port: Int) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/api/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1
        let semaphore = DispatchSemaphore(value: 0)
        let flag = AtomicBool()
        URLSession.shared.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true
            else { return }
            flag.value = true
        }.resume()
        _ = semaphore.wait(timeout: .now() + 2)
        return flag.value
    }
}

private final class ResultBox: @unchecked Sendable {
    var result: Result<ScenarioResult, Error>?
}

private final class AtomicBool: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
