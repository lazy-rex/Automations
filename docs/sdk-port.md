# Automations: the port to the Plugin SDK (plan)

Status: **proposed**, 2026-10-21. The SDK contract is hub branch `hub/sql-contract` at a2a0ece
(`docs/plugin-sdk.md` and `docs/sql.md`, draft 2). The SDK code does not exist yet. This page is
the plan; the port starts when the SDK code that it uses runs against the fake `hub.sql`.

## Baseline

- Pre-port commit: a79e7f2 (main 3c86058 plus the not_created restart, in review). The port
  starts from that commit after it is on main. If it changes in review, the baseline is the
  reviewed commit.
- Lines at a79e7f2: `automations.lua` 1837, `automations_view.lua` 552 (plugin 2389); tests 2754.
- The report at the end gives the same counts for the port commit.

## Invariants that the port keeps

Each one has tests today (the files in "Tests"). The port changes how they are stored, not what
they guarantee.

1. **Runs.** One run per daily slot (`daily_high`), per file appearance (the marker), and per Run
   now key. Catch-up after a restart gives one run for the newest missed date.
2. **Starts.** The start request is stored before `hub.spawn`. An unknown outcome replays the same
   key. A definite failure fails the run. A not_created failure restarts once in each start
   admission. `unknown_start` after 10 minutes; dismiss never replays that key.
3. **Watches.** One watch key per trigger generation. Files from before the watch make no run. An
   appearance is acknowledged only after its run commits; the marker retires after the removal.
4. **Delivery attempts.** A task goes to one holder. A lost worker gives attempt + 1; `done` of an
   old attempt is refused.
5. **Deletion.** The delete fence first; no new run, start or delivery after it; queued runs are
   cancelled; active runs end; then the run history, the markers and the preset reservation go.
6. **Retention.** The newest 100 terminal runs stay, in end order (not clock order).
7. **Operation replay.** A mutation with the same key and content gives the first answer; other
   content is a conflict. A pre-port key must not make a second run after the cutover.

## What the SDK replaces

| Code today | Lines (about) | After the port |
|---|---|---|
| `hub()` wrapper, error text parsing, unknown outcome codes | 25 | SDK calls; `app.hub` for the raw hub actions |
| `batch`, `get`, `get1`, `scan`, `committed`, request size checks | 60 | `app.db.exec` / `query` in one handler transaction |
| Op keys, `replay`, fingerprints, the `if_rev` retry loops in each export (`save`, `run_change`, `commit_managed`, `done`, `run_now`, `set_enabled`, `delete`) | 250 | SDK saved replies (key = the caller's key) and one transaction per handler |
| `client.keymap`, `hub.register`, `exports` table, the dispatch in `client_perform_requested` | 130 | `app.action(name, schema, fn)` |
| `agent_caller` (`hub.identify`, legacy IDs) | 20 | `ctx.agent` (gap 8: the legacy IDs) |
| `ui_changed` and `hub.ui.invalidate` | 15 | automatic refresh from table reads |
| Store key layouts: `q/`, `dv/`, `t/`, `box/`, `preset/`, `meta/next_id` and their index upkeep | 120 | SQL indexes on `runs` and a UNIQUE index for presets |
| Delete cleanup batching (`fits`, `send_fenced`, bounded cancel and purge pages) | 90 | One transaction for cancel, one for purge (bounded by SQL, not by the 48 KB batch) |
| Retention (`terminal_op`, the `t/` index, `prune_step`) | 70 | `ended_seq` column and one DELETE in the terminal transaction |
| `runs` phases S/D/Q/T and the cursor | 90 | One ordered query with keyset paging |
| `list` tombstone paging | 40 | `WHERE deleted = 0` with keyset paging |
| View: route parsing, the `view.render` / `view.action` dispatch, rendered parity glue | 150 of 552 | `app.panel` and items with `on_select` (gap 4: forms and routes) |

What stays: the validation of triggers and actions, the clock and daily slots, the engine steps
(spawn, lost worker, drain, reconcile, tick), the presets, and the panel and form content.

Estimate (proposed, not measured): `automations.lua` from 1837 to about 1000, the view from 552
to about 350.

## The SQL schema

One migration string for each statement, version 1:

```sql
CREATE TABLE automations (
  id INTEGER PRIMARY KEY, name TEXT NOT NULL, enabled INTEGER NOT NULL, deleted INTEGER NOT NULL DEFAULT 0,
  trigger_kind TEXT NOT NULL, at TEXT, path TEXT, glob TEXT,
  profile TEXT NOT NULL, args TEXT NOT NULL DEFAULT '{}', title TEXT, cwd TEXT, instruction TEXT NOT NULL,
  preset TEXT, gen INTEGER NOT NULL, daily_base TEXT, daily_high TEXT,
  next_manual INTEGER NOT NULL DEFAULT 0, next_q INTEGER NOT NULL DEFAULT 0, next_t INTEGER NOT NULL DEFAULT 0,
  worker TEXT,      -- JSON {spawn_id, agent_id, spec}
  spawning TEXT     -- JSON {run, since, request, auto}
)
CREATE UNIQUE INDEX automations_preset ON automations (preset) WHERE preset IS NOT NULL AND deleted = 0
CREATE TABLE runs (
  run_key TEXT PRIMARY KEY, automation_id INTEGER NOT NULL REFERENCES automations (id),
  kind TEXT NOT NULL, k TEXT NOT NULL, status TEXT NOT NULL, at INTEGER, slot TEXT, item TEXT,
  task TEXT NOT NULL, attempt INTEGER NOT NULL, starts INTEGER NOT NULL,
  agent TEXT, spawn_id TEXT, error TEXT, outcome TEXT, summary TEXT, retries INTEGER,
  dismissed TEXT, restarted TEXT, by TEXT, q INTEGER, t INTEGER, done_at INTEGER
)
CREATE INDEX runs_queue ON runs (automation_id, q) WHERE q IS NOT NULL
CREATE INDEX runs_ended ON runs (automation_id, t) WHERE t IS NOT NULL
CREATE INDEX runs_box ON runs (agent, status)
CREATE TABLE seen (automation_id INTEGER NOT NULL, appearance TEXT NOT NULL, run_key TEXT, retired_seq INTEGER,
  PRIMARY KEY (automation_id, appearance))
CREATE TABLE legacy_ops (key TEXT PRIMARY KEY, fingerprint TEXT, reply TEXT NOT NULL, at INTEGER NOT NULL)
```

- The partial UNIQUE index replaces `preset/<name>`: a reinstall during an old cleanup works,
  because the old row has `deleted = 1`.
- `runs.q` replaces `q/`; `runs.t` replaces `t/` and `next_t`; "delivered to agent X" replaces
  `box/` and `dv/`.
- `spawning` and `worker` stay JSON: the engine reads and writes them whole.

## The one-time import

- One action with `{tx = false}` reads the hub.store records (`app.hub` `hub.store.scan`) and
  writes the rows in bounded steps. A `meta` row records the import as done; the import runs once,
  at the first start of the ported plugin, before any engine step.
- Spawn keys, watch keys, appearance keys, attempts and starts copy as they are, so a pending
  start replays its stored key and a watch keeps its appearance IDs.
- Operation replies: hub.store op records copy to `legacy_ops`, and each export checks
  `legacy_ops` before the SDK replay, for 7 days after the import (gap 2). If the SDK gets an
  import bridge into `lazyrex_ops`, this table goes.
- Automations runs live since 2026-10-20. I do not know whether the user added automations, so the
  import is required.
- The old records stay in hub.store until a later cleanup commit.

## Gaps sent to the SDK owners

1. Timer and event callbacks need a transaction boundary, with `app.notice` in it (the engine
   runs from timers and `hub.changed`).
2. An import or replay bridge for the saved replies of hub.store operations.
3. The SDK API (or the documented `app.hub` escape) for `hub.spawn`, `hub.watch.*`,
   `hub.workers`, `hub.profiles`, and `hub.identify`.
4. Forms, routes, confirmation and paging in views, and the link from an `on_select` handler to its
   agent action for parity.
5. Test harness: a read of the plugin's SQL rows (today `store()`), a fault on `hub.sql.commit`
   (today `inject` on store writes), and a way to write rows directly (today `write()`).
6. A panel without a tab: Automations has a palette command and a side panel, no tab
   (`hub.ui.tabs {tabs = {}}`, commands with `surface = 'panel'`).
7. A `hub.changed` handler (workers, watch nudges) in the SDK.
8. `ctx.agent` and the legacy IDs of an agent (task access accepts the IDs it took over).

## Tests

All 18 files stay green, with the same names and the same behavior checks. The tests that read or
fault the store directly change their mechanism (gap 5), not their assertions:
lifecycle.lua, retention.lua, restart.lua, reassign.lua, action.lua, deliver.lua, presets.lua,
not_created.lua, panel.lua, schedule.lua, start.lua, file.lua, save.lua, runs.lua, list.lua.
New: an import test (a store backlog with a pending start, a watch, a terminal history and a
saved Run now key; after the import, the same key gives the same run, and the pending start
replays its key).

## Order of the work

1. This plan (review).
2. The schema, the import and the read paths (`list`, `runs`, `presets`, `read`), with the raw
   escape for hub calls.
3. The exports, one transaction each, with the saved replies.
4. The engine steps from timers (needs gap 1, or the raw escape until it closes).
5. The panel and forms (needs gap 4).
6. Remove the bridges that the SDK covers; report the line counts.
