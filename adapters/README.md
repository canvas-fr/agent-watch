# Agent Watch hooks

The hook bridge records lifecycle metadata for Claude Code, Codex, WorkBuddy,
and the legacy Cascade agent in Devin Desktop. It does not store prompts, tool
arguments, replies, transcripts, or approval decisions. Devin support covers
legacy Cascade only; it does not establish Devin Local or Devin CLI support.

## Requirements and storage

- macOS with Python 3. The scripts use only the Python standard library.
- At installation, the manager captures the absolute interpreter path reported
  by `sys.executable`. Keep that Python installation at the same path while the
  hooks are enabled; a temporary virtual environment is not a suitable
  interpreter.
- Each installed command includes a short digest of the bridge script. Updating
  the script updates the hook definition too, so Codex can request review and
  trust again for the changed definition.
- `--apply` copies `emit.py` atomically to
  `~/Library/Application Support/Agent Watch/bridge/emit.py`. The bridge
  directory is private (0700) and the script is owner-readable only (0600).
  Hook commands use the captured absolute interpreter and this stable copy, so
  moving the source checkout does not break installed hooks.
- Event files are one-line JSON records under
  `~/Library/Application Support/Agent Watch/events/`. Small per-session turn
  metadata is under `metadata/`. Both locations are private. Input larger than
  1 MiB and a session lock that remains busy for 0.1 seconds are ignored so a
  hook failure does not hold up the agent.

## Preview, install, and uninstall

The default command is a dry-run. It displays the selected configuration,
planned hook changes, and stable bridge destination without writing files.
`--apply` makes the change and backs up an existing configuration before
replacing it.

```sh
python3 adapters/manage_hooks.py --app claude_code
python3 adapters/manage_hooks.py --app claude_code --apply

python3 adapters/manage_hooks.py --app codex
python3 adapters/manage_hooks.py --app codex --apply

python3 adapters/manage_hooks.py --app workbuddy
python3 adapters/manage_hooks.py --app workbuddy --apply

python3 adapters/manage_devin.py
python3 adapters/manage_devin.py --apply
```

Configuration targets:

- Claude Code: `~/.claude/settings.json`
- Codex: `~/.codex/hooks.json`
- WorkBuddy desktop: `~/.workbuddy/settings.json`
- Devin Desktop legacy Cascade: `~/.codeium/windsurf/hooks.json`

The Devin adapter registers only `pre_user_prompt` and
`post_cascade_response`. It uses the official legacy Cascade hook format and
keeps `trajectory_id` / `execution_id` as the session / turn keys. It does not
install the transcript hook. See [DEVIN.md](DEVIN.md) for the evidence and
scope boundary. Its stable bridge copy is `bridge/devin.py`; the three other
hook integrations share `bridge/emit.py`.

For Codex, review and trust the new hook definitions before expecting them to
run. Codex skips non-managed definitions until their exact current definition
has been trusted. Open Codex Settings → Hooks, review the entries, then start a
new session (or restart Codex) when checking whether the active session picked
up the configuration. The manager does not bypass Codex's trust prompt.

Uninstall is also dry-run by default:

```sh
python3 adapters/manage_hooks.py --app codex --uninstall
python3 adapters/manage_hooks.py --app codex --uninstall --apply

python3 adapters/manage_devin.py --uninstall
python3 adapters/manage_devin.py --uninstall --apply
```

Uninstall removes only entries carrying this installer's marker. It keeps the
bridge script, event files, session metadata, and their directories. Review and
remove `~/Library/Application Support/Agent Watch/` manually only if you also
want to discard those local records.

## Support boundaries

- Claude Code hooks follow Anthropic's command-hook event and stdin JSON
  contract. This does not establish support for Claude chat or Cowork modes.
- Codex hooks use the documented user-level `hooks.json` source. Codex trust
  review remains required.
- The installed WorkBuddy 5.8.3 desktop bundle contains a CodeBuddy hook
  runtime and resolves its desktop configuration through `~/.workbuddy`.
  Its packaged event dispatch includes the events used here. Real WorkBuddy
  desktop sessions have not been exercised end to end, so installation support
  is not a desktop compatibility acceptance result. CodeBuddy CLI support is
  not treated as proof that every WorkBuddy desktop mode fires the same hooks.

Reference docs: [Claude Code hooks](https://code.claude.com/docs/en/hooks),
[Codex hooks](https://developers.openai.com/codex/hooks), and
[CodeBuddy CLI hooks](https://www.workbuddy.cn/docs/cli/hooks).
