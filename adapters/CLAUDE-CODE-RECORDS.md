# Claude Code session records

`claude_code_records.py` reads the `local_*.json` session metadata under
`~/Library/Application Support/Claude-3p/claude-code-sessions/*/*/` and the
equivalent `Claude` profile. It also reads a bounded tail from the matching
`~/.claude/projects/*/<cliSessionId>.jsonl` file when it needs to associate a
record with a hook turn. It never reads Claude Desktop Cowork audit files.

The metadata reader selects only `sessionId`, `cliSessionId`,
`completedTurns`, `latestUserFrameAt`, `lastTurnEdgeAt`, `lastTurnCutShort`,
`isArchived`, `errorCategory`, `errorAt`, and `lastAssistantUuid`. The journal
reader selects root `type`, `timestamp`, `promptId`, `sessionId`, `uuid`,
`parentUuid`, and `isSidechain`, plus `message.stop_reason`. Other JSON strings
are scanned only to find their boundaries; message bodies and attachment data
are not decoded or saved.

`sessionID` is the validated raw `cliSessionId`, matching Claude Code hook
events. Fresh `latestUserFrameAt` advances can emit inferred `running` with the
matching journal `promptId` (or the current hook turn ID when available).
Startup seeds the completion counter without replaying old terminal records.
An absent `completedTurns` starts at zero; an explicit null or malformed value
fails closed. A completion first observed after a newer prompt has started is
withheld rather than applied late to the old turn.
`responseEnded` requires both a new `completedTurns` value and a changed
`lastAssistantUuid`. A journal chain from that assistant UUID through
`parentUuid` must resolve to a root `promptId`; the matching assistant record
must have `message.stop_reason: "end_turn"`. Missing or ambiguous mapping
produces no completion event. A prompt-start race therefore cannot close a
newer prompt using an older assistant record.

`lastTurnCutShort` alone does not prove cancellation. A newly observed cut-short
edge on a tracked run produces `unknown`; only a fresh `errorCategory` and
`errorAt` can take failure precedence. The reader never infers completion from
idle time.

The persisted cursor is stored at
`~/Library/Application Support/Agent Watch/metadata/claude_code_records_state.json`.
It contains the validated session identifiers, selected counters and times,
the matched turn ID, sequence, and round-robin position. Output event files use
the Agent Watch private events directory. Directory and file reads reject
symbolic links; metadata and journal reads are byte-bounded and rechecked with
device, inode, size, and modification time after reading.

Each poll scans at most 64 of 500 discovered sessions, reads at most 2 MiB of
metadata and 2 MiB of journal data, and inspects no more than 256 KiB from one
journal tail. The independent checks use synthetic records:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -B Tests/check_claude_code_records.py
```

Static inspection of Claude Desktop version `4.4212.0` (build identifier
`C3r2jk0E`) confirmed the selected metadata fields and that successful results
advance `completedTurns`. A synthetic task in the real 4.4212.0 Gateway/API
desktop client, using Sonnet Low, produced `running` and then `responseEnded`
for the same journal prompt ID through this reader. A subsequent manual Stop
did not increase the success count or produce a completion event. This is
adapter-level evidence; installation, notification timing, multiple sessions,
and precise cancellation classification remain separate acceptance checks.

Some immediate Stops produce an edge timestamp slightly before the SDK's user
frame. Such cases stay unresolved instead of being classified from a clock
tolerance or from `lastTurnCutShort` alone.
