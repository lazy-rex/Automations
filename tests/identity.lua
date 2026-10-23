-- A worker's identity: the plugin delivers to the current identity in the worker's pane
-- (hub.workers {spawn_id}: identity_id, identity_seen). An open spawn can have no identity yet:
-- the admitted start waits for it, keeps its run, and starts no second worker. The silent
-- profile reports nothing, so a test reports for it (pane:report, as an agent CLI's hook).
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
local list = F.profile_list()
list[#list + 1] = F.silent()
H.write_profiles({profiles = list})
local T0 = F.at(2026, 11, 3, 10, 0)
F.set_clock(T0)
local alice = agent('alice')

local function automation(key, profile)
  return alice:call('automations.save', {key = key, name = 'Identity ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = profile or 'silent'}, instruction = 'Identity task.'}).id
end
local function run_now(id, key) return alice:call('automations.run', {id = id, key = key}).run_key end
-- opened waits until the admitted start has its open spawn, and returns the hub.workers row.
local function opened(id)
  local sid = wait('the open spawn of automation ' .. id, function()
    local st = F.state(id)
    return st and st.spawning and st.spawning.spawn_id
  end, 20)
  return alice:hub('hub.workers', {spawn_id = sid}).workers[1]
end
local function attempt(run_key, n)
  return wait('run ' .. run_key .. ' attempt ' .. n, function()
    local r = F.run(run_key)
    return r.status == 'delivered' and r.attempt == n and r
  end, 25)
end

test('an open worker with no identity gets no task and no second worker; its first report delivers', function()
  local id = automation('wait')
  local first = run_now(id, 'wait-1')
  local row = opened(id)
  expect(row.identity_id).to_be(nil)
  expect(row.identity_seen).to_be(false)
  local second = run_now(id, 'wait-2')
  rex.sleep(3)
  expect(F.run(first).status).to_be('starting')
  expect(F.run(second).status).to_be('queued')
  expect(#F.workers('silent')).to_be(1)
  local pane = F.worker(row.agent_id)
  pane:report('claude', 'automations-identity-wait')
  local one = F.wait_status(first, 'delivered')
  expect(one.agent).to_be('claude:automations-identity-wait')
  expect(one.spawn_id).to_be(row.spawn_id)
  expect(one.attempt).to_be(1)
  expect(F.state(id).worker.spawn_id).to_be(row.spawn_id)
  expect(F.state(id).worker.agent_id).to_be(nil)
  local two = F.wait_status(second, 'delivered')
  expect(two.agent).to_be(one.agent)
  expect(#F.workers('silent')).to_be(1)
  -- The worker reads its tasks as the identity.
  expect(#pane:call('automations.read', {}).tasks).to_be(2)
end)

-- A stop before the first report: nothing was delivered. The run goes back to its place at the
-- head of the queue with no agent and no attempt, and the next start has a new key.
test('a worker stopped before its first report: the run is queued again at the head, with a new start', function()
  local id = automation('stop')
  local first = run_now(id, 'stop-1')
  local row = opened(id)
  local second = run_now(id, 'stop-2')
  local q, tries = F.run(first).q, F.run(first).attempt
  expect(alice:hub('hub.stop', {spawn_id = row.spawn_id}).status).to_be('closed')
  local run = wait('the second start of ' .. first, function()
    local r = F.run(first)
    return r.starts == 2 and r
  end, 20)
  expect(run.unstarted.spawn_id).to_be(row.spawn_id)
  expect(run.unstarted.key).to_be('automations/spawn/' .. first .. '/1')
  expect(run.q).to_be(q)
  expect(run.agent).to_be(nil)
  expect(run.attempt).to_be(tries)
  expect(run.lost).to_be(nil)
  expect(F.run(second).status).to_be('queued')
  expect(F.state(id).spawning.run).to_be(first)
  expect(F.state(id).spawning.request.key).to_be('automations/spawn/' .. first .. '/2')
end)

-- A delete during the wait: the admitted run is not cancelled and is delivered at the report;
-- the queued run is cancelled. A stop before the report after a delete cancels the run.
test('a delete during the identity wait keeps the admitted run; a stop then cancels it', function()
  local id = automation('delete')
  local first = run_now(id, 'delete-1')
  local row = opened(id)
  local second = run_now(id, 'delete-2')
  alice:call('automations.delete', {id = id, key = 'delete-del'})
  F.wait_status(second, 'cancelled')
  expect(F.run(first).status).to_be('starting')
  F.worker(row.agent_id):report('claude', 'automations-identity-delete')
  local one = F.wait_status(first, 'delivered')
  expect(one.agent).to_be('claude:automations-identity-delete')

  local id2 = automation('delete-stop')
  local third = run_now(id2, 'delete-stop-1')
  local row2 = opened(id2)
  alice:call('automations.delete', {id = id2, key = 'delete-stop-del'})
  expect(alice:hub('hub.stop', {spawn_id = row2.spawn_id}).status).to_be('closed')
  local run = F.wait_status(third, 'cancelled')
  expect(run.error).to_be('worker gone before it started, after delete')
  expect(run.q).to_be(nil)
  expect(run.unstarted.spawn_id).to_be(row2.spawn_id)
  expect(run.agent).to_be(nil)
end)

-- An action edit during the wait: the admitted run goes to its own worker with the spec it
-- started with; the run of the new action starts its own worker.
test('an action edit during the identity wait starts no replacement for the admitted run', function()
  local id = automation('edit')
  local first = run_now(id, 'edit-1')
  local row = opened(id)
  local a = F.view(alice, id)
  alice:call('automations.save', {id = id, if_rev = a.rev, key = 'edit-save-2', name = a.name, trigger = a.trigger,
    action = {profile = 'worker'}, instruction = a.instruction})
  local second = run_now(id, 'edit-2')
  rex.sleep(3)
  expect(F.run(first).status).to_be('starting')
  expect(F.run(second).status).to_be('queued')
  expect(#F.workers('worker')).to_be(0)
  F.worker(row.agent_id):report('claude', 'automations-identity-edit')
  expect(F.wait_status(first, 'delivered').spawn_id).to_be(row.spawn_id)
  local two = F.wait_status(second, 'delivered')
  expect(two.spawn_id).not_to_be(row.spawn_id)
  expect(F.state(id).worker.spawn_id).to_be(two.spawn_id)
end)

test('a hub restart during the identity wait keeps the start; the report then delivers', function()
  local id = automation('restart')
  local first = run_now(id, 'restart-1')
  local row = opened(id)
  hub:restart({crash = true})
  rex.sleep(2)
  expect(F.run(first).status).to_be('starting')
  expect(F.state(id).spawning.spawn_id).to_be(row.spawn_id)
  F.worker(row.agent_id):report('claude', 'automations-identity-restart')
  expect(F.wait_status(first, 'delivered').agent).to_be('claude:automations-identity-restart')
end)

-- No report for 10 minutes: unknown_start, as a pending start. After the dismiss, a late report
-- in that pane gets nothing.
test('an open worker with no report for 10 minutes is unknown_start; after a dismiss a late report gets nothing', function()
  local id = automation('late')
  local first = run_now(id, 'late-1')
  local row = opened(id)
  F.set_clock(T0 + 601)
  F.wait_status(first, 'unknown_start')
  expect(alice:call('automations.dismiss_start', {run_key = first, key = 'late-dismiss'}).status).to_be('dismissed')
  local pane = F.worker(row.agent_id)
  pane:report('claude', 'automations-identity-late')
  rex.sleep(3)
  expect(F.run(first).status).to_be('dismissed')
  expect(F.run(first).agent).to_be(nil)
  expect(#pane:call('automations.read', {}).tasks).to_be(0)
  F.set_clock(T0)
end)

-- The conversation resumes in another pane: the worker's pane has no identity_id, and
-- identity_seen is true (state running). The worker ended for the plugin: its task moves to a
-- new worker, and the identity, now in the other pane, cannot complete the old attempt.
test('a conversation that resumes in another pane: the worker ended, and its task moves', function()
  local id = automation('resume', 'worker')
  local first = run_now(id, 'resume-1')
  local one = F.wait_status(first, 'delivered')
  local bob = agent('bob', {report = false})
  bob:report({kind = 'claude', conversation_id = one.agent:sub(#'claude:' + 1), source = 'resume'})
  local row = alice:hub('hub.workers', {spawn_id = one.spawn_id}).workers[1]
  expect(row.state).to_be('running')
  expect(row.identity_id).to_be(nil)
  expect(row.identity_seen).to_be(true)
  local two = attempt(first, 2)
  expect(two.spawn_id).not_to_be(one.spawn_id)
  expect(two.lost.agent).to_be(one.agent)
  expect(F.state(id).worker.spawn_id).to_be(two.spawn_id)
  expect_error(function() bob:call('automations.done', {run_key = first, attempt = 1, key = 'resume-late'}) end, 'stale_delivery')
end)

-- The agent process ends: state exited (the test agent is the pane's process), or the spawn is
-- closed with its pane. Either way the worker is gone, and its task moves to a new worker.
-- Test limit: a process end under a shell that stays (state running) is a known hub defect (hub
-- docs, hub.workers); the resume test above gives the running form of an ended worker.
test('a worker whose agent exits: its task moves to a new worker', function()
  local id = automation('exit', 'worker')
  local first = run_now(id, 'exit-1')
  local one = F.wait_status(first, 'delivered')
  F.worker(one.agent):exit()
  local two = attempt(first, 2)
  expect(two.spawn_id).not_to_be(one.spawn_id)
end)

-- An ID that the worker had before its identity (the spawn's roster ID, which the hub still names
-- in ctx.aliases) gives it nothing: a reply saved under it does not replay, and a task delivered
-- to it is not the worker's. Such a task is lost once and goes to the identity as attempt + 1.
-- The coordinator accepted this loss for rows from before 4.3 (2026-10-23).
test('a legacy roster ID gives the worker no saved reply and no task; its delivered run moves once', function()
  local id = automation('legacy', 'worker')
  local first = run_now(id, 'legacy-1')
  local one = F.wait_status(first, 'delivered')
  local roster = alice:hub('hub.workers', {spawn_id = one.spawn_id}).workers[1].agent_id
  local w = F.worker(one.agent)
  local function key(k) return 'run/' .. #roster .. ':' .. roster .. #k .. ':' .. k end
  F.sql_write('INSERT INTO ops (key, fingerprint, reply) VALUES (?, ?, ?)',
    {key('legacy-op'), 'run-v1/' .. rex.json.encode({id = id}), rex.json.encode({run_key = 'run/' .. id .. '/m/000099'})})
  local fresh = w:call('automations.run', {id = id, key = 'legacy-op'})
  expect(fresh.run_key).not_to_be('run/' .. id .. '/m/000099')
  -- A delivered run of the roster ID: the worker does not list it, and the plugin moves it.
  local run, rev = F.run(first), F.rev('runs', first)
  run.agent = roster
  F.write({{tbl = 'runs', key = first, if_rev = rev, value = run}})
  -- The plugin can move it at once, so a listed task of that run is the new attempt.
  for _, t in ipairs(w:call('automations.read', {}).tasks) do
    if t.run_key == first then expect(t.attempt).to_be(2) end
  end
  local two = attempt(first, 2)
  expect(two.agent).to_be(one.agent)
  expect(two.lost.agent).to_be(roster)
end)
