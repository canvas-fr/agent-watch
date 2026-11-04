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
`parentUuid`, `isSidechain`, `origin`, `isMeta`, `isAbortedMidStream`,
`toolUseResult`, and `version`, plus `message.role`, `message.id`, and
`message.stop_reason`.
For message content, it reads block types and compares raw JSON string bytes
only to the exact interruption marker literals; it caps this scan at 32 blocks
per message, and message bodies and attachment data are never decoded or saved.

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
idle time. A specific cancellation is accepted only from a single text block
whose raw JSON string exactly matches `[Request interrupted by user]`, on a
main-thread user record with no `origin` or `toolUseResult`. The marker must
share the current human prompt ID and CLI session, and its direct `parentUuid`
must identify an assistant record with `isAbortedMidStream: true`, a message
ID, and an explicitly null `message.stop_reason`. `isSidechain` must be false
for every record in that chain. The human prompt, parent assistant, and marker
must each have top-level `version: "2.1.309"`; a missing or different version
fails closed for cancellation and does not affect the normal completion-counter
rule. A later human-origin prompt in the journal invalidates a marker for the
older prompt, even if that marker appeared earlier in the same tail and before
the metadata frame updates. The projector and reducer both check the final
human prompt observed in the bounded tail. On a later poll, if the original
human frame has fallen outside the bounded tail, the exact prompt ID and
version verification already mapped to the still-active cursor may anchor the
match; the metadata frame must still be the same frame as the tracked run.
The `[Request interrupted by user for tool use]` marker and
tool-result denials do not cancel the whole turn. Quoted or embedded marker
text is not sufficient.

The accepted cancellation shape is bound to the per-record CLI version
`2.1.309` found in the one named test journal, paired with Claude Desktop
`4.4212.0`. An earlier POC summary labeled the executable `2.1.296`, but its
selected root records report `2.1.309`; this reader follows the per-record
metadata. It does not query the installed CLI binary, and this evidence does
not establish compatibility with other CLI versions. Missing versions and
other versions, including `2.1.296`, are unverified and fail closed for
cancellation; normal completion-counter checks remain separate.

For a schema-1 cursor written before the per-record version flag existed, one
migration fallback can use a fresh interruption marker (no older than 30
seconds) when its exact prompt ID matches the still-active cursor and the
direct parent assistant and marker both carry version `2.1.309`. If the human
prompt is still visible in the tail, its version must also match. The
transition writes the opaque replay signature and clears the legacy flag, so
restart does not replay it. The monitor treats `cancelled` as terminal without
a default user notification.

While a run remains tracked as active, each poll may inspect its journal tail
even when `completedTurns` and `lastAssistantUuid` have not changed. The reader
caps these checks at eight journal files and 2 MiB total per poll, with at most
256 KiB per file and 5,000 JSONL records per lookup. If a message exceeds the
block cap, marker matching fails closed while the separate stop-reason end-turn
check remains available. No running state is generated from journal
modification time.
A marker already present during bootstrap is recorded as an opaque replay
signature and does not create a new cancellation event. A successful
`completedTurns` plus matching `end_turn` result still takes precedence.

The persisted cursor is stored at
`~/Library/Application Support/Agent Watch/metadata/claude_code_records_state.json`.
It contains the validated session identifiers, selected counters and times,
the matched turn ID, sequence, an opaque interruption replay signature, a
boolean indicating whether the tracked prompt version was verified, a
temporary schema-migration flag for eligible old cursors, and the round-robin
position. Output event files use the Agent Watch private events
directory. Directory and file reads reject symbolic links; metadata and journal
reads are byte-bounded and rechecked with device, inode, size, and modification
time after reading.

Each poll scans at most 64 of 500 discovered sessions, reads at most 2 MiB of
metadata and 2 MiB of journal data, performs at most eight journal lookups, and
inspects no more than 256 KiB from one journal tail. The independent checks use
synthetic records:

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
frame. That timestamp alone remains unclassified; cancellation is emitted only
if the same current prompt also satisfies the journal-marker contract above.
