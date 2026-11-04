# Optional Doubao accessibility launch experiment

This is an **unverified experiment**, not normal monitoring or declared Doubao
compatibility. It is never executed by Agent Watch.

Installed Doubao 2.24.10 embeds CEF/Chromium 147.0.7727.149. The matching
[CEF 7727 public contract](https://github.com/chromiumembedded/cef/blob/7727/include/cef_browser.h#L3818-L3867)
documents renderer-accessibility defaults and `force-renderer-accessibility`.
It does not establish that Doubao forwards a main-app launch argument to its
embedded browser, or that a windowless host implements native AX objects.
The current adapter's window shell is insufficient for task monitoring.

```sh
python3 -B experiments/doubao_accessibility.py          # preflight only
python3 -B experiments/doubao_accessibility.py --apply  # explicit experiment
```

Before an apply, finish any Doubao tasks and exit Doubao normally. The launcher
refuses while either the main app or its exact embedded-browser executable is
running. It checks the app identity/version/signature, reads only PID and
executable path metadata (no command lines), and makes one normal launch request
with the documented process flag. No application binary, signature, profile,
TCC record, launch preference, debug port or certificate policy is changed.
It never force-quits an app or forces a second instance. A successful launch
request is not proof that the flag was applied or that task state is observable.
Validate only through the monitor's bounded state/role diagnostics.

A later normal quit and normal launch omits the temporary flag. Do not infer
completion from process presence, a successful launch, a web area becoming
available, or a child message's finish marker.
