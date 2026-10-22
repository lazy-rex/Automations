-- A start that the hub never sent (hub Fix A, hub main 8aa9426): hub.spawn answers status failed
-- with an error that starts with not_created. Nothing was created, so the plugin starts it again
-- once with a new key (the coordinator's decision: one automatic retry per start admission). A
-- second failure fails the run. Needs the spawn-create fault mode fail-sending (hub 89cab8f or
-- later). Not covered here: a hub crash between the admission and the sending commits (the hub's
-- own tests cover the restart path), and a not_created call error when the hub cannot store the
-- failure (a call error never gives the retry).
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function spawn_key(run_key, n) return 'automations/spawn/' .. run_key .. '/' .. n end
local function not_created(w) return w.state == 'failed' and type(w.error) == 'string' and w.error:sub(1, 12) == 'not_created:' end
local function count_not_created()
  local n = 0
  for _, w in ipairs(F.workers('worker')) do if not_created(w) then n = n + 1 end end
  return n
end
local function automation(key)
  return alice:call('automations.save', {key = key, name = 'Not created ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Not created task.'}).id
end
local function run_now(id, key)
  local run_key = 'run/' .. id .. '/m/000001'
  expect(alice:call('automations.run', {id = id, key = key}).run_key).to_be(run_key)
  return run_key
end
-- wait_for waits for a run status. Each poll sees a status other than unknown_start. A poll does
-- not see every state, so the source review covers the rest: a failed result never takes the
-- pending branch.
local function wait_for(run_key, status)
  return wait('run ' .. run_key .. ' to be ' .. status, function()
    local r = F.run(run_key)
    expect(r.status ~= 'unknown_start').to_be(true)
    return r.status == status and r
  end, 30)
end
-- restarted checks the committed state of the automatic retry while a gate holds key /2.
local function restarted(id, run_key)
  local run = F.run(run_key)
  expect(run.status).to_be('starting')
  expect(run.starts).to_be(2)
  expect(run.restarted).to_be(spawn_key(run_key, 1))
  local sp = store('state/' .. id).value.spawning
  expect(sp.auto).to_be(true)
  expect(sp.request.key).to_be(spawn_key(run_key, 2))
end
local function listed(id, run_key)
  for _, r in ipairs(F.runs(alice, id)) do if r.run_key == run_key then return r end end
end

test('two not_created starts fail the run; Retry gets a new admission and starts one worker', function()
  local id = automation('two')
  local run_key = 'run/' .. id .. '/m/000001'
  local q = string.format('q/%s/%012d', id, 1)
  local before, running = #F.workers('worker'), F.running('worker')
  local f1 = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key(run_key, 1)})
  local f2 = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key(run_key, 2)})
  run_now(id, 'two-run')
  local run = wait_for(run_key, 'failed')
  expect(fault_fired(f1)).to_be(true)
  expect(fault_fired(f2)).to_be(true)
  expect(run.error:sub(1, 12)).to_be('not_created:')
  expect(run.starts).to_be(2)
  expect(run.restarted).to_be(spawn_key(run_key, 1))
  expect(listed(id, run_key).restarted).to_be(spawn_key(run_key, 1))
  expect(run.dismissed).to_be(nil)
  expect(run.q).to_be(nil)
  expect(store(q).rev).to_be('0')
  expect(store('state/' .. id).value.spawning).to_be(nil)
  expect(store(run.t).value.run).to_be(run_key)
  -- The hub lists both starts as failed, and no worker of them runs.
  expect(#F.workers('worker')).to_be(before + 2)
  expect(count_not_created()).to_be(2)
  expect(F.running('worker')).to_be(running)

  -- A gate holds the third start, so the test reads its stored key before it opens.
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(run_key, 3)})
  alice:call('automations.retry', {run_key = run_key, key = 'two-retry'})
  wait('the gated third start', function() return fault_fired(gate) end, 10)
  local sp = store('state/' .. id).value.spawning
  expect(sp.request.key).to_be(spawn_key(run_key, 3))
  expect(sp.auto).to_be(nil)
  fault_release(gate)
  run = F.wait_status(run_key, 'delivered')
  expect(run.starts).to_be(3)
  expect(run.attempt).to_be(1)
  expect(run.retries).to_be(1)
  expect(run.t).to_be(nil)
  expect(F.running('worker')).to_be(running + 1)
  expect(#F.workers('worker')).to_be(before + 3)
  expect(count_not_created()).to_be(2)
  local tasks = F.worker(run.agent):call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].run_key).to_be(run_key)
end)

test('one not_created start starts again with a new key, without Retry', function()
  local id = automation('one')
  local before, running, failed = #F.workers('worker'), F.running('worker'), count_not_created()
  local f = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key('run/' .. id .. '/m/000001', 1)})
  local run_key = run_now(id, 'one-run')
  local run = wait_for(run_key, 'delivered')
  expect(fault_fired(f)).to_be(true)
  expect(run.starts).to_be(2)
  expect(run.restarted).to_be(spawn_key(run_key, 1))
  expect(listed(id, run_key).restarted).to_be(spawn_key(run_key, 1))
  expect(run.retries).to_be(nil)
  expect(run.attempt).to_be(1)
  expect(F.running('worker')).to_be(running + 1)
  expect(#F.workers('worker')).to_be(before + 2)
  expect(count_not_created()).to_be(failed + 1)
  expect(#F.worker(run.agent):call('automations.read', {}).tasks).to_be(1)
end)

test('a not_created start, then another failure: the run fails with no third start', function()
  local id = automation('other')
  local run_key = 'run/' .. id .. '/m/000001'
  local before, running = #F.workers('worker'), F.running('worker')
  local f1 = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key(run_key, 1)})
  local f2 = fault({point = 'spawn-create', mode = 'refuse', op = spawn_key(run_key, 2)})
  run_now(id, 'other-run')
  local run = wait_for(run_key, 'failed')
  expect(fault_fired(f1)).to_be(true)
  expect(fault_fired(f2)).to_be(true)
  expect(run.starts).to_be(2)
  expect(run.restarted).to_be(spawn_key(run_key, 1))
  expect(run.error:sub(1, 11) ~= 'not_created').to_be(true)
  expect(store('state/' .. id).value.spawning).to_be(nil)
  rex.sleep(3)
  expect(#F.workers('worker')).to_be(before + 2)
  expect(F.running('worker')).to_be(running)
  expect(F.run(run_key).starts).to_be(2)
end)

-- The lost reply belongs to the retry batch: the batch fault is armed only after a gate holds
-- start 1, and the committed state is read while a gate holds start 2.
test('a lost reply of the retry batch: the stored request /2 starts once', function()
  local id = automation('lost')
  local run_key = 'run/' .. id .. '/m/000001'
  local before, running = #F.workers('worker'), F.running('worker')
  local g1 = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(run_key, 1)})
  run_now(id, 'lost-run')
  wait('the gated first start', function() return fault_fired(g1) end, 10)
  local f1 = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key(run_key, 1)})
  local lost = fault({point = 'action', action = 'hub.store.batch', when = 'after', mode = 'lose-reply'})
  local g2 = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(run_key, 2)})
  fault_release(g1)
  wait('the gated second start', function() return fault_fired(g2) end, 20)
  expect(fault_fired(f1)).to_be(true)
  expect(fault_fired(lost)).to_be(true)
  restarted(id, run_key)
  fault_release(g2)
  local run = wait_for(run_key, 'delivered')
  expect(run.starts).to_be(2)
  expect(F.running('worker')).to_be(running + 1)
  expect(#F.workers('worker')).to_be(before + 2)
end)

-- The durable allowance against a second not_created is the first test; this one shows that the
-- committed request /2 is used after a crash, once.
test('a crash after the retry batch: the new hub starts /2 once, and there is no /3', function()
  local id = automation('crash')
  local run_key = 'run/' .. id .. '/m/000001'
  local before, running, failed = #F.workers('worker'), F.running('worker'), count_not_created()
  local f1 = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key(run_key, 1)})
  local g2 = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(run_key, 2)})
  run_now(id, 'crash-run')
  wait('the gated second start', function() return fault_fired(g2) end, 20)
  expect(fault_fired(f1)).to_be(true)
  restarted(id, run_key)
  hub:restart({crash = true})
  local run = F.wait_status(run_key, 'delivered', 30)
  expect(run.starts).to_be(2)
  expect(run.restarted).to_be(spawn_key(run_key, 1))
  expect(F.running('worker')).to_be(running + 1)
  expect(#F.workers('worker')).to_be(before + 2)
  expect(count_not_created()).to_be(failed + 1)
end)

-- Delete fences the retry: no new key after a delete. The cleanup purges the failed run, so the
-- test checks the hub rows after the purge.
test('a delete while start 1 waits: not_created gives no second start, and the cleanup ends', function()
  local id = automation('delete')
  local run_key = 'run/' .. id .. '/m/000001'
  local before, running, failed = #F.workers('worker'), F.running('worker'), count_not_created()
  local g1 = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(run_key, 1)})
  run_now(id, 'delete-run')
  wait('the gated first start', function() return fault_fired(g1) end, 10)
  alice:call('automations.delete', {id = id, key = 'delete-delete'})
  expect(store('state/' .. id).value.deleted).to_be(true)
  local f1 = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key(run_key, 1)})
  fault_release(g1)
  wait('the purge', function()
    return store('auto/' .. id).rev == '0' and store('state/' .. id).rev == '0' and store(run_key).rev == '0'
  end, 30)
  expect(fault_fired(f1)).to_be(true)
  expect(#F.workers('worker')).to_be(before + 1)
  expect(count_not_created()).to_be(failed + 1)
  expect(F.running('worker')).to_be(running)
  rex.sleep(5)
  expect(#F.workers('worker')).to_be(before + 1)
end)
