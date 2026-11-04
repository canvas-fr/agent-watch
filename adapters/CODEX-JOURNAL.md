# Codex lifecycle journal

`codex_rollouts.py` reads the local `state_5.sqlite` index in read-only mode and
projects lifecycle records from the indexed rollout journals. The index query
selects only thread ID, rollout location and an available parent ID. It never
selects titles, previews, prompts or credentials. Output stores only opaque IDs,
state, timestamp, source and parent relationship; cursor paths are hashed.

The selective JSON scanner reads `type`, `timestamp`, the turn ID and a terminal
error-presence flag. Message text, tool arguments and error descriptions are
structurally skipped without decoding their values. It accepts `task_started`
and `task_complete` and their `turn_*` aliases. A completed turn with a terminal
error maps to failed. A documented interrupted turn maps to cancelled, or failed
when accompanied by an explicit terminal error; unknown abort reasons stay
unclassified.

This is downstream of a Stop hook. The public Codex implementation
[continues the turn when a Stop hook requests continuation](https://github.com/openai/codex/blob/007f668c34cca4b9c36ca7ddc08066897f2bbabc/codex-rs/core/src/session/turn.rs#L759),
and its task lifecycle
[emits TurnComplete as the terminal event](https://github.com/openai/codex/blob/007f668c34cca4b9c36ca7ddc08066897f2bbabc/codex-rs/core/src/tasks/mod.rs#L943).
The [protocol definition](https://github.com/openai/codex/blob/007f668c34cca4b9c36ca7ddc08066897f2bbabc/codex-rs/protocol/src/protocol.rs#L2413)
defines the optional terminal error and the per-turn identity. Those references
pin the reviewed source revision; the installed desktop journal was separately
observed to contain the same `task_started` / `task_complete` metadata shape.
The monitor normalizes older `codex:Stop` and `codex:SubagentStop` bridge events
to unknown pending journal confirmation, so continuation can update the same turn.

Each poll has a time/byte budget and rotates across up to 256 indexed threads.
Partial appends are retried, oversized records are skipped, and emitted event
IDs are deterministic. A first scan does not replay historical start/end pairs.
The monitor can retain a historical final snapshot silently, then receive new
activity through the incremental cursor. Missing files, unknown schemas and
truncated evidence do not imply completion. The hooks still provide prompt,
tool and permission activity that may be absent from the recent journal tail.

Agent Watch 0.3 packages and runs the reader in an independent background lane.
It does not start a Codex server or model turn, modify Codex configuration, or
connect to undocumented sockets. Python 3 is required.

```sh
python3 adapters/codex_rollouts.py --once
python3 adapters/codex_rollouts.py --watch
python3 Tests/check_codex_rollouts.py
```
