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
The adapter returns `{}` from `PreInvocation`. For `Stop` it returns
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
`fullyIdle`. It scans and discards every other JSON value without decoding it.

## State mapping

| Official event/input | Agent Watch state | Notes |
| --- | --- | --- |
| `PreInvocation` | `running` | Opens a turn or reuses the current open turn in the same conversation. |
| `Stop`, `terminationReason=model_stop`, `fullyIdle=true` | `responseEnded` | The documented normal model stop is complete only when fully idle. |
| `Stop`, `terminationReason=model_stop`, `fullyIdle=false` | `running` | Source is `antigravity:Stop:background_tasks`; the turn stays open. |
| `Stop`, `terminationReason=error` or `max_steps_exceeded` | `failed` | These documented reason examples take priority; when `fullyIdle=false`, source adds `background_pending` and the turn stays open. |
| Other `Stop` reason | `unknown` | The reason is not persisted; when `fullyIdle=false`, source adds `background_pending` and the turn stays open. |

The Hooks guide gives `model_stop`, `max_steps_exceeded`, and `error` as
examples, not as a closed enum. Mapping `error` and `max_steps_exceeded` to
`failed` is a conservative adapter inference from those reason names; Google
does not publish a host-state mapping. Known failure reasons remain `failed`
even if background tasks are pending. Unknown reasons remain `unknown` under
the same condition, rather than implying normal running. The guide does not document a cancellation reason, so
the adapter does not infer `cancelled` from strings such as `cancelled` or
`user_cancelled`; those remain `unknown`. No documented hook reports that a
conversation is waiting for user input or approval, so this adapter does not
emit either waiting state.

`PreInvocation` has no turn ID, while `executionNum` first appears in `Stop`.
The bridge creates a turn ID when the first `PreInvocation` arrives and reuses
it for subsequent invocations until a fully idle `Stop`. A `Stop` without an
open turn is ignored; `executionNum` never creates a turn by itself. A
non-idle stop keeps that same turn open for a later invocation/stop pair.

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

`--apply` merges only the two managed handlers and makes a timestamped backup
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
