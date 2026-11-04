# Devin Local hook adapter

This adapter covers the current Devin Local agent through Devin's CLI-format command hooks. It is separate from [`devin.py`](DEVIN.md), which observes the older Devin Desktop Cascade hook protocol.

## Contract evidence

The official [Hooks reference](https://docs.devin.ai/cli/extensibility/hooks/overview) documents the user hook file `~/.config/devin/config.json`, with event groups under `hooks`, and command-hook JSON on stdin. The [Lifecycle Hooks reference](https://docs.devin.ai/cli/extensibility/hooks/lifecycle-hooks) documents the stable `session_id` and per-turn `prompt_id` fields and says the same lifecycle events run in Devin CLI and Devin Desktop. It documents `DEVIN_PROJECT_DIR` as an automatically supplied environment variable for command hooks.

The installed Devin Desktop bundle at this machine identifies as version `3.11.228` in its `Info.plist` and includes PascalCase hook definitions such as `UserPromptSubmit`, `Stop`, and `PermissionRequest`. This confirms the local app bundle contains the current hook UI/runtime vocabulary; it does not prove that an end-to-end Devin Local session fired an event. Local UI acceptance remains unverified.

Devin imports Claude Code hooks by default. Claude's official [Hooks reference](https://code.claude.com/docs/en/hooks) also documents `session_id` and `prompt_id`, so those fields alone cannot identify the host. The Claude Code installer guards its observer command with the absence of `DEVIN_PROJECT_DIR`; Devin's imported Claude hooks therefore do not create duplicate Claude-attributed observations when Devin runs them. This is based on Devin's documented host-specific environment variable, not a prompt-field guess.

## Events and privacy

| Devin hook | Monitor state | Use |
| --- | --- | --- |
| `UserPromptSubmit` | `running` | Start of a user turn |
| `PermissionRequest` | `waitingApproval` | Devin reports a tool permission decision is needed |
| `PreToolUse` | `running` | Activity resumes around a tool call |
| `PostToolUse` | `running` | Tool execution has returned |
| `Stop` | `responseEnded` | Devin decides to finish the turn |

`SessionStart` and `SessionEnd` are not registered because they do not reliably supply the current turn ID and session end is not the same as a turn ending. The adapter uses the observer's UTC receipt time because Devin's documented input has no source timestamp. Events have no sequence number because the contract does not provide an invocation counter.

The reader validates the bounded JSON input while decoding only `hook_event_name`, `session_id`, and `prompt_id`. It structurally skips `prompt`, `tool_input`, tool output, paths, and other fields without decoding their values. Hook input larger than 1 MiB is ignored after one bounded read; the observer returns success with empty stdout and stderr. The bridge emits no decision JSON, so it does not approve or block tool calls.

Only allowlisted monitor metadata is atomically written under `~/Library/Application Support/Agent Watch/events/`. Directories use mode 0700 and event files mode 0600. Permission wait clears on a later `PreToolUse`, `PostToolUse`, or `Stop`; if Devin supplies no later event, normal freshness expiry applies.

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
