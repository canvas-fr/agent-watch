# Antigravity desktop hooks

This adapter uses Antigravity's documented command hooks for the desktop app.
It records lifecycle metadata only; it does not record prompts, tool arguments,
tool error text, workspace paths, artifact paths, or transcripts.

## Official contract used

Google documents the global desktop hooks file at
`~/.gemini/config/hooks.json` and workspace hooks at `.agents/hooks.json` in
the [Antigravity Hooks guide](https://antigravity.google/docs/hooks?tab=ide).
The manager edits only the global file. Its JSON root is a map of named hook
groups. Each group can have `enabled` and lifecycle event arrays. For
`PreInvocation` and `Stop`, handlers are flat arrays of command handler objects:

```json
{
  "agent-watch-antigravity": {
    "enabled": true,
    "PreInvocation": [
      {"type": "command", "command": "...", "timeout": 1}
    ],
    "Stop": [
      {"type": "command", "command": "...", "timeout": 1}
    ]
  }
}
```

There is no `matcher` wrapper for these two events. `timeout` is in seconds.
The adapter also installs `PreToolUse` and `PostToolUse` wrappers with the exact
matcher `^ask_question$`. It reads only `toolCall.name`, skipping arguments
without decoding them. Questions and selected answers are not inspected.
The adapter returns `{}` from `PreInvocation` and `PostToolUse`. For `Stop` and
`PreToolUse` it returns
`{"decision":"allow"}`; the Hooks guide says `continue` is the value that
prevents stopping and any other decision allows the stop. It does not inject
steps or ask Antigravity to continue its loop.

Google lists the same hooks system on Antigravity App, CLI, and IDE, and the
global file is shared. The manager does not claim an app-only config scope.
This adapter is based on the official App hook contract; a CLI session is not
desktop runtime acceptance.

The documented `PreInvocation` input fields are `invocationNum` and
`initialNumSteps`, plus common fields including `conversationId`. The
documented `Stop` fields are `executionNum`, `terminationReason`, optional
`error`, and required `fullyIdle`, plus those common fields. Although hook stdin
also carries paths and may carry other private fields, the adapter parses only
`conversationId`, the relevant sequence numbers, `terminationReason`, and
`fullyIdle`, or `toolCall.name` for question hooks. It scans and discards every
other JSON value without decoding it.

## State mapping

| Event/input | Agent Watch state | Notes |
| --- | --- | --- |
| `PreInvocation` | `running` | Opens or reuses an active observation turn. |
| `PreToolUse`, `toolCall.name=ask_question` | `waitingInput` | Question interaction; requires an active turn. |
| `PostToolUse`, `toolCall.name=ask_question` | `running` | The interaction has returned. |
| `Stop`, `model_stop` or `NO_TOOL_CALL`, `fullyIdle=true` | `responseEnded` | Normal model stop, with no pending background work. |
| Same normal reasons, `fullyIdle=false` | `running` | Background work keeps the observation turn open. |
| `Stop`, `error`, `max_steps_exceeded`, `ERROR`, `MAX_INVOCATIONS`, `MAX_FORCED_INVOCATIONS`, or `MAX_TOKEN_BUDGET_EXCEEDED` | `failed` | Known error/limit reason; a retry opens a new turn. |
| `Stop`, `USER_CANCELED` | `cancelled` | Installed client's documented user-cancel reason; a retry opens a new turn. |
| Other `Stop` reason | `unknown` | Unrecognized reason text is not persisted. |

The web guide uses lowercase examples, not a closed enum. The installed 2.28.2
client's Hook Contract uses uppercase enum names. `NO_TOOL_CALL` is explicitly
normal completion; `USER_CANCELED` is user cancellation. See the
[local contract evidence](../docs/ANTIGRAVITY-CONTRACT.zh-CN.md). Error and limit
reasons map to failure as an adapter interpretation, even with pending
background work. A `background_pending` suffix then preserves that limitation.
Terminal custom hook/step and injected-response reasons remain unknown; they
are not sufficient proof of a normal response ending. Plausible lowercase
strings such as `cancelled` also remain unknown.

The question marker was verified against an actual native question display.
It does not inspect its content. There is no dedicated approval-state callback.
`ask_permission` may use a prior grant, so its invocation is not mapped to
`waitingApproval`. The observer does not choose answers or approve tools.
`PreToolUse` returns `allow`, delegating to the remaining hooks/default policy;
it never returns `auto_approve`, permission overrides, or rewritten arguments.

`PreInvocation` has no turn ID; `executionNum` appears only at `Stop`. The bridge
creates an observation turn on the first invocation and reuses it until an idle
stop or an explicit failure/cancellation. An orphan Stop or tool callback is
ignored; it cannot invent a task identity or revive a completed turn.

For hook output and event-field definitions, see the official
[Antigravity Hooks guide](https://antigravity.google/docs/hooks?tab=ide) and
[Build plugins: lifecycle hooks](https://antigravity.google/docs/build-plugins).

## Preview, install, and remove

The manager defaults to a dry run:

```sh
python3 adapters/manage_antigravity.py
python3 adapters/manage_antigravity.py --apply

python3 adapters/manage_antigravity.py --uninstall
python3 adapters/manage_antigravity.py --uninstall --apply
```

`--apply` merges only the four managed handlers and makes a timestamped backup
before changing an existing `hooks.json`. It stores a stable, owner-readable
copy at `~/Library/Application Support/Agent Watch/bridge/antigravity.py` and
uses that copy in the hook commands. It preserves other named groups, event
handlers, and group settings. If the preferred hook-group name is already used
by an unowned group, it selects a free numbered name. If the stable bridge path
already contains a file without the Agent Watch ownership marker, the manager
stops rather than replacing it.

Uninstall removes only command handlers carrying the Agent Watch ownership
marker. It leaves other handlers, configuration, the bridge copy, event files,
and turn metadata in place. The parent task is responsible for any real
`--apply` and desktop runtime acceptance; the fixture tests use temporary home
directories only.

## Runtime and data limits

- Hook stdin is capped at 1 MiB. Oversized or malformed input fails open and
  emits no lifecycle event.
- Session metadata writes use a non-blocking file lock with a 0.1-second limit.
  If another writer holds it, the hook skips the event.
- Hook handler timeout is 1 second. The adapter never contacts a server or
  reads a transcript.
- Events and the minimal conversation/turn/sequence state are written under
  `~/Library/Application Support/Agent Watch/` with private directory/file
  permissions.

Run the fixtures with:

```sh
python3 Tests/check_antigravity.py
```
