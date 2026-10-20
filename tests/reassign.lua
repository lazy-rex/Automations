-- A lost worker (design v2, 5e): its delivered runs go back to the queue and to the next worker
-- with attempt + 1. The old box entry goes, the old notice row follows its box, and a done of the
-- old attempt is refused.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function automation(key)
  return alice:call('automations.save', {key = key, name = 'Reassign ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Reassign task.'}).id
end

local function delivered_again(run_key, attempt)
  return wait('run ' .. run_key .. ' attempt ' .. attempt, function()
    local run = store(run_key).value
    return run and run.status == 'delivered' and run.attempt == attempt and run
  end, 25)
end

test('a stopped worker: the task goes to a new worker as attempt 2', function()
  local id = automation('stop')
  local first = alice:call('automations.run', {id = id, key = 'stop-1'})
  local one = F.wait_status(first.run_key, 'delivered')
  local old = F.worker(one.agent)
  expect(old:call('automations.read', {}).tasks[1].attempt).to_be(1)
  expect(alice:hub('hub.stop', {spawn_id = one.spawn_id}).status).to_be('closed')
  local two = delivered_again(first.run_key, 2)
  expect(two.agent).not_to_be(one.agent)
  expect(two.lost.agent).to_be(one.agent)
  expect(two.lost.attempt).to_be(1)
  -- The run started once for each worker: the second start has its own key, ending in /2.
  expect(two.starts).to_be(2)
  expect(store('state/' .. id).value.worker.spawn_id).to_be(two.spawn_id)
  expect(store('box/' .. one.agent .. '/' .. first.run_key).rev).to_be('0')
  expect(notice(one.agent).pending).to_be(false)
  expect(notice(two.agent).pending).to_be(true)
  local new = F.worker(two.agent)
  local tasks = new:call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].attempt).to_be(2)
  expect(tasks[1].token).to_be(first.run_key .. '#2')
  -- The old attempt is refused, also from the new holder.
  expect_error(function() new:call('automations.done', {run_key = first.run_key, attempt = 1, key = 'stop-old'}) end, 'stale_delivery')
  expect(new:call('automations.done', {run_key = first.run_key, attempt = 2, key = 'stop-new'}).status).to_be('done')
  expect(notice(two.agent).pending).to_be(false)
end)

test('an alias reads its task; a superseded identity loses it, and its late done is refused', function()
  local id = automation('identity')
  local first = alice:call('automations.run', {id = id, key = 'identity-1'})
  local one = F.wait_status(first.run_key, 'delivered')
  local pane = F.worker(one.agent)
  -- The pane's first conversation takes over the spawn ID: the worker still runs, and the
  -- identity reads the task delivered to its legacy ID.
  pane:report('claude', 'automations-reassign-1')
  rex.sleep(2.5)
  expect(store(first.run_key).value.attempt).to_be(1)
  local tasks = pane:call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].run_key).to_be(first.run_key)
  -- A second conversation in the same pane: the spawn ID's alias stays with the first one, which
  -- is no longer current. The worker does not run by rule 5c, so the task moves.
  pane:report('claude', 'automations-reassign-2')
  local two = delivered_again(first.run_key, 2)
  expect(two.agent).not_to_be(one.agent)
  expect(store('box/' .. one.agent .. '/' .. first.run_key).rev).to_be('0')
  -- The old pane, now another conversation, sees nothing and cannot complete the old attempt.
  expect(#pane:call('automations.read', {}).tasks).to_be(0)
  expect_error(function() pane:call('automations.done', {run_key = first.run_key, attempt = 1, key = 'identity-late'}) end, 'stale_delivery')
  expect(store(first.run_key).value.status).to_be('delivered')
  F.worker(two.agent):call('automations.done', {run_key = first.run_key, attempt = 2, key = 'identity-done'})
end)

test('two delivered tasks of a lost worker both move', function()
  local id = automation('two')
  local a = alice:call('automations.run', {id = id, key = 'two-1'})
  local one = F.wait_status(a.run_key, 'delivered')
  local b = alice:call('automations.run', {id = id, key = 'two-2'})
  expect(F.wait_status(b.run_key, 'delivered').agent).to_be(one.agent)
  expect(alice:hub('hub.stop', {spawn_id = one.spawn_id}).status).to_be('closed')
  local ra, rb = delivered_again(a.run_key, 2), delivered_again(b.run_key, 2)
  expect(ra.agent).to_be(rb.agent)
  expect(ra.agent).not_to_be(one.agent)
  expect(notice(one.agent).pending).to_be(false)
  expect(#F.worker(ra.agent):call('automations.read', {}).tasks).to_be(2)
end)

-- Restart coverage for the requeue: the hub crashes after the requeue and the new start admission
-- committed, and before hub.spawn ran. A gate on that spawn key fixes the crash point: a crash
-- inside the hub's spawn window leaves the start pending (hub docs, "spawn intent ... stays
-- unresolved"). lifecycle.lua covers recovery from a pending start (a dropped spawn) through
-- unknown_start and dismiss; it does not reproduce that crash timing. After the restart
-- the stored key replays, and the run moves exactly once, to exactly one new worker. The hub
-- keeps faults in memory, so the gate is gone after the restart.
test('a hub crash after a worker loss moves the task once', function()
  local id = automation('crash')
  local first = alice:call('automations.run', {id = id, key = 'crash-1'})
  local one = F.wait_status(first.run_key, 'delivered')
  F.worker(one.agent)
  local before = F.running('worker')
  local key = 'automations/spawn/' .. first.run_key .. '/2'
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = key})
  expect(alice:hub('hub.stop', {spawn_id = one.spawn_id}).status).to_be('closed')
  wait('the gated second start', function() return fault_fired(gate) end, 20)
  local held = store(first.run_key).value
  expect(held.status).to_be('starting')
  expect(held.starts).to_be(2)
  expect(held.attempt).to_be(1)
  expect(store('state/' .. id).value.spawning.request.key).to_be(key)
  expect(store('box/' .. one.agent .. '/' .. first.run_key).rev).to_be('0')
  expect(store('dv/' .. id .. '/' .. first.run_key).rev).to_be('0')
  hub:restart({crash = true})
  local two = delivered_again(first.run_key, 2)
  expect(two.agent).not_to_be(one.agent)
  rex.sleep(3)
  expect(store(first.run_key).value.attempt).to_be(2)
  expect(F.running('worker')).to_be(before)
  expect(notice(one.agent).pending).to_be(false)
end)
