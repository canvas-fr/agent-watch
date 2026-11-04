# MonitorEvent 0.3

The native decoder uses these keys (the early planning document used different draft names):

| Key | Type | Meaning |
| --- | --- | --- |
| id | string | Unique observation ID; replaying this ID is silent |
| appID | string | One supported application ID; demo is reserved for visibly marked local tests |
| sessionID | string | Opaque session or window identity, never the conversation title |
| turnID | string | Stable within one turn; changes at a real new-turn boundary |
| state | enum | unknown, running, waitingApproval, waitingInput, responseEnded, failed, cancelled |
| evidence | enum | explicit or inferred |
| identityScope | optional enum | session for a durable identity, window for an ephemeral window observation; independent of evidence confidence |
| observedAt | ISO 8601 string | UTC timestamp; fractional seconds are accepted |
| sequence | optional integer | Monotonic within a source domain and turn |
| parentSessionID | optional string | Parent identity for a child session |
| source | string | Stable adapter/event identifier, no message text |

Identifiers and source are bounded to 256 UTF-8 bytes and cannot contain newlines. Do not send prompts, tool arguments, paths, transcript text, or raw interface labels. The JSON schema describes the producer contract; the receiver discards unrecognized fields.

Write one object atomically to `~/Library/Application Support/Agent Watch/events/<id>.json`. Create the directory with mode 0700 and files with mode 0600. The consumer accepts regular non-symlink JSON files up to 16 KiB. It scans at most 2,000 entries and accepts at most 200 records per pass, retaining a cursor so malformed files cannot monopolize the queue. Valid consumed files are acknowledged only after the engine snapshot has been persisted.

Sources with independent counters have independent sequence domains. Codex hooks and `codex_app_server` are distinct domains. Same-session old turns, stale timestamps, repeats and events more than 30 seconds in the future cannot roll state back. Terminal states cannot return to running in the same turn. Missing evidence ages to unknown; it does not become completed.

An inferred journal or audit event can still have a stable session identity. Such
records survive a monitor restart, including their replay guards and pending
turns. Only ephemeral window observations are discarded and rediscovered.
Legacy events without `identityScope` retain session semantics except for the
reserved `ax` window-source namespace; the linked Cowork interruption is a
known durable exception. New linked adapters should declare `session`
explicitly. The persisted engine keeps the older dictionary-pair layout and
replay-set fields for decoder compatibility. Window-only heartbeat traffic
does not rewrite identical durable state; the exported status heartbeat stays
live.

Snapshot write suppression also checks file identity, size, modification time
and permissions; an ordinary external replacement invalidates the cache. One
monitor must remain the only writer of its Application Support directory.
Upgrades must stop the old process before replacing it. Rolling back to 0.3.2
requires the paired pre-upgrade state backup: its old startup code removes
inferred sessions even though it can decode the newer optional scope field.

The exported report also includes permission/monitor option booleans and fixed
notification authorization/request outcomes. `accepted_by_system` means the
system accepted a notification request; it does not prove a banner appeared
through Focus settings.
System notification submission is best-effort across process exit; the unread
completion badge is persisted independently. An accepted request is not an
end-to-end delivery receipt and the report does not claim otherwise.

The native window adapter is experimental. It emits only inferred running, waitingApproval, and unknown. It never emits responseEnded merely because a stop button disappears. It does not guarantee access to hidden conversations.

Local metadata and state are stored under the user's Application Support folder. The app provides an explicit local export; no data is uploaded. The host-specific hook adapters are installed independently and preserve unrelated host configuration. The DSH plugin must pass its native bundle installer.
