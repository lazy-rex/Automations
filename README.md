# Automations

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. An automation is a trigger and an action:

- Triggers: a new file in a directory, or a schedule (daily at a local time).
- Action: deliver the run to the automation's worker if it runs; else start a worker from the
  automation's agent profile, then deliver.

Status: in progress. Built: file and daily triggers, manual runs, the worker start, the delivery,
enable and disable, delete, retry, cancel, dismiss, run retention, the panel and forms, and the
presets.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "automations", "path": "/path/to/Automations/automations.lua",
 "notice": "Automation task. Call automations_read.",
 "watch_roots": ["/path/to/a/watched/parent"]}
```

A file automation can watch only a directory inside `watch_roots`. The hub reads the config at
start, so restart the hub after a change. `automations.list` shows a refused watch with a hint.
The hub refuses a directory that does not exist (`watch_missing`) before it checks the grant.

## Panel and forms

The palette command "Automations…" opens the side panel. "New Automation…" opens the form.

- The panel lists 20 automations a page (Next page, First page). Each item shows the trigger, the
  watch state, a start that needs action, the queued runs and the last run. A deleting automation
  shows as "<name> (deleting)". The panel also lists the presets, with Add.
- The automation view has Run now, Enable or Disable, Edit…, Delete… and a page of 20 runs. A run
  has one action: Cancel (queued), Dismiss pending start (unknown_start) or Retry (failed,
  dismissed or cancelled). Retry is disabled while the automation is disabled, and for a file run
  without a path. A deleting automation shows only its runs, with Cancel and Dismiss.
- A form has two steps: step 1 chooses the agent profile (50 a page), step 2 has the fields and
  that profile's args. "Change profile…" goes back to step 1 and does not keep the entered fields.
  A profile whose form is over 40 KB gets a refusal: use `automations.save`.
- The edit route carries the rev. A save after another change is refused (conflict), and the
  message says to reopen the automation.
- Delete asks for confirmation and says that the run history goes too.
- Each view action calls the same handler as its agent tool, with the user as the caller. The
  hub keeps each view operation durable; the plugin replays it by its operation key.

## Presets

`automations.presets` lists the presets with their fields. Install one with `automations.save`
and `preset`, or with Add on the panel. You choose the profile.

- Vault inbox (`vault-inbox`): a run for each new `*.md` file in `~/knowledge/inbox`, in
  `~/knowledge`. The live hub must grant `~/knowledge/inbox` in `watch_roots`.
- Vault health (`vault-health`): a run every day at 22:00, in `~/knowledge`.

A preset installs once: `preset/<name>` names the automation that installed it, and a second
install is a conflict. An edit keeps the preset. Delete makes it available again at once; the old
automation's cleanup never removes a newer install.

## How a run reaches an agent

The plugin does not use Messaging. A run goes into the worker's task box (a delivered run in
this plugin's SQL tables), and the same transaction sets a hub notice for the worker. The hub writes the
notice text into the worker's pane when the worker is ready. The worker reads its tasks with
`automations.read` and completes each one with `automations.done`.

- Each automation keeps one current worker (the spawn that it started). It never chooses an agent
  by profile. A run goes to the current worker only when the worker was started with the same
  profile, args and working directory (`action.cwd`) as the run. After a change of those, the next
  run starts a new worker, and the old worker finishes the tasks that it has and gets no new ones.
  A change back to an earlier action also starts a new worker.
- `action.cwd` is the worker's directory. Save expands a leading `~` with `HOME` and checks that
  the directory exists (`/bin/test -d`); the hub checks it again at each start. A run keeps the
  action of its time, and a pending start replays its stored request.
- The plugin checks the delivered runs a page at a time and wraps at the end, so a page of live
  tasks never hides a lost one.
- The worker key is the spawn ID. A task goes to the current identity in the worker's pane
  (`identity_id`), never to the spawn's agent ID. The plugin reads one spawn with
  `hub.workers {spawn_id}` (hub docs, hub.workers). It reads `state` first: `exited` or `failed`,
  or `not_found` (a closed or unknown spawn), means gone, and `identity_id` is not read then.
  `running` with an `identity_id` is alive. With no `identity_id`, the pane is waiting when
  `identity_seen` is false, and ended (the program left, or the conversation resumed in another
  pane) when it is true. Ended is gone for the plugin. In `hub.workers`, `status` is the pane's
  program status; the row's lifecycle is `state`.
- "open" from `hub.spawn` says nothing about the identity: a spawn can be open before its first
  report. The admitted start keeps its run until the pane has an identity, and waits for
  `hub.changed {what = "workers"}`. A delete or an action edit during that wait keeps the
  admitted run. After 10 minutes with no identity the run is `unknown_start`, as a pending start.
  A spawn that is gone before its first identity got no task (no notice, no attempt): its run
  fails, as a refused start does, and Retry starts it again. After a delete it is cancelled. The
  plugin never starts it again by itself: a profile whose program exits before it reports would
  loop (observed in the lab on 2026-10-23: 64 spawns in about 2 s, until Rex's window limit).
- A `/clear` in the worker pane makes a new identity there. The tasks of the old identity go to
  the new identity in the same spawn as attempt + 1 (the coordinator, 2026-10-23).
- An agent is its identity only. An ID that it had before (a legacy roster ID) gives it no task
  and no saved reply. A task that names such an ID is lost once and goes to the identity as
  attempt + 1; a reply saved under it does not replay. The coordinator accepted this loss for rows
  from before release 4.3 (2026-10-23). Observation, dated: a read-only copy of the live database
  had 0 runs and 0 operation replies at about 18:00 UTC on 2026-10-23. That count does not hold
  for later data.
- Known hub defects (hub docs, hub.workers): after a hub restart, a pane whose agent exited during
  the downtime can keep a stale identity; an agent CLI that runs under a shell that stays gives no
  exit event, so its row stays `running` with its `identity_id`. The plugin then counts that
  worker alive. The hub owner fixes both; the plugin tests do not cover the shell form.
- The plugin starts a worker with `hub.spawn` and `for: "user"`, from its own timer. It stores
  the spawn request before the call and replays it with the same key after a lost reply, so a lost
  reply never starts a second worker.
- A task has an attempt. `automations.done` needs the current attempt.
- When the worker no longer runs, its delivered tasks go back to the queue and to the next worker
  with attempt + 1. Only a definite answer counts as "no longer runs": a failed read, or a row
  that breaks the hub contract (no valid `identity_seen`, or a waiting answer for a worker that had
  an identity), keeps the worker, and the plugin tries again later.

## File triggers

A file trigger is `{kind = "file", path, glob?}`: one directory (not recursive) and a glob for the
file name (default `*`). Save expands a leading `~` with `HOME`. The hub watches the directory
(`hub.watch`, LazyRex `docs/hub.md`, "File watches").

- One run for each appearance of a matching file. A file that changes makes no new run. A file that
  is removed and comes back is a new appearance.
- Files that exist when the watch starts make no run. A disable or a directory change makes a new
  watch, so files from the time between make no run.
- At most 8 enabled file automations: the hub allows 8 watches per plugin.
- The run's task has `item` {name, path}. A run that would pass 12 KiB fails with "path too long"
  and keeps no path.
- Delivery from the hub is at least once. The record `seen/<id>/<appearance_key>` proves that an
  appearance has its run, so a repeated row makes no second run. It is deleted only when the
  appearance cannot come again: after the hub acknowledged its removal, or when its watch is gone.

## Daily schedule

The scheduled instant of a date is the first local minute on that date at or after the set time
(the hub host's time zone). On a spring-forward date, 02:30 runs at 03:00. After several missed
days, one run catches up, for the newest date. A date runs at most once. A manual run does not
change the schedule.

Observed on Rex 0.0.1792158932-g88fd41 (lab): `os.time` of a nonexistent local time gives a time
one hour earlier, and `os.date('*t').isdst` is always false. So the plugin steps forward minute by
minute and never reads `isdst`.

## Lifecycle

- Disable stops new run admission: no new run is made. Runs already admitted continue: a queued
  run can still start a worker and be delivered, and a starting or delivered run goes on.
  Enable starts the schedule from now and makes a new file watch, so the disabled time makes no run.
- Delete also deletes the run history, and frees its preset. The delete commits a fence first: the automation record
  stays as a tombstone, and no new run, start or delivery of a queued run commits after it. Then
  the plugin cancels the queued runs. A run that is starting or delivered continues until it ends;
  a lost worker's run is cancelled, not requeued. Then the plugin deletes the markers, the runs and
  the automation. Each cleanup batch is measured complete and has the state fence. A crash resumes
  the cleanup.
- Retry queues a failed, dismissed or cancelled run again. Its next start uses a new spawn key, and
  its next delivery has attempt + 1. A disabled automation refuses a retry. A file run without a
  path (path too long) refuses it too.
- Cancel takes only a queued run.
- A start without an outcome for 10 minutes becomes `unknown_start`. Dismiss ends that run, and the
  plugin never uses that start again. The pane of that start can still appear and be a duplicate
  worker; stop it with `hub.stop`. The run keeps the dismissed spawn keys in `dismissed`.
- Each new start checks the profile again. A profile that is no longer an agent profile fails the
  run before `hub.spawn`.
- A start that the hub never sent fails with an error that starts with `not_created` (hub Fix A,
  hub 89cab8f or later). Nothing of it exists, so the plugin starts it again once with a new spawn
  key, without a Retry. That is one automatic restart for each start admission: a second
  failure fails the run. Retry and the requeue of a lost worker's run are new admissions, so each
  can restart once again. A delete stops the restart: after the delete fence, the run fails. A
  disabled automation keeps its admitted runs, so their starts can still restart. Only a stored
  failed result counts; a call error never restarts. The run shows the replaced spawn key in
  `restarted`.

## Run retention

Each automation keeps its newest 100 terminal runs (done, failed, cancelled, dismissed). "Newest"
is the order in which runs ended: each terminal change takes the next sequence from the
automation's state record, in the same batch, so a clock change cannot reorder them. A retry
removes the run from that order; when the run ends again, it is the newest. Active runs are never
pruned, and pruning never deletes a file marker, so a pruned file run cannot come again.

## Storage

The plugin keeps its data in its own SQL database (hub.sql), in one table for each entity:

| Table | Key | Holds |
|---|---|---|
| `meta` | `name` | `rev` (the revision counter), `next_id` and `next_id_rev` |
| `automations` | `id` | the automation document |
| `states` | `id` | the engine state of an automation (gen, schedule, queue and end counters, deleted) |
| `runs` | `run_key` | the run document, and its `automation_id`, `status`, `q`, `t` and `agent` as columns |
| `presets` | `name` | the automation that installed the preset |
| `seen` | `seen/<id>/<appearance>` | a file marker: the appearance has its run |
| `retired` | `rt/<id>/<appearance>` | a marker whose removal came, until the marker is deleted |
| `ops` | operation key | the saved reply and fingerprint of a keyed operation |

- The document is the one authoritative value. The run columns are copies of document fields, and
  the one write function of a run sets them from the document in the same statement.
- Revisions are decimal strings. Each written row takes the next value of `meta.rev`; a write
  compares the old revision in its transaction. The counter refuses a value at or above the
  int64 maximum, and a malformed value, with no change.
- Queue keys (`q/<id>/<seq>`) and end keys (`t/<id>/<inverted seq>`) are zero padded, so the text
  order is the queue order and the end order (the newest end first). `runs.q` and `runs.t` are
  unique. A delivered run has `status = 'delivered'` and its `agent`.
- `presets.name` is the primary key, so a second install is a conflict that names the owner. The
  delete fence deletes the row only when it names that automation.
- A marker stays after its run is pruned, until the hub acknowledges the removal of its file.
- A deleted highest ID is never used again (`meta.next_id`).
- Saved replies have no expiry (the exports use `store = false` and the `ops` table). An operation
  key holds the operation kind, the caller ID and the key; a replay looks under every ID of the
  caller.
- The engine reads and writes the tables with SQL (`automations_db.lua`): one transaction for each
  engine step or operation, with its notices and its saved reply. An operation reads its rows in
  its own transaction. A cleanup or prune step reads and writes in one transaction: at most
  20 queued runs, or 50 markers or terminal runs. No transaction spans `hub.spawn` or another
  slow hub call: a start stores its request, calls the hub, then stores the result in a second,
  fenced transaction.
- The schema is one base step, `base = 13` (hub `docs/plugin-sdk.md`, "A base step"). A new
  database gets the tables above and `meta.rev` = 0, at version 13. It folds the old steps 1 to 13
  (the old step 13 deleted only the import rows of the copy from hub.store). A database at version
  13 runs nothing and keeps every row. A database at a version from 1 to 12 refuses to start, and
  nothing changes. The live database was at version 13 when the coordinator deployed main on
  2026-10-23 (about 19:28 UTC). The plugin owns the eight tables above and their four indexes
  (`runs_auto`, `runs_delivered`, `runs_q`, `runs_t`). The `lazyrex_*` objects belong to the hub
  SDK; the plugin does not make them.
- The plugin needs a hub SDK with the base step (hub main a407e08a and later). An older SDK runs
  the base as step 1 and sets a wrong `user_version`.
- After the migrations, the start checks the counters: `meta.rev` must be a valid counter, and
  `next_id` and `next_id_rev` both canonical or both absent. Otherwise the engine starts no work
  and writes nothing, each tool answers `unavailable`, and the panel says why.

## Agents

The exports are agent tools: `automations.save`, `automations.list`, `automations.run`,
`automations.set_enabled`, `automations.delete`, `automations.retry`, `automations.cancel_run`,
`automations.dismiss_start`, `automations.runs`, `automations.presets`, `automations.read` and
`automations.done`. A list page can be empty and still have `next`: follow `next` until it is
absent. `automations.list` with `deleted = true` also lists the deleting automations.
`automations.runs` gives the starting run first, then the delivered, queued and ended runs (the
newest end first); its cursor is the last position that a page read. Each
mutation takes `key`: a retry with the same key and content gives the same result; the same key
with other content is a conflict.

## Tests

The tests are Lua files in `tests/`. `lazyrex-hub test` runs them against the real hub, on an
isolated lab Rex server that it starts and stops (LazyRex `docs/testing.md`). No test touches your
own Rex server.

Automations runs on the LazyRex Plugin SDK (manifest `"sdk": "0"`) and hub.sql, on a hub whose SDK
has the base step `app.db.migrate {base = N}` (hub main a407e08a and later).
An older SDK runs the base as step 1 of a new database. The suite passes on hub main a407e08a
(observed 2026-10-23, on the Linux lab host): it uses the SQL test hooks, the test renderer and the
render counts of `renders()`.

```sh
cd ../LazyRex/hub && go build -o ~/bin/lazyrex-hub ./cmd/hub
cd ../../Automations && lazyrex-hub test
```

- deliver.lua: a daily tick starts one worker, which reads and completes its task; a second run
  goes to the running worker; a lost `hub.spawn` reply starts one worker; `done` from another agent
  or for another attempt is refused.
- file.lua: one run for each new matching file, none for an existing file or another name; a
  failed ack, a change before the ack and created_removed give no second run; a refused ack
  does not hold the delivery; a marker retires
  after its removal is acknowledged, also after a lost ack reply and a crash; a run over the budget
  fails without the path; a backlog of 120 files gives 120 runs.
- lifecycle.lua: a hub crash between delete cleanup commits (41 queued runs, 20 for each commit, a
  gate on the third SQL commit) cancels every queued run once and delivers none; a delete during a pending start
  delivers that run and cancels the queued ones; a worker loss after delete cancels and starts no
  worker; a deleted file automation loses its watch, markers and runs; a deleted automation is not
  listed and refuses changes; retry after a start failure (new spawn key) and an agent failure
  (attempt 2); disable keeps admitted runs and refuses run and retry; cancel of a queued run does
  not block the next run; `unknown_start` after 10 minutes, and dismiss lets the next run start.
- not_created.lua: a start that the hub never sent (error `not_created`) starts again once with a
  new key and delivers; a second `not_created` or another failure fails the run, never
  `unknown_start`, and Retry starts one worker with a new key; a lost reply of the restart batch
  and a hub crash after it start key /2 once; after a delete there is no restart; an
  `unknown_start` run (a written fixture) whose start fails as `not_created` is starting again. It
  needs the spawn-create fault mode `fail-sending` (hub 89cab8f or later). Not covered: a hub
  crash between the admission and the sending commits (the hub's own tests cover it), and a
  `not_created` call error when the hub cannot store the failure.
- list.lua: pages of only deleted automations (first and in the middle) keep the cursor going;
  a page limited by bytes skips no automation.
- panel.lua: the panel pages 25 automations, and a run of one on page 2 is cancelled from its
  view; a view with 25 queued runs reaches the last one on its second page; retry is disabled while
  the automation is disabled; an edit after another change is refused and says to reopen, and a
  current edit saves; a deleting automation shows only its runs, and dismiss from its view ends the
  cleanup.
- forms.lua: a new automation in two steps (profile, then the fields and its args), a refused
  submit, and Change profile; a profile that is not an agent profile shows a warning; 120 agent
  profiles in pages of at most 50; a profile with 400 args gets a refusal; an edit form with a
  4000-byte instruction and full args fits the budget.
- pump.lua: three backlogs that are ready at once (after a gate on the worker check) deliver in
  turns: no automation delivers its whole backlog before another delivers its first run.
- reload_work.lua: a file that appears while the plugin is stopped gives one run after its start,
  and a pending start replays its key once.
- large_page.lua: one watch page of 50 file runs of more than 8000 bytes each commits in one
  transaction, within the hub's transaction time; a failed page commit leaves no run and no marker.
- refresh.lua: an open profile picker shows a new agent profile with no plugin handler; a start
  refusal asks for an invalidate render of an open panel.
- transaction.lua: a failed commit of a create or of a manual run leaves no row, no revision
  change and no saved reply, and the same key then makes the change once; manual runs take the
  numbers 1 and 2 from the state, and a replay makes no run.
- schema.lua: the schema of a new database (the base step) equals the schema that the old steps
  1 to 13 make (`sqlite_master`, the columns and the index columns); a version-13 database from
  the old steps keeps every row, its revision counter and its next ID; an old key replays, and a new automation
  takes the next ID and a higher revision.
- storage.lua: a new database starts `meta.rev` at 0; an old key replays, and the next ID is
  new; while a delivery commit is held, the worker has no task
  and no notice, and after it one of each; a lost reply delivers once; a
  start with a missing or malformed `meta.rev` or next ID refuses with no write, and a restart keeps
  the rows; the revision counter refuses at the int64 maximum, above it and on a malformed value
  with no change, and a commit whose later write finds the maximum rolls back its earlier writes.
- presets.lua: the preset fields; install, replay, a second install, an edit that keeps the
  preset; a concurrent install (an injection) stores nothing; delete and reinstall, also while the
  old cleanup waits for a run; the preset through the forms and Run now starts its worker in
  `~/knowledge`; the vault inbox watch shows the grant hint.
- restart.lua (blocked-commit recovery, not an outage: an injection fails each batch of the due
  run until a crash): a blocked daily slot runs exactly once after the restart, also after a
  second crash; after a jump over several dates only the newest date is tried and runs once; a
  crash after a delete and a preset reinstall ends the old cleanup and keeps the new reservation.
  Run now through the view, cut by a crash after its batch committed and before its result
  (faults: a lost batch reply, then a gate on the replay check): the hub resumes the same
  operation after the restart, and there is exactly one run.
- runs.lua: a mixed set over byte-limited pages gives every run once, in phase order; a page of
  only skipped entries is empty and has `next`; the cursor crosses an empty phase; malformed cursors
  are refused.
- retention.lua: the newest 100 terminal runs stay and an older active run stays; a retry takes
  a new sequence; with run documents near the budget (more than one SQL reply for 101 of them),
  exactly the newest 100 stay; a clock moved back keeps the latest run; done takes a sequence, and its replay
  gives the same result; a file run pruned before its ack makes no second run; a crash between
  prune batches (a backlog written to the tables, an injection that fails the second batch)
  leaves exactly the newest 100; a retry between the prune read and its batch keeps the oldest run.
- reassign.lua: a lost worker (stopped) gives its tasks to the next
  worker as attempt 2; the old box entry and notice go, and the old attempt is refused; a new
  conversation in the worker pane gets the tasks in the same spawn; a hub crash after the loss
  (fixed by a gate on the second start) moves the task once.
- save.lua: save checks the action against the hub contract (a tab title of at most 60
  characters) and stores nothing when it refuses; the 9th enabled file automation is refused; `~`
  expands with HOME, and a path outside `watch_roots` shows the grant hint.
- schedule.lua: a date runs at its time, not before; three missed dates give one run; an
  unrelated save keeps the baseline; a time change on the same date gives no second run; enable
  after the time gives no run that date; daily, file, daily with the clock moved back gives no run
  at or before `daily_high`; on a spring-forward date 02:30 runs at 03:00.
- start.lua: an unknown start outcome (client_unavailable from `hub.spawn`) keeps the stored
  request and replays its key, so one worker starts; a definite refusal fails the run; a profile
  that is no longer an agent profile fails the run before a start, and the next run is not blocked.
- action.lua: save checks `action.cwd`; a run starts its worker in that directory; a changed
  cwd or changed args start a new worker, and the old worker keeps its task; a pending start
  across an edit opens with its stored request; an old worker's lost task starts a worker with its
  own spec; A, B, then A again starts a third worker; a lost task after 20 live tasks moves, and a
  crash keeps every holder.
- watch_reconcile.lua: a directory change moves the watch, and old watches are removed (ten
  changes stay under the limit of 8); a crash after the save, after the remove and after the ensure,
  and lost remove and ensure replies, converge; files from a disabled time make no run.
- worker.lua: a failed observation (a hub call that fails) keeps the running worker, and the step
  tries again; a stopped worker is replaced.
- identity.lua: an open worker with no identity gets no task and no second worker, and its first
  report delivers; a stop
  before the report fails the run, and Retry starts it again; a program that exits before it
  reports is started once; a delete or an action edit during the wait
  keeps the admitted run; a hub restart during the wait; no report for 10 minutes is
  `unknown_start`, and after a dismiss a late report gets nothing; a resume in another pane and an
  agent exit move the task; a legacy roster ID gets no saved reply and no task. Test limit: the
  harness cannot fake a `hub.workers` reply, so the contract check has no test.

The parity fixture (`tests/parity_fixture.lua`, manifest `test.parity_fixture`) renders the
views that open only from another view; `test.parity_routes` lists them.

The test manifest sets the plugin args `clock_file` (a file with epoch seconds: the test clock),
`tick` and `recheck` (seconds), and `settle_ms` (the watch settle time). It grants the watch root
`LAB/inbox` (`test.watch_roots`). It sets `TZ=PST8PDT` (`test.env`), so every lab has the same
time zone. Observed on Rex 0.0.1792158932-g88fd41 (lab): Rex Lua honors a zone name in `TZ`, and a
POSIX rule string (for example `PST8PDT,M3.2.0,M11.1.0`) gives UTC. A `test.env` value with a `/`
is a path, so `America/Los_Angeles` is refused. Retries use the real clock, so they continue while a test holds
the test clock still. `tests/support/fixture.lua` writes an agent profile whose worker is
a real test agent (`lazyrex-hub testagent`), so a test can call the plugin as the worker. The
pane first reports the identity `claude:w-<spawn's agent ID>`, as an agent CLI's start hook does.
