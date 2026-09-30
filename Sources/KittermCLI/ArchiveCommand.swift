import Foundation
import KittermDaemon

/// `kitterm archive cost <id> [--line|--json]` — the bill of one archived
/// session, read from the state directory with no daemon: the archive's
/// join (`SessionArchive.agentJoin(of:)`, under `DaemonPaths.archiveDirectory`,
/// so `KITTERM_STATE_DIR` moves it) names the transcript, and
/// `TranscriptBill.read` reads its last `cost-state` line. This is the pair
/// `GoalLedger.bills(for:)` reads with, and the sums are
/// `GoalLedger.SessionBill`'s, so the ledger and this command never
/// disagree on a number.
///
/// `--line` (the default) prints the round record's line as `LOOP.md`
/// ("The round record") defines it:
///
///     - Cost: $D · Nk in (C% cached) · Nk out · Hh Mm
///
/// `$D` is `totalCostUSD` to the cent; `Nk in` is `inputTokens` plus
/// `cacheCreationInputTokens` plus `cacheReadInputTokens` over every model,
/// to whole thousands; `C%` is the summed `cacheReadInputTokens` over `in`,
/// to a whole percent; `Nk out` is `outputTokens`, to whole thousands;
/// `Hh Mm` is `totalDuration` to whole minutes. When there is no bill, the
/// line reads `- Cost: none recorded (<reason>)` with the reason the route
/// gives: `no such archive`, `no transcript`, `transcript not found`, or the
/// transcript's own reason (`noCostStateLine`, `lastLineIncomplete`,
/// `lastLineTooLong`, `costStateMalformed`). The foreman pastes the line
/// under the record's header, one per session in `Sessions:` order.
///
/// `--json` prints what `GET /api/archives/<id>/cost` answers: `ok`,
/// `hasBill`, `agentSessionId`, `agentTranscript`, and `bill` with the
/// transcript's own field names unrounded, or `reason` without a bill. An
/// archived session has exited, so there is no running estimate.
///
/// The exit status says whether the archive answered: 0 for a bill and for
/// a transcript that holds none (the `none recorded` line is the answer the
/// record wants), 1 when the id is not a UUID, the archive is missing, it
/// has no join, or its transcript does not open, with the id and the path
/// on stderr. The line still prints on stdout in those cases, so a foreman
/// that ignores the status still gets a line it can paste.
enum ArchiveCommand {
    static let usage = "usage: kitterm archive cost <id> [--line | --json]"

    enum Format { case line, json }

    /// Run one subcommand. `out` takes every line meant for stdout.
    static func run<S: Sequence>(_ args: S, out: (String) -> Void = { print($0) }) throws
    where S.Element == String {
        let array = Array(args)
        switch array.first {
        case "cost":
            try cost(Array(array.dropFirst()), out: out)
        default:
            throw CLIError.usage(usage)
        }
    }

    // MARK: - The answer

    /// What the archive answered for `id`: the route's four outcomes.
    enum Answer: Equatable {
        case bill(TranscriptBill, AgentJoin)
        /// The transcript opened and holds no bill; `reason` is
        /// `TranscriptBill.NoBill`'s raw value.
        case noBill(reason: String, AgentJoin)
        case noTranscript
        /// The archive names a transcript that does not open; `detail` is
        /// what the read said.
        case transcriptNotFound(AgentJoin, detail: String)
        case noSuchArchive
    }

    /// Read the archive `id` under the state directory. The same lookup the
    /// route makes, on the caller's thread: one small `archive.json`, then
    /// one `pread` of the transcript's tail.
    static func answer(for id: UUID) -> Answer {
        guard SessionArchive.exists(id) else { return .noSuchArchive }
        guard let join = SessionArchive.agentJoin(of: id) else { return .noTranscript }
        switch TranscriptBill.read(path: join.transcriptPath) {
        case .bill(let bill): return .bill(bill, join)
        case .noBill(let why): return .noBill(reason: why.rawValue, join)
        case .unreadable(let detail): return .transcriptNotFound(join, detail: detail)
        }
    }

    // MARK: - The line

    /// `- Cost: $D · Nk in (C% cached) · Nk out · Hh Mm` from a bill, with
    /// `LOOP.md`'s rounding.
    static func costLine(_ bill: TranscriptBill) -> String {
        let sums = GoalLedger.SessionBill(bill: bill)
        let percent = sums.inTokens > 0
            ? Int((100 * Double(sums.cacheRead) / Double(sums.inTokens)).rounded())
            : 0
        let minutes = Int((Double(bill.totalDuration) / 60_000).rounded())
        return String(
            format: "- Cost: $%.2f · %dk in (%d%% cached) · %dk out · %dh %02dm",
            bill.totalCostUSD, thousands(sums.inTokens), percent, thousands(sums.outTokens),
            minutes / 60, minutes % 60
        )
    }

    /// `- Cost: none recorded (<reason>)`.
    static func noneRecordedLine(_ reason: String) -> String {
        "- Cost: none recorded (\(reason))"
    }

    /// A token count to whole thousands: 1,100,502 is `1101`.
    static func thousands(_ count: Int) -> Int {
        Int((Double(count) / 1000).rounded())
    }

    /// The line for an answer, whatever it was.
    static func line(for answer: Answer) -> String {
        switch answer {
        case .bill(let bill, _): return costLine(bill)
        case .noBill(let reason, _): return noneRecordedLine(reason)
        case .noTranscript: return noneRecordedLine("no transcript")
        case .transcriptNotFound: return noneRecordedLine("transcript not found")
        case .noSuchArchive: return noneRecordedLine("no such archive")
        }
    }

    // MARK: - The JSON

    /// The route's body: `CostResponse` in `HTTPAPIHandler`, less the
    /// running estimate an archive never has.
    struct CostJSON: Encodable {
        let ok: Bool
        let hasBill: Bool?
        let agentSessionId: String?
        let agentTranscript: String?
        let reason: String?
        let bill: TranscriptBill?
        let error: String?
        let detail: String?
    }

    static func json(for answer: Answer) throws -> String {
        let body: CostJSON
        switch answer {
        case .bill(let bill, let join):
            body = CostJSON(
                ok: true, hasBill: true, agentSessionId: join.sessionID, agentTranscript: join.transcriptPath,
                reason: nil, bill: bill, error: nil, detail: nil
            )
        case .noBill(let reason, let join):
            body = CostJSON(
                ok: true, hasBill: false, agentSessionId: join.sessionID, agentTranscript: join.transcriptPath,
                reason: reason, bill: nil, error: nil, detail: nil
            )
        case .noTranscript:
            body = CostJSON(
                ok: false, hasBill: nil, agentSessionId: nil, agentTranscript: nil,
                reason: nil, bill: nil, error: "no transcript", detail: nil
            )
        case .transcriptNotFound(let join, let detail):
            body = CostJSON(
                ok: false, hasBill: nil, agentSessionId: nil, agentTranscript: join.transcriptPath,
                reason: nil, bill: nil, error: "transcript not found", detail: detail
            )
        case .noSuchArchive:
            body = CostJSON(
                ok: false, hasBill: nil, agentSessionId: nil, agentTranscript: nil,
                reason: nil, bill: nil, error: "no such archive", detail: nil
            )
        }
        let encoder = JSONEncoder()
        // The route's formatting: sorted keys, slashes in the path as they are.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(body), as: UTF8.self)
    }

    // MARK: - The command

    /// Why the command exits 1 after it printed its line: the id, and the
    /// path when there is one, so the message names what to look at.
    enum Failure: Error, LocalizedError, Equatable {
        case noSuchArchive(UUID)
        case noTranscript(UUID)
        case transcriptNotFound(UUID, path: String, detail: String)

        var errorDescription: String? {
            let archives = DaemonPaths.archiveDirectory.path
            switch self {
            case .noSuchArchive(let id):
                return "no such archive \(id.uuidString) under \(archives)"
            case .noTranscript(let id):
                return "archive \(id.uuidString) under \(archives) has no transcript join (the session never ran claude)"
            case .transcriptNotFound(let id, let path, let detail):
                return "archive \(id.uuidString): transcript not found at \(path): \(detail)"
            }
        }
    }

    static func cost(_ args: [String], out: (String) -> Void) throws {
        var id: String?
        var format = Format.line
        for arg in args {
            switch arg {
            case "--line": format = .line
            case "--json": format = .json
            case _ where arg.hasPrefix("-"):
                throw CLIError.usage("unknown option \(arg)\n\(usage)")
            default:
                guard id == nil else { throw CLIError.usage(usage) }
                id = arg
            }
        }
        guard let id else { throw CLIError.usage(usage) }
        guard let uuid = UUID(uuidString: id) else {
            throw CLIError.usage("not an archive id (a UUID): \(id)")
        }
        let answer = answer(for: uuid)
        switch format {
        case .line: out(line(for: answer))
        case .json: out(try json(for: answer))
        }
        switch answer {
        case .bill, .noBill: return
        case .noSuchArchive: throw Failure.noSuchArchive(uuid)
        case .noTranscript: throw Failure.noTranscript(uuid)
        case .transcriptNotFound(let join, let detail):
            throw Failure.transcriptNotFound(uuid, path: join.transcriptPath, detail: detail)
        }
    }
}
