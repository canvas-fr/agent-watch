# Devin Local hook adapter

This adapter covers the current Devin Local agent through Devin's CLI-format command hooks. It is separate from [`devin.py`](DEVIN.md), which observes the older Devin Desktop Cascade hook protocol.

## Contract evidence

The official [Hooks reference](https://docs.devin.ai/cli/extensibility/hooks/overview) documents the user hook file `~/.config/devin/config.json`, with event groups under `hooks`, and command-hook JSON on stdin. The [Lifecycle Hooks reference](https://docs.devin.ai/cli/extensibility/hooks/lifecycle-hooks) documents the stable `session_id` and per-turn `prompt_id` fields and says the same lifecycle events run in Devin CLI and Devin Desktop. It documents `DEVIN_PROJECT_DIR` as an automatically supplied environment variable for command hooks.

The installed Devin Desktop bundle at this machine identifies as version `3.11.228` in its `Info.plist` and includes PascalCase hook definitions such as `UserPromptSubmit`, `Stop`, and `PermissionRequest`. A fixed short reply in the native Devin Local UI has now produced a live `Stop` event with matching session and turn IDs. This confirms that the hook path fires for that case; it does not establish that every `Stop` becomes a completed turn.

Devin imports Claude Code hooks by default. Claude's official [Hooks reference](https://code.claude.com/docs/en/hooks) also documents `session_id` and `prompt_id`, so those fields alone cannot identify the host. The Claude Code installer guards its observer command with the absence of `DEVIN_PROJECT_DIR`; Devin's imported Claude hooks therefore do not create duplicate Claude-attributed observations when Devin runs them. This is based on Devin's documented host-specific environment variable, not a prompt-field guess.

## Events and privacy

| Devin hook | Monitor state | Use |
| --- | --- | --- |
| `UserPromptSubmit` | `running` | Start of a user turn |
| `PermissionRequest` | `waitingApproval` | Devin reports a tool permission decision is needed |
| `PreToolUse` | `running` | Activity resumes around a tool call |
| `PostToolUse` | `running` | Tool execution has returned |
| `Stop` | `unknown` | Observed stop intent; source is `devin_local:Stop:awaiting_confirmation` |

Devin documents `Stop` as firing when the agent decides to stop, and says a Stop hook can prevent premature stopping. Another registered hook may therefore block the stop after Agent Watch observes it. The adapter keeps `evidence=explicit` to mean that the Stop callback itself was directly observed, while the resulting state remains `unknown`; it does not report `responseEnded` or lock the turn as terminal. A later same-turn `PreToolUse` or `PermissionRequest` can still update the state. Confirmation of a broadly reliable final-response signal remains pending.

`SessionStart` and `SessionEnd` are not registered because they do not reliably supply the current turn ID and session end is not the same as a turn ending. The adapter uses the observer's UTC receipt time because Devin's documented input has no source timestamp. Events have no sequence number because the contract does not provide an invocation counter.

The reader validates the bounded JSON input while decoding only `hook_event_name`, `session_id`, and `prompt_id`. It structurally skips `prompt`, `tool_input`, tool output, paths, and other fields without decoding their values. Hook input larger than 1 MiB is ignored after one bounded read; the observer returns success with empty stdout and stderr. The bridge emits no decision JSON, so it does not approve or block tool calls.

Only allowlisted monitor metadata is atomically written under `~/Library/Application Support/Agent Watch/events/`. Directories use mode 0700 and event files mode 0600. Permission wait clears on a later `PreToolUse`, `PostToolUse`, or `Stop`; a `Stop` changes the current state to unknown pending confirmation, not to a completed turn. If Devin supplies no later event, normal freshness expiry applies.

## Installer

`manage_devin_local.py` defaults to a read-only dry run. Apply explicitly to edit only `~/.config/devin/config.json`; an existing config is backed up, unrelated hook entries are preserved, and uninstall removes only marked handlers. Devin supports JSON comments, but this installer refuses commented JSON rather than silently dropping comments during serialization. Nonstandard constants such as `NaN` and `Infinity` are also rejected.

The stable bridge copy is `~/Library/Application Support/Agent Watch/bridge/devin_local.py`. It has the ownership marker `agent-watch-bridge-owner: devin-local-v1` in its first 512 bytes. A different existing file at that path is treated as user-owned and is never replaced.

```sh
python3 adapters/manage_devin_local.py
python3 adapters/manage_devin_local.py --apply
python3 adapters/manage_devin_local.py --uninstall
python3 adapters/manage_devin_local.py --uninstall --apply

python3 Tests/check_devin_local.py
```

Fixture checks use temporary homes. No live Devin Local task or user hook configuration is changed by the test suite.

The current test machine registers only this modern observer. Its old Cascade observer was removed after the compatibility callbacks were observed on the same session/turn. Existing sessions may retain cached hook definitions: verify changed registrations in a fresh session. See the project release report for the sanitized real-client evidence.

Native 3.11.228 acceptance also observed PermissionRequest while its approval card was visible, then cleared the waiting state after the test rejected the request. The expected denial reply appeared; no extra write scope was granted. A separate Stop-block test produced two native replies, while both legacy post callbacks arrived before their respective Stop decisions. The modern observer stayed unknown and created no completion record or terminal notice for that test. Approval-granted recovery, cancellation, failure and the full background matrix remain unverified.
