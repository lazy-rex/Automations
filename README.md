# Automations

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. An automation is a trigger and an action:

- Triggers: a new file in a directory, or a schedule (daily at a local time).
- Action: deliver the run to the automation's worker if it runs; else start a worker from the
  automation's agent profile, then deliver.

Status: in progress. Built: file and daily triggers, manual runs, the worker start, the delivery,
enable and disable, delete, retry, cancel, dismiss and run retention. Not built yet: the panel and
forms, and presets.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "automations", "path": "/path/to/Automations/automations.lua",
 "notice": "Automation task. Call automations_read.",
 "watch_roots": ["/path/to/a/watched/parent"]}
```

A file automation can watch only a directory inside `watch_roots`. The hub reads the config at
start, so restart the hub after a change. `automations.list` shows a refused watch with a hint.

## How a run reaches an agent

The plugin does not use Messaging. A run goes into the worker's task box (a record in this
plugin's store), and the same store batch sets a hub notice for the worker. The hub writes the
notice text into the worker's pane when the worker is ready. The worker reads its tasks with
`automations.read` and completes each one with `automations.done`.

- Each automation keeps its own worker (the spawn that it started). It never chooses an agent by
  profile.
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

- Disable stops new runs and new starts. Runs already queued, starting or delivered continue.
  Enable starts the schedule from now and makes a new file watch, so the disabled time makes no run.
- Delete also deletes the run history. The delete commits a fence first: the automation record
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

## Run retention

Each automation keeps its newest 100 terminal runs (done, failed, cancelled, dismissed). "Newest"
is the order in which runs ended: each terminal change takes the next sequence from the
automation's state record, in the same batch, so a clock change cannot reorder them. A retry
removes the run from that order; when the run ends again, it is the newest. Active runs are never
pruned, and pruning never deletes a file marker, so a pruned file run cannot come again.

This store layout came before the first release: a lab store from an earlier commit needs a fresh
store.

## Agents

The exports are agent tools: `automations.save`, `automations.list`, `automations.run`,
`automations.set_enabled`, `automations.delete`, `automations.retry`, `automations.cancel_run`,
`automations.dismiss_start`, `automations.runs`, `automations.read` and `automations.done`. A list
 page can be empty and still have `next`: follow `next` until it is absent. Each
mutation takes `key`: a retry with the same key and content gives the same result; the same key
with other content is a conflict.

## Tests

The tests are Lua files in `tests/`. `lazyrex-hub test` runs them against the real hub, on an
isolated lab Rex server that it starts and stops (LazyRex `docs/testing.md`). No test touches your
own Rex server.

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
  store batch) cancels every queued run once and delivers none; a delete during a pending start
  delivers that run and cancels the queued ones; a worker loss after delete cancels and starts no
  worker; a deleted file automation loses its watch, markers and runs; a deleted automation is not
  listed and refuses changes; retry after a start failure (new spawn key) and an agent failure
  (attempt 2); disable keeps admitted runs and refuses run and retry; cancel of a queued run does
  not block the next run; `unknown_start` after 10 minutes, and dismiss lets the next run start.
- list.lua: pages of only deleted automations (first and in the middle) keep the cursor going;
  a page limited by bytes skips no automation.
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
- watch_reconcile.lua: a directory change moves the watch, and old watches are removed (ten
  changes stay under the limit of 8); a crash after the save, after the remove and after the ensure,
  and lost remove and ensure replies, converge; files from a disabled time make no run.
- worker.lua: a failed observation (a hub call that fails) keeps the running worker, and the step
  tries again; a stopped worker is replaced.

The test manifest sets the plugin args `clock_file` (a file with epoch seconds: the test clock),
`tick` and `recheck` (seconds), and `settle_ms` (the watch settle time). It grants the watch root
`LAB/inbox` (`test.watch_roots`). It sets `TZ=PST8PDT` (`test.env`), so every lab has the same
time zone. Observed on Rex 0.0.1792158932-g88fd41 (lab): Rex Lua honors a zone name in `TZ`, and a
POSIX rule string (for example `PST8PDT,M3.2.0,M11.1.0`) gives UTC. A `test.env` value with a `/`
is a path, so `America/Los_Angeles` is refused. Retries use the real clock, so they continue while a test holds
the test clock still. `tests/support/fixture.lua` writes an agent profile whose worker is
a real test agent (`lazyrex-hub testagent`), so a test can call the plugin as the worker.
