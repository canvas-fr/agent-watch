# Claude Desktop local Chat / Cowork reader

`claude_desktop.py` is a read-only, metadata-only prototype for Claude
Desktop's local agent-mode store. Static inspection of the installed Claude
app's package version `4.4212.0` confirmed the path and audit schema markers
used here. A local Gateway/API Cowork session on that version has also been
verified for new prompt activity and an explicit successful result. This does
not establish acceptance of every mode or background scenario. Other versions
may run only when the same expected metadata and audit
record shapes are present. Unknown session types and malformed records fail
closed.

The reader supports the store's `sessionType: "chat"` and
`sessionType: "cowork"` records, plus records without `sessionType` (treated
as Cowork). It does not establish coverage of ordinary cloud Chat conversations
that are absent from `local-agent-mode-sessions`.

Both `~/Library/Application Support/Claude/local-agent-mode-sessions` and
the Gateway profile `Claude-3p/local-agent-mode-sessions` are checked. Their
session namespaces stay separate. Alongside the full `local_<uuid>` directory,
the reader accepts the observed eight-character UUID directory only when a
single metadata record owns that prefix. A collision remains unobserved;
no two chats are merged. Symbolic-link roots, folders, and logs are rejected.

It reads only `sessionId`, `sessionType`, `isArchived`, and `lastActivityAt`
from each `local_<id>.json` metadata file. From `audit.jsonl`, it selects the
event `type` / `subtype`, `tool_name` only to distinguish `AskUserQuestion`,
`is_error`, `terminal_reason`, and the main-agent parent marker. It never
decodes or stores message text, prompt text, tool input, result text, titles,
paths, or permission decisions. Audit JSON string values outside this allowlist
are skipped by a bounded lexical reader. The `.claude/projects` transcript
files are never opened.

Mappings:

- A user prompt, `init`, main-agent output, or permission response gives an
  inferred `running` state.
- A `permission_request` gives `waitingApproval`; `AskUserQuestion` gives
  `waitingInput`.
- A `result` with `subtype: "success"` and `is_error: false` gives
  `responseEnded`.
- A result with an `aborted_…` terminal reason gives `cancelled`; an error
  result gives `failed`. An unclassified result gives `unknown`.
- Tool-result user records and subagent assistant records do not change the
  parent session state.

The reader writes standard MonitorEvent JSON files under Agent Watch's private
`events/` directory and stores only opaque session hashes, audit inode/offset,
state, turn ID, selected metadata timestamps, and a round-robin cursor in
`metadata/claude_desktop_state.json`. Event IDs are deterministic from the
session hash, audit generation, record offset, state, and turn ID, so repeated
`--once` scans do not replay the same notification. A bootstrap emits at most
one inferred current nonterminal snapshot; terminal history is only used to
seed the cursor, so installing or restarting the reader does not create an
unread-completion count from an old result.

Each scan rotates through at most 64 sessions, reading at most 2 MiB of changed
session metadata and 4 MiB of audit data in total. The metadata cache and
round-robin position persist across `--once` process launches; large stores
make bounded progress across scans instead of repeatedly reading every log.

Run one scan or keep a poller running:

```sh
python3 adapters/claude_desktop.py --once
python3 adapters/claude_desktop.py --watch
```

The default poll interval is 0.5 seconds. Console output is a fixed-field JSON
health summary; it never includes paths, raw audit lines, or exception text.
This reader does not modify Claude configuration, inject into the app, or
perform UI actions.

In the real Gateway/API Cowork check, manual Stop exposed the exact native
status `Claude’s response was interrupted.` but no terminal audit result.
The audit reader alone therefore cannot close that case. The native monitor
has a Cowork-only supplement that requires a continuous run in the same
window/route and joins the interruption to an audit turn observed during that
run. A cold label, an old cursor, or a changed turn remains unknown. This
supplement has fixture coverage; its installed native acceptance is pending.

Implementation evidence: the installed Claude `4.4212.0` package statically
contains the `local-agent-mode-sessions` store and audit record markers. A read-only public
implementation reference is [CodeIsland v1.0.41 at commit
03c77e9](https://github.com/wxtsky/CodeIsland/tree/03c77e9457f0adc56fa036caf4925e4a576b453b),
especially its [Cowork session metadata model](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/Sources/CodeIslandCore/CoworkSession.swift),
[audit event reducer](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/Sources/CodeIslandCore/CoworkAuditLog.swift),
and [read-only watcher](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/Sources/CodeIsland/CoworkSessionWatcher.swift).
The third-party source documents local Cowork and local `chat` session records;
it is implementation evidence, not an Anthropic-published contract.

The referenced CodeIsland commit carries an MIT license with Copyright (c)
2026 wxtsky in its [LICENSE](https://github.com/wxtsky/CodeIsland/blob/03c77e9457f0adc56fa036caf4925e4a576b453b/LICENSE).
This adapter was independently written against the field names and status
semantics documented by that source and the installed package. It does not
translate or copy CodeIsland implementation code; no CodeIsland source is
redistributed here.
