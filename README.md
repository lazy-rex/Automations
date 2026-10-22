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
- A worker runs when its `hub.workers` row has state `running` and its agent is current. In
  `hub.workers`, `status` is the pane's program status; the row's lifecycle is `state`.
- The plugin starts a worker with `hub.spawn` and `for: "user"`, from its own timer. It stores
  the spawn request before the call and replays it with the same key after a lost reply, so a lost
  reply never starts a second worker.
- A task has an attempt. `automations.done` needs the current attempt.
- When the worker no longer runs, its delivered tasks go back to the queue and to the next worker
  with attempt + 1. Only a definite answer counts as "no longer runs": a failed lookup keeps the
  worker, and the plugin tries again later.

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

The plugin keeps its data in its own SQL database (hub.sql), in one table for each entity
(automations, states, runs, presets, file markers, operation replies). Each row has its record as
a JSON document, and the fields that queries need as columns. The first start of this version
copies the hub.store records of the earlier version into the tables, one page at a time; until
the copy is done, each tool answers `unavailable` ("importing") and the panel says so. A start on
a database that the plugin does not recognize changes nothing and says why. The engine still uses
a store interface over the tables (`automations_store.lua`, a temporary adapter); SDK port plan
slice 3 replaces it with direct SQL. The plan (`docs/sdk-port.md`) has the start states, the
revision rules and the rollback procedure.

## Agents

The exports are agent tools: `automations.save`, `automations.list`, `automations.run`,
`automations.set_enabled`, `automations.delete`, `automations.retry`, `automations.cancel_run`,
`automations.dismiss_start`, `automations.runs`, `automations.presets`, `automations.read` and
`automations.done`. A list page can be empty and still have `next`: follow `next` until it is
absent. `automations.list` with `deleted = true` also lists the deleting automations.
`automations.runs` gives the starting run first, then the delivered, queued and ended runs (the
newest end first); its cursor is the last index entry that a page read. Each
mutation takes `key`: a retry with the same key and content gives the same result; the same key
with other content is a conflict.

## Tests

The tests are Lua files in `tests/`. `lazyrex-hub test` runs them against the real hub, on an
isolated lab Rex server that it starts and stops (LazyRex `docs/testing.md`). No test touches your
own Rex server.

Automations runs on the LazyRex Plugin SDK (manifest `"sdk": "0"`) and hub.sql. It needs a hub
with the SDK launcher, hub.sql, the store fence and the SQL test hooks (lab branch `hub/sql-lab`
26c751d or later; not on hub main yet), and an `sdk/lua` with the block join (ffa583f or later;
with an older SDK, the two long-list tests of save.lua fail in the SDK).

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
- lifecycle.lua: a hub crash between delete cleanup batches (near-limit runs, a gate on the third
  SQL commit) cancels every queued run once and delivers none; a delete during a pending start
  delivers that run and cancels the queued ones; a worker loss after delete cancels and starts no
  worker; a deleted file automation loses its watch, markers and runs; a deleted automation is not
  listed and refuses changes; retry after a start failure (new spawn key) and an agent failure
  (attempt 2); disable keeps admitted runs and refuses run and retry; cancel of a queued run does
  not block the next run; `unknown_start` after 10 minutes, and dismiss lets the next run start.
- not_created.lua: a start that the hub never sent (error `not_created`) starts again once with a
  new key and delivers; a second `not_created` or another failure fails the run, never
  `unknown_start`, and Retry starts one worker with a new key; a lost reply of the restart batch
  and a hub crash after it start key /2 once; after a delete there is no restart; an
  `unknown_start` run (a written fixture) whose start fails as `not_created` is starting again. It needs
  the spawn-create fault mode `fail-sending` (hub 89cab8f or later); on an older hub, such as the
  live hub fc0cd19, this file fails. Not covered: a hub crash between the admission and the
  sending commits (the hub's own tests cover it), and a `not_created` call error when the hub
  cannot store the failure.
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
- cutover.lua: the first start on an old store copies each record and saved reply exactly, with
  its rev, below the new revision counter, and the run columns equal the document; while the copy
  waits, every tool and the panel answer "importing" and nothing changes; after it, an old key
  replays under the identity and under a legacy ID, and the next ID is new; a delivery commits its
  task and notice together, also after a failed commit and a lost reply; the revision counter
  refuses at the int64 maximum and on a malformed value with no change; each unknown start state
  refuses with no write, and a start on a done copy keeps the SQL changes; a crash during the copy
  resumes from its cursor.
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
  a new sequence; a clock moved back keeps the latest run; done takes a sequence, and its replay
  gives the same result; a file run pruned before its ack makes no second run; a crash between
  prune batches (a backlog from the harness `write`, an injection that fails the second batch)
  leaves exactly the newest 100; a retry between the prune read and its batch keeps the oldest run.
- reassign.lua: a lost worker (stopped, or its identity superseded) gives its tasks to the next
  worker as attempt 2; the old box entry and notice go, and the old attempt is refused; an alias
  reads its task; a hub crash after the loss (fixed by a gate on the second start) moves the task
  once.
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

The parity fixture (`tests/parity_fixture.lua`, manifest `test.parity_fixture`) renders the
views that open only from another view; `test.parity_routes` lists them.

The test manifest sets the plugin args `clock_file` (a file with epoch seconds: the test clock),
`tick` and `recheck` (seconds), and `settle_ms` (the watch settle time). It grants the watch root
`LAB/inbox` (`test.watch_roots`). It sets `TZ=PST8PDT` (`test.env`), so every lab has the same
time zone. Observed on Rex 0.0.1792158932-g88fd41 (lab): Rex Lua honors a zone name in `TZ`, and a
POSIX rule string (for example `PST8PDT,M3.2.0,M11.1.0`) gives UTC. A `test.env` value with a `/`
is a path, so `America/Los_Angeles` is refused. Retries use the real clock, so they continue while a test holds
the test clock still. `tests/support/fixture.lua` writes an agent profile whose worker is
a real test agent (`lazyrex-hub testagent`), so a test can call the plugin as the worker.
