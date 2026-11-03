# Agent Watch adapter for DeepSeek Harness

This Host-only plugin writes one small JSON file per observed lifecycle change to:

`~/Library/Application Support/Agent Watch/events/<event-id>.json`

The files follow Agent Watch's `MonitorEvent` shape and are created with owner-only directory and file permissions. The plugin reads only session identity, optional parent-session identity, session event type, turn number, event sequence, and the fixed turn-end reason tag. It never reads or writes prompt text, transcript bodies, tool arguments, approval details, or tool results. It observes `approval/asked` only; it does not register an approval answerer, resolve a request, or act on `approval/decided`.

## Version evidence and compatibility

This adapter targets **DeepSeek Harness 0.2.1-rc.5**. On the development Mac, both `Contents/Info.plist` and `Contents/Resources/app.asar`'s `dsh/package.json` report `0.2.1-rc.5`; the bundled `dsh-session`, `dsh-agent`, `dsh-agent-loop`, and `dsh-user-approval` packages use the same version. Inspection of that installed build confirmed the `session/event` callback receives `(session, event)`, `event` carries `seq`, `type`, and `data`, the approval service appends `approval/asked` and `approval/decided`, and the agent event dispatcher adds the agent to `agent/status` payloads.

The matching upstream release is [v0.2.1-rc.5](https://github.com/deepseek-ai/deepseek-harness/releases/tag/dsh-v0.2.1-rc.5). Versioned references include [`session/index.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.1-rc.5/packages/core/session/src/index.ts), [`session/types.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.1-rc.5/packages/core/session/src/types.ts), the [`agent` event dispatcher](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.1-rc.5/packages/core/agent/src/dispatch.ts), the [agent loop](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.1-rc.5/packages/core/agent-loop/src/agent.ts), and [`user-approval/index.ts`](https://github.com/deepseek-ai/deepseek-harness/blob/dsh-v0.2.1-rc.5/packages/interaction/user-approval/src/index.ts). Recheck these contracts before enabling on a different version; this is not a claim of compatibility with later releases.

The [MIT-licensed agent-pet DSH plugin](https://github.com/rpegorov/agent-pet/tree/main/plugins/dsh-agent-pet) was used only as a cross-check that DSH plugins can observe session-status events. This adapter does not copy its event log, permission handling, bridge, or other implementation.

## State coverage

- `turn/start` and `step/start` map to `running`.
- `approval/asked` maps to `waitingApproval`; the decision event is deliberately ignored.
- `turn/end` reason `completed` maps to `responseEnded`; `error` maps to `failed`; `aborted` maps to `cancelled`. `blocked` (a rejected pre-step) and `max-tokens` (a turn that hit the output-token ceiling) map to `unknown` with fixed reason codes, since neither proves a complete response.
- `tool/result` and an in-turn `agent/status: running` confirm that work resumed. The plugin ignores agent status outside an observed open turn, since it has no durable turn identifier.
- Version 0.1.1 maps the exact `tool/call` metadata name `ask_user_question` to `waitingInput`; it never accesses the arguments or question body. `tool/result` resumes the running state. This has been verified in an isolated fixed-choice desktop session.
- Unknown or synthetic turn-end reason tags are ignored. Session disposal is not treated as completion.

Subagent events use the child Session's own ID and preserve only its `header.parentSession` ID. They do not change the parent's state.

## Fixture checks

From this directory, run:

```sh
node --test test/fixture.test.mjs
```

The fixtures exercise session, agent-status, approval, terminal mapping, malformed identifiers, and payload exclusion without opening DSH or writing to the user's Application Support directory.

## Installation steps for the main agent

Do not add this plugin by editing the real DSH profile or copying files into it. The main agent should:

1. Confirm the active DSH profile and inspect its current bundles.
2. Use DSH's Plugin Manager `install_bundle` operation with this directory as the local bundle target.
3. Review the operation result and warnings; verify the bundle is applied before enabling it.
4. Restart DSH only if the installation reports that a restart is required.

No installation or profile change is performed by this adapter task.

## Local validation update

Version 0.1.1 was installed and enabled through the native DSH plugin manager using a versioned local directory. The host reported one running component. An isolated fixed-reply task emitted a completed turn; a fixed-choice task emitted waitingInput and then completed after answering. These checks do not prove all failure/cancellation/background cases.
