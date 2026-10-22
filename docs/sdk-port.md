# Automations: the port to the Plugin SDK (plan)

Status: **proposed**, 2026-10-21. The SDK contract is hub branch `hub/sql-contract` at a2a0ece
(`docs/plugin-sdk.md` and `docs/sql.md`, draft 2). The SDK v0 code is on hub branch `sdk/lua`
(52a2e1f). Slice 1 runs on the current hub. Slice 2 (SQL) starts when the real `hub.sql` and the
harness `H.sql` run in a lab: the fake `hub.sql` of the SDK tests knows only the statements of the
to-do example.

## Baseline

- Pre-port commit: d66cdc5 (main 3c86058 plus the not_created restart and its fix, in review).
  The port starts from that commit after it is on main. If it changes in review, the baseline is
  the reviewed commit.
- Lines at d66cdc5: `automations.lua` 1839, `automations_view.lua` 552 (plugin 2391); tests 2781.
- Measured after each slice: 5e32486 (the fairness fix, on main) `automations.lua` 1849; slice 1
  (6fb8b4a) 1840.

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
5. **Deletion.** The delete fence first. The fence frees the preset at once, so a reinstall can
   commit while the old cleanup waits. After the fence: no new run, no new start and no delivery
   of a queued run. Queued runs are cancelled. A start that is already pending can still open and
   deliver its run, and a delivered run can finish. Then the run history and the markers go.
6. **Retention.** The newest 100 terminal runs stay, in end order (not clock order).
7. **Operation replay.** A mutation with the same key and content gives the first answer; other
   content is a conflict. Today a saved reply has no expiry. A pre-port key must not make a second
   run after the cutover.

## What the SDK replaces

| Code today | Lines (about) | After the port |
|---|---|---|
| `hub()` wrapper, error text parsing, unknown outcome codes | 25 | SDK calls; `app.hub` for the raw hub actions |
| `batch`, `get`, `get1`, `scan`, `committed`, request size checks | 60 | `app.db.exec` / `query` in one handler transaction |
| The `if_rev` retry loops in each export (`save`, `run_change`, `commit_managed`, `done`, `run_now`, `set_enabled`, `delete`) | 200 | one transaction per handler |
| Op keys, `replay`, fingerprints | 50 | stay, on a plugin table (see "Operation replies") |
| `client.keymap`, `hub.register`, `exports` table, the dispatch in `client_perform_requested` | 130 | `app.action(name, schema, fn)` |
| `agent_caller` (`hub.identify`, legacy IDs) | 20 | `ctx.agent` (gap 8: the legacy IDs) |
| `ui_changed` and `hub.ui.invalidate` | 15 | automatic refresh from table reads; `app.refresh()` stays for the watch and worker state, which is not in the database |
| Store key layouts: `q/`, `dv/`, `t/`, `box/`, `preset/`, `meta/next_id` and their index upkeep | 120 | SQL indexes on `runs` and a UNIQUE index for presets |
| Delete cleanup batching (`fits`, `send_fenced`, the 48 KB measure) | 50 | bounded pages of SQL rows (LIMIT), one transaction each, resumed by the engine |
| Retention (`terminal_op`, the `t/` index, `prune_step`) | 70 | `ended_seq` column and one DELETE in the terminal transaction |
| `runs` phases S/D/Q/T and the cursor | 90 | One ordered query with keyset paging |
| `list` tombstone paging | 40 | `WHERE deleted = 0` with keyset paging |
| View: route parsing, the `view.render` / `view.action` dispatch, rendered parity glue | 150 of 552 | `app.panel` and items with `on_select` (gap 4: forms and routes) |

What stays: the validation of triggers and actions, the clock and daily slots, the engine steps
(spawn, lost worker, drain, reconcile, tick), the presets, and the panel and form content.

Estimate (proposed, not measured): slice 2 (document tables) to about 1300; slice 3 (normalized
tables) to about 1100, the view from 552 to about 350.

## Slice 1: the SDK frame on the store engine

Slice 1 uses the SDK for the registration and the dispatch, and keeps the store engine and the
replay path as they are. It needs no SQL, so it runs in a lab hub today. The SQL storage is one
later cutover (slice 2): no release has SQL reads beside store writes.

- `app.action(name, schema, fn, {tx = false, store = false})` for each export. The handler makes
  the caller from `ctx` (`ctx.agent` and `ctx.aliases`, with today's ID checks) and calls the
  handler of today with `args.key = ctx.key`.
- `app.view('/panels/automations*', ...)` and `app.view('/forms/automation/*', ...)` with
  `{store = false}`; the view module stays. `app.command` for the two palette commands.
- `app.on('hub.changed', fn)` marks the automations and schedules the steps, as today.
- The hub calls stay on the plugin's own `hub()` function, which calls `rex.call` directly (not
  `app.hub`) and keeps today's codes: no code, `disconnected`, `timeout`, `client_unavailable` and
  `unavailable` are `unavailable` (an unknown outcome). The SDK maps only `disconnected`.
- The launcher: the manifest has `"sdk": "0"`, and the hub starts the plugin through the SDK
  launcher (`boot.lua`, hub 0ae7451 on the lab branch `hub/sql-r2`), which puts the SDK in
  `package.path`. The plugin has no path setup of its own. Until the launcher is live, slice 1 runs
  in a lab only (slice 1 is 6fb8b4a, approved for its branch).
- Removed: `client.keymap`, `hub.register`, the dispatch, `client.set_label` and the `hub.identify`
  call of the caller. The `exports` table stays as the source of the names, schemas, titles and
  descriptions. Measured: `automations.lua` 1849 to 1840 lines.

## The SQL schema (slice 2: document tables)

Coordinator decision (2026-10-22): slice 2 keeps each record value of today as one JSON document,
with the fields that queries need as extra columns. The engine rules stay; the storage layer, the
column synchronization, the SQL constraints and the import and cutover are the new parts, and the
tests must prove each of them. These document tables, with their query columns, are the target
schema of release 4 (coordinator decision, 2026-10-22): they are domain tables, one for each
entity, and a JSON document column in a domain table is allowed. Slice 3 deletes the bridge and
uses direct SQL on these tables; it is not optional. A normalization of `runs.doc` into columns is
a separate migration with its own decision, only when a query or size need shows it.

```sql
CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)
CREATE TABLE automations (id TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)
CREATE TABLE states (id TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)
CREATE TABLE runs (run_key TEXT PRIMARY KEY, automation_id TEXT NOT NULL, rev TEXT NOT NULL,
  status TEXT NOT NULL, q TEXT, t TEXT, agent TEXT, doc TEXT NOT NULL)
CREATE UNIQUE INDEX runs_q ON runs (q) WHERE q IS NOT NULL
CREATE UNIQUE INDEX runs_t ON runs (t) WHERE t IS NOT NULL
CREATE INDEX runs_delivered ON runs (agent, run_key) WHERE status = 'delivered'
CREATE INDEX runs_auto ON runs (automation_id, status)
CREATE TABLE presets (name TEXT PRIMARY KEY, rev TEXT NOT NULL, automation_id TEXT NOT NULL)
CREATE TABLE seen (key TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)
CREATE TABLE retired (key TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)
CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT, reply TEXT NOT NULL)
```

- One authoritative value: the document. The columns are copies of document fields (`status`,
  `q`, `t`, `agent`) that one write function computes from the document in the same statement.
  No code writes a column alone. A test checks, after each test file, that every row's columns
  equal the fields of its document.
- Revisions are decimal strings, as the store gives them today (`rev TEXT`). A write compares the
  old rev and stores the next decimal string, in the handler transaction. Hub watch sequences,
  spawn requests and every other value stay in the document exactly as the store gave them to Lua.
- Queue and terminal keys stay the strings of today (`q/<id>/<seq>`, `t/<id>/<inv>`), zero padded,
  so their order is the text order.

Every old index record and its replacement:

| Store record | SQL replacement | What must hold |
|---|---|---|
| `q/<id>/<seq>` = {run} | `runs.q` (UNIQUE) | queue order is `q` order; a queued run has `q`; cancel and delivery clear it in the same write |
| `t/<id>/<inv>` = {run, seq} | `runs.t` (UNIQUE) | terminal order is `t` order; retry clears `t`; retention keeps the newest 100 by `t` |
| `dv/<id>/<run_key>` = {agent} | `runs` with `status = 'delivered'` | the delivered runs of one automation; the lost-worker step pages them |
| `box/<agent>/<run_key>` = {attempt, auto} | `runs` with `status = 'delivered'` and `agent` | read lists only the caller's IDs; the attempt is the document's; `done` checks the attempt (stale_delivery); the read cursor keeps the text `box/<agent>/<run_key>` |
| `preset/<name>` = {id} | `presets` (PRIMARY KEY on name) | a save inserts it in its transaction (a second install is a conflict that names the owner); the delete fence deletes it only when it names that automation, so a reinstall during an old cleanup stays |
| `seen/<id>/<appearance>` | `seen` | a marker stays after its run is pruned, until its removal is acknowledged |
| `rt/<id>/<appearance>` | `retired` | as today |
| `meta/next_id` | `meta.next_id` | a deleted highest ID is never used again |
| op records (hub.store ops) | `ops`, and the lazy old lookup | see "Operation replies" |

- The delete cleanup keeps bounded pages (at most 50 runs or markers in one transaction), resumed
  by the engine after a timeout or an error, with a test of a large backlog.
- A transaction never spans `hub.spawn` or another slow hub call. The start keeps its order: one
  transaction stores the request, then the call, then one fenced transaction stores the result.

## Operation replies (slice 2)

- Today a saved reply has no expiry. The SDK saved replies expire (7 days, 10 000 keys), so the
  exports use `{store = false}` and the plugin table `ops`, with no expiry. A change of that
  guarantee needs a product decision.
- The op key and the fingerprint stay as today: `<kind>/<caller id><key>`, looked up under every
  ID of the caller (identity and legacy IDs).
- Old replies are imported: the hub gives `hub.store.ops_scan` (f6f1a03), and the import copies
  each saved operation (key, fingerprint, result) into `ops` (f962e2b). The lazy `hub.store.op`
  lookup is not needed when the cutover test shows that an old key replays from `ops` under the
  identity and under a legacy ID; until that test passes, the lookup stays in the plan.

## The one-time import (slice 2)

Built and approved for its branch (f962e2b): the import module copies each store record and
saved reply exactly, one page per transaction with its cursor; a row repeats only when it is
equal; any other conflict stops the import. Until the cutover it runs only on a lab trigger.

## The cutover (slice 2, proposed)

The cutover is one plugin version. From its first start, SQL is the only store: no path reads or
writes hub.store records after the copy, and no path writes hub.store notices. The coordinator
rule for SQL ports applies (2026-10-22): the tables are the target domain tables (no generic
`records` table), and a temporary code adapter over them is allowed when it adds no new caller
after the cutover, the plan names each function it replaces and the slice that deletes it, and
that slice starts right after the cutover is approved on the branch.

1. **The storage state at start.** `meta.import` holds `cutover-1:copying` or `cutover-1:done`.
   At start, before any other work, the plugin reads the meta table and the row counts, and takes
   exactly one of these paths:

   | State at start | Path |
   |---|---|
   | every table empty | write `cutover-1:copying` and the cursor `1:`, then copy |
   | `cutover-1:copying` with a valid cursor (`<n>:<key>`, n from 1 to the step count) | resume the copy from its committed cursor |
   | `cutover-1:done` with `meta.rev` (a decimal string) and `meta.next_id` | open SQL: the engine starts on the tables |
   | any other state: rows without `meta.import` (also the lab import layout), another or newer version, another state word, a bad cursor, `done` without its metadata | refuse to start: no write; each export answers `unavailable` ("the storage state is not known"); views show that text; the log names the state |

   The plugin never deletes rows at start. A database with rows and no valid marker is damaged
   state, and the plugin refuses it. A lab with the tables of the lab import (f962e2b, never on
   main) is reset outside the plugin (the test harness empties the tables). Tests: each row of the
   table, and a restart after SQL-only changes (a save and a delivery after `done`) that keeps
   them and does not copy again.
2. **No other writer during the copy.** Every entry point checks one gate (`S.ready`), and the
   copy sets it only after `done`:
   - exports: `unavailable` ("starting: importing the automations");
   - views: `render` shows that text and no action; `view.action` refuses;
   - `hub.changed`: marks only; no drain, no step;
   - the startup callback and the tick: no engine step, no reconcile, no sweep; the tick runs only
     the next copy step.

   The old instance: the hub retires it before the new one starts. A store batch of the old
   instance that passed the caller check before the retirement must not commit after it. That is
   the store write fence of hub/store-fence (f0c580c), which is not in f6f1a03. The cutover needs
   it in the hub release that has hub.sql: the hub lead puts it on main before hub.sql. Test in
   a lab: an old-instance
   batch held at the fence during a plugin reload; it gets `stale_instance`, and the copy does not
   see its record.

   Watch events: the hub keeps them while the copy runs (the watch, its `watch_id` and its unread
   page stay in the hub). After `done`, the normal start reconciles (`hub.watch.list`, then
   `ensure` with the same key, which keeps the `watch_id`) and drains from the hub cursor. To
   verify in a lab: `ensure` on a live key during a new instance keeps the watch_id and its unread
   events. Tests: a file that appears during the copy gives one run after `done`; a pending start
   (stored request, no result) replays its key after `done` and gives one worker.
3. **The copy.** The approved import steps. Then one store batch writes `meta/cutover` and gives
   its revision R. The last SQL transaction sets `meta.rev = R`, `meta.next_id` and
   `cutover-1:done`. A lost store reply or a crash between the two writes the marker again at the
   next try, and gives a later R. A later R is correct: no SQL runtime write happens before `done`.
   Then the engine starts, as at a start today.
4. **The bridge** (temporary adapter, see the inventory below). It gives the store interface of
   today (`get`, `get1`, `scan`, `batch` with `if_rev`, the op records) on the SQL tables:
   - a record key names its table and row (`auto/`, `state/`, `run/`, `preset/`, `seen/`, `rt/`,
     `meta/next_id`);
   - revisions: one counter `meta.rev`, initialized to R, which is above every revision that the
     store gave (R is the store's own next revision). Each written row takes the next value, as
     each written store record does today. The counter is a decimal string; SQLite adds one in
     64-bit integers (`CAST(CAST(value AS INTEGER) + 1 AS TEXT)`), so Lua never holds it as a
     number. Before each increment, the bridge compares the counter text with the int64 maximum
     (`9223372036854775807`; length, then text). At the maximum it fails the batch (`internal`),
     before SQLite can give a REAL, and the transaction rolls back with no row changed. No
     revision is used twice, and an imported revision keeps its text. Tests: the boundary (a
     counter one below the maximum gives one write, then the refusal with no change), and R after
     a lost store reply;
   - `if_rev` is checked in the transaction: the row's `rev` equal, or the row absent for `'0'`;
   - the derived index records (`q/`, `t/`, `dv/`, `box/`) have no row. A derived record exists
     when a run has that column value (`q`, `t`; `dv` and `box` for a delivered run with its
     agent). Its value is computed from the run (`{run}`, `{run, seq = tseq}`, `{agent}`,
     `{attempt, auto}`). Its revision is the run's revision;
   - `if_rev` on a derived record: `'0'` holds when no run before the batch gives it; another
     value holds when the run that gives it has that revision;
   - a batch write of a derived record holds when the run after the batch gives exactly that
     value; a delete holds when no run after the batch gives it. Else the batch fails with
     `conflict` and writes nothing. So a batch that deletes a run and its index records holds, and
     a batch that writes an index record with no matching run fails;
   - a stale index record (an entry with no run that gives it) cannot exist in SQL. The prune step
     deletes such entries today; on the bridge that delete holds with no change;
   - `{notify = {agent, pending}}` becomes `app.notice(agent, pending)` in the same transaction;
   - an op record (`{op = {key, fingerprint, result, result_revs}}`) is an `ops` row in the same
     transaction, with `result_revs` filled from the revisions of that batch. The replay reads
     `ops` under every ID of the caller, with the fingerprint check of today.

   Tests for revisions: a conflict after an external call (a save between the spawn request and
   the result batch makes the result batch fail and retry); a lost commit reply of a result batch,
   then the replay; terminal pruning on the bridge; a run delete with its index records.
5. **External calls stay outside a transaction.** Each batch is one transaction. A step that
   calls `hub.spawn`, `hub.watch.*` or `hub.workers` does it between its batches, as today.
6. **Bounded work.** The cleanup pages (at most 50 rows in one batch) and the 48 KiB measure of
   one batch stay.
7. **Tests.** All 20 files run on the cutover version. The harness store calls (`store()`,
   `write()`, `inject` on store batches) change to SQL (`sql()`, `sql_write()`, the commit
   faults); the assertions stay. New, besides the tests in 1 to 4:
   - a crash during the copy resumes from its committed cursor and copies each record once; a
     database with rows and no valid marker refuses to start and changes nothing;
   - an old Run now key replays from `ops` under the identity and under a legacy ID. When it
     passes, the lazy `hub.store.op` lookup goes; until then it stays;
   - a delivery: the task and its notice commit together; a failed commit has neither; a lost
     commit reply delivers once; a store notice after the cutover is `notices_moved`.

### The bridge inventory

Each function of today that the bridge replaces, and the slice 3 step that deletes it. Slice 3
starts when the cutover is approved on the branch. Release 4 can ship the cutover with the
bridge; slice 3 follows as a plugin release.

| Function today (automations.lua) | Bridge part | Deleted in |
|---|---|---|
| `scan` of `q/`, `t/`, `dv/`, `box/` (queue, prune, lost worker, read) | derived index records | 3a: runs queries on the columns (`ORDER BY q`, `ORDER BY t`, `status = 'delivered'`) |
| `batch` ops on `q/`, `t/`, `dv/`, `box/`; `terminal_op`; the stale-entry prune | derived index checks | 3a: the run write sets the columns; the index ops go |
| `get1`/`get`/`batch` on `run/` | the runs table, `if_rev` | 3a: run writes with `WHERE rev = ?` |
| `get1`/`batch` on `auto/`, `state/`, `preset/`, `meta/next_id` | key mapping, `if_rev` | 3b: direct SQL for automations, states, presets, next ID |
| `scan`/`batch` on `seen/`, `rt/` | key mapping | 3c: direct SQL for the markers |
| the op records of `batch`, `result_revs`, the `hub.store.op` lookup (line 313) | ops mapping | 3d: the replay reads and writes `ops` directly |
| `batch` notify | `app.notice` mapping | 3d: the steps call `app.notice` |
| the bridge module, `fits`, the 48 KiB request measure | all | 3e: deleted; bounds become row counts |

After 3e the plugin has no call to `hub.store.*`, except the copy steps of the import, which
slice 4 deletes when no install can be older than the cutover.

### Rollback

Code rollback alone is not a rollback. At hub f6f1a03, the first SQL commit with a notice writes
`sql_notice_plugins` in hub.db (`moveNotices`). After that, the hub refuses every
`hub.store.batch` with `notify` from the plugin (`notices_moved`), so the slice 1 version cannot
deliver a task. A restore of hub.db is not the procedure: hub.db holds the records of every
plugin. The hub lead's procedure (proposed, not built; it goes to hub/sql-r2 before the hub.sql
release):

1. Before the cutover: a consistent SQLite backup of `<state>/sql/automations.db` (a backup
   operation, or a copy after the hub closed its connections; not a file copy of a live database
   and its `-wal` and `-shm` files).
2. Rollback: stop the plugin; call `hub.admin.sql_return {plugin}`; move the release clone back;
   start the plugin. The admin call refuses while the plugin is registered or desired running. It
   drains the plugin's outbox and refuses if a row stays. It closes the hub's connections to the
   plugin's SQL file and renames the file (with `-wal` and `-shm`) to
   `<plugin>.db.returned-<UTC time>`; it never deletes it. Then, in one hub.db transaction, it
   deletes the plugin's `sql_notice_plugins` and `notice_receipts` rows. It answers
   `{returned = <backup name>}`. A retry after a stop between the rename and the transaction finds
   no file and does only the transaction. Reviewer requirements (hub-owned, to verify): no crash
   between the steps lets a start replay the retired outbox or reopen the stale file; the archive
   is outside the directory of active SQL databases; a test interrupts at each durable boundary,
   then checks legacy delivery and a later forward import.
3. A later forward starts with no SQL file and copies the store again. The renamed file is never
   live: it has `cutover-1:done` and does not have the store changes made after the rollback, and
   the plugin cannot see those changes. The file stays as evidence.

The changes made after the cutover are lost (accepted by the coordinator); the release note must
say so and name the procedure.

## Gaps sent to the SDK owners

Answered by sdk/lua 52a2e1f and the hub lead: 1 (`app.after`, `app.every` and `db.transaction`
give callbacks a transaction, with `app.notice`), 3 (`app.hub`), 5 (hub side: `H.sql`, commit
faults; in progress), 6 (`app.panel` and `app.command` make no tab), 7 (`app.on('hub.changed')`),
8 (`ctx.aliases`). Open:

2. An import bridge for hub.store operation replies. The plan above does not need one.
4. Forms and routes: `app.view` raw handlers cover them; the view module stays.
9. Saved replies are looked up under `ctx.agent` only, not under the legacy IDs. The plan above
   keeps its own replay, so it does not need a fix.

## Tests

All 18 files stay green, with the same names and the same behavior checks. Slice 1 changes no
test. In slice 2 the tests that read or fault the store change their mechanism (`H.sql`, commit
faults), not their assertions: lifecycle.lua, retention.lua, restart.lua, reassign.lua,
action.lua, deliver.lua, presets.lua, not_created.lua, panel.lua, schedule.lua, start.lua,
file.lua, save.lua, runs.lua, list.lua.

New in slice 2:
- An import of a store backlog with a pending start, a watch with appearances, a terminal history,
  a deleted highest ID and an open edit form: after the import, the pending start replays its key,
  the next ID is new, and the old rev gets the conflict.
- An old Run now key (and one under a legacy ID) gives the same run after the cutover; other
  content is a conflict.
- A crash in the middle of the import, and one at the last step: the import resumes and copies
  each record once; no action runs before it is done.
- A notice after the cutover goes through SQL, and no store notice is sent.
- A delete of an automation with a large backlog: the cleanup pages time out or fail, retry, and
  end with nothing left.
- A reinstall of a preset while the old cleanup waits (kept from presets.lua).

## Order of the work

1. This plan (review).
2. Slice 1, against the current hub (`app.hub`, store engine).
3. Slice 2 on the lab branch hub/sql-r2: first the storage module and the import, used by no
   production path, with their tests; (done: f962e2b, approved for its branch; the import runs
   only on a lab trigger); then the exports, the engine steps and the views on SQL, in
   one cutover commit series. The delivery moves to SQL only when the hub commits SQL notices in
   the same transaction. Nothing of it goes to main before the coordinator announces the launcher
   and hub.sql live.
4. Slice 3, which starts when the cutover is approved on the branch (coordinator rule,
   2026-10-22), not when SQL goes live: delete the bridge in the steps 3a to 3e of "The bridge
   inventory" (runs first), with direct SQL on the same domain tables, and delete the record
   logic that each step makes redundant.
5. Remove the bridges that the SDK covers; report the line counts after each slice.
