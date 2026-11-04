# Devin Desktop: legacy Cascade hooks

This adapter covers **legacy Cascade in Devin Desktop (formerly Windsurf)**. It does not claim support for Devin Local's migrated hook contract or for Devin CLI sessions.

## Evidence and contract

The official [historical Cascade Hooks reference](https://docs.windsurf.com/de/windsurf/cascade/hooks) documents the user-level file `~/.codeium/windsurf/hooks.json`, with hooks under a top-level `hooks` object. The original English URL, [docs.windsurf.com/windsurf/cascade/hooks](https://docs.windsurf.com/windsurf/cascade/hooks), now redirects to Devin Local customizations. The current [Devin Desktop legacy Cascade reference](https://docs.devin.ai/desktop/cascade) retains the legacy Cascade surface. In the installed Devin bundle, `extensions/windsurf/bin/language_server_macos_arm` contains the legacy action names `HOOK_AGENT_ACTION_PRE_USER_PROMPT`, `HOOK_AGENT_ACTION_POST_CASCADE_RESPONSE`, and `HOOK_AGENT_ACTION_POST_CASCADE_RESPONSE_WITH_TRANSCRIPT`, plus the payload fields `agent_action_name`, `trajectory_id`, `execution_id`, `timestamp`, `tool_info`, and `transcript_path`.

The official event list has `pre_user_prompt` and `post_cascade_response`; it has no `post_user_prompt`. `pre_user_prompt` carries the user prompt in `tool_info.user_prompt`. `post_cascade_response` carries response text in `tool_info.response`. The transcript variant is intentionally not installed.

A native Devin Local Stop-blocking experiment showed that `post_cascade_response` is not a reliable turn-end confirmation for that runtime: the callback arrived about 0.22 seconds before a blocked Stop decision and about 0.18 seconds before a later allowed Stop decision. The callback can therefore precede the outcome of stop hooks. This adapter now records it as `unknown` with source `devin:post_cascade_response:awaiting_confirmation`, while retaining `evidence=explicit` to mean the hook itself was observed. Do not interpret this event as `responseEnded` or use it to claim a completed Devin Local turn.

The bundle identifies as `com.exafunction.windsurf`. Its app `Info.plist` short version is `3.11.228`; the bundled `package.json` and `product.json` report `1.126.0`. These are separate version fields.

Current Devin Local uses a different contract: its [customizations guide](https://docs.devin.ai/desktop/devin-local/customizations) points to Devin CLI-format hooks such as `.devin/hooks.v1.json` and user config under `~/.config/devin/config.json`. The bundled Devin Local hook editor uses event names such as `UserPromptSubmit` and `Stop`, not the legacy Cascade event payload. This adapter therefore writes only the official legacy Cascade user hook file above.

## Event mapping and privacy

The official hook payload defines `trajectory_id` as the conversation identity and `execution_id` as the per-turn identity. The installed Devin changelog also identifies `trajectory_id` as the Windsurf-format session ID and `execution_id` as the per-turn ID. The adapter requires both, plus the documented ISO-8601 `timestamp`; it drops events missing any of them rather than inventing a session or turn.

| Cascade event | Agent Watch state | Sequence |
| --- | --- | ---: |
| `pre_user_prompt` | `running` | 1 |
| `post_cascade_response` | `unknown` | 2 |

The adapter reads hook JSON in memory and persists only the allowlisted event ID, app/session/turn IDs, state, timestamp, sequence, evidence, and source. It never reads `tool_info` and never saves prompts, response text, transcript paths, workspace paths, or complete hook payloads. Hook stdout/stderr are kept empty so the observer does not add text to Cascade or change its behavior.

Hook input is capped at 1 MiB. Oversized or malformed input is ignored without blocking the original action, so missing events remain unknown rather than implying completion.

`pre_user_prompt` is an explicit turn-start observation. `post_cascade_response` is an explicit callback observation, but its relation to final completion is not reliable in the current Devin Local runtime; the adapter therefore records unknown. This source does not report approval waits, failures, cancellation, or a separate post-prompt event. An absent event is not treated as completion.

## Install or remove

The manager defaults to dry-run and changes no files unless `--apply` is supplied. It preserves unrelated JSON and hook entries, backs up an existing config before a write, installs a stable owner-only bridge copy, and removes only entries carrying its marker.

```sh
python3 adapters/manage_devin.py
python3 adapters/manage_devin.py --apply

python3 adapters/manage_devin.py --uninstall
python3 adapters/manage_devin.py --uninstall --apply
```

The stable bridge lives in `~/Library/Application Support/Agent Watch/bridge/devin.py`. Event files use the standard Agent Watch events directory and private permissions. Uninstall keeps the bridge and event history.

Fixture checks run with:

```sh
python3 Tests/check_devin.py
```

Fixtures use temporary homes. Native 3.11.228 testing later observed the compatibility callbacks and the Stop-block negative case documented above. The test machine now unregisters this legacy bridge and keeps only the modern Local observer.
