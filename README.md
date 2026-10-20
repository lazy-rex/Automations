# Automations

A [LazyRex](https://github.com/lazy-rex/LazyRex) plugin. An automation is a trigger and an action:

- Triggers: a schedule (daily at a local time). A new file in a directory comes next.
- Action: deliver the run to the automation's worker if it runs; else start a worker from the
  automation's agent profile, then deliver.

Status: in progress. Built: daily triggers, manual runs, the worker start and the delivery. Not
built yet: file triggers, the panel and forms, presets, delete, retry and dismiss.

## Install

Check this repository out next to LazyRex, and add the plugin to the hub config:

```json
{"name": "automations", "path": "/path/to/Automations/automations.lua",
 "notice": "Automation task. Call automations_read."}
```

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

## Daily schedule

The scheduled instant of a date is the first local minute on that date at or after the set time
(the hub host's time zone). On a spring-forward date, 02:30 runs at 03:00. After several missed
days, one run catches up, for the newest date. A date runs at most once. A manual run does not
change the schedule.

Observed on Rex 0.0.1792158932-g88fd41 (lab): `os.time` of a nonexistent local time gives a time
one hour earlier, and `os.date('*t').isdst` is always false. So the plugin steps forward minute by
minute and never reads `isdst`.

## Agents

The exports are agent tools: `automations.save`, `automations.list`, `automations.run`,
`automations.read` and `automations.done`. Each mutation takes `key`: a retry with the same key
and content gives the same result; the same key with other content is a conflict.

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
- save.lua: save checks the action against the hub contract (a tab title of at most 60
  characters) and stores nothing when it refuses.
- worker.lua: a failed observation (a hub call that fails) keeps the running worker, and the step
  tries again; a stopped worker is replaced.

The test manifest sets the plugin args `clock_file` (a file with epoch seconds: the test clock),
`tick` and `recheck` (seconds). Retries use the real clock, so they continue while a test holds
the test clock still. `tests/support/fixture.lua` writes an agent profile whose worker is
a real test agent (`lazyrex-hub testagent`), so a test can call the plugin as the worker.
