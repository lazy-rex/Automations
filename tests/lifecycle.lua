-- Lifecycle (design v2, 5f, 5g and section 9; amendment 1, B3): delete, set_enabled, retry,
-- cancel_run and dismiss_start. Delete is a fence, then a cleanup in bounded commits. The
-- decision "Automation delete also deletes its run history" (2026-10-20): the runs go after the
-- active work ends.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
local T0 = F.at(2026, 11, 3, 10, 0)
F.set_clock(T0)
local alice = agent('alice')

-- A daily automation at 09:00: the clock is past 09:00 at save, so only manual runs come.
local function automation(key, action, instruction)
  return alice:call('automations.save', {key = key, name = 'Life ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = action or {profile = 'worker'}, instruction = instruction or 'Life task.'}).id
end
local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function spawn_key(run_key, starts) return 'automations/spawn/' .. run_key .. '/' .. (starts or 1) end
local function qkey(id, n) return string.format('q/%s/%012d', id, n) end
local function run_now(id, key) return alice:call('automations.run', {id = id, key = key}).run_key end
local function gone(id)
  return wait('automation ' .. id .. ' to be deleted', function()
    return F.state(id) == nil and F.auto(id) == nil
  end, 30)
end

-- The reviewer's crash boundary for B3. A cleanup commit cancels at most 20 queued runs
-- (CLEANUP_RUNS), so 41 queued runs need three commits. A dropped spawn holds the first run in
-- starting, so the others stay queued. A gate on the third SQL commit (1: the fence, 2: the first
-- cleanup commit) stops the cleanup between commits; the hub crashes there. The hub keeps faults
-- in memory, so the gate is gone after the restart. This test is first in the file: no other
-- automation commits during it.
local QUEUED = 41
test('a crash between delete cleanup batches cancels every queued run once and delivers none', function()
  local id = automation('crash')
  local first = manual(id, 1)
  local drop = fault({point = 'spawn-create', mode = 'drop', op = spawn_key(first)})
  expect(run_now(id, 'crash-1')).to_be(first)
  wait('the dropped spawn', function() return fault_fired(drop) end, 10)
  expect(F.wait_status(first, 'starting').starts).to_be(1)
  for n = 2, QUEUED + 1 do run_now(id, 'crash-' .. n) end
  for n = 2, QUEUED + 1 do
    expect(F.run(manual(id, n)).status).to_be('queued')
    expect(F.queued(qkey(id, n))).to_be(manual(id, n))
  end
  local gate = fault({point = 'action', action = 'hub.sql.commit', when = 'before', mode = 'gate', nth = 3})
  expect(alice:call('automations.delete', {id = id, key = 'crash-delete'}).status).to_be('deleting')
  wait('the gated third commit', function() return fault_fired(gate) end, 10)
  expect(F.auto(id).deleted).to_be(true)
  expect(F.state(id).deleted).to_be(true)
  -- The first cleanup commit cancelled the first 20 in queue order; the others are queued.
  for n = 2, QUEUED + 1 do
    local run = F.run(manual(id, n))
    if n <= 21 then
      expect(run.status).to_be('cancelled')
      expect(F.queued(qkey(id, n))).to_be(nil)
    else
      expect(run.status).to_be('queued')
      expect(F.queued(qkey(id, n))).not_to_be(nil)
    end
  end
  hub:restart({crash = true})
  wait('every queued run to be cancelled', function()
    for n = 2, QUEUED + 1 do
      if F.run(manual(id, n)).status ~= 'cancelled' then return false end
    end
    return true
  end, 30)
  -- Each run is cancelled once: one terminal sequence each, all different.
  local seqs = {}
  for n = 2, QUEUED + 1 do
    local run = F.run(manual(id, n))
    expect(run.error).to_be('automation deleted')
    expect(run.agent).to_be(nil)
    expect(run.attempt).to_be(0)
    expect(F.queued(qkey(id, n))).to_be(nil)
    expect(seqs[run.tseq]).to_be(nil)
    seqs[run.tseq] = true
  end
  expect(F.running('worker')).to_be(0)
  -- The started run continues after the delete. Its start has no outcome; dismiss it, and the
  -- cleanup ends.
  if F.run(first).status == 'starting' then
    F.set_clock(T0 + 601)
    F.wait_status(first, 'unknown_start')
    alice:call('automations.dismiss_start', {run_key = first, key = 'crash-dismiss'})
  end
  gone(id)
  for n = 1, QUEUED + 1 do expect(F.run(manual(id, n))).to_be(nil) end
  expect(#sql('SELECT run_key FROM runs WHERE automation_id = ?', {id})).to_be(0)
  F.set_clock(T0)
end)

-- Delete while a start waits: the stored request still replays after the delete, and its open
-- delivers exactly that run (design v2, 5f). A gate on hub.spawn holds the request.
test('a delete during a pending start: the start delivers its run, and queued runs are cancelled', function()
  local id = automation('pending')
  local first = manual(id, 1)
  local before = #F.workers('worker')
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(first)})
  run_now(id, 'pending-1')
  wait('the gated spawn', function() return fault_fired(gate) end, 10)
  local second = run_now(id, 'pending-2')
  alice:call('automations.delete', {id = id, key = 'pending-delete'})
  expect(F.wait_status(second, 'cancelled').error).to_be('automation deleted')
  fault_release(gate)
  local run = F.wait_status(first, 'delivered')
  expect(#F.workers('worker')).to_be(before + 1)
  local worker = F.worker(run.agent)
  local tasks = worker:call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].run_key).to_be(first)
  rex.sleep(2)
  expect(F.state(id)).not_to_be(nil)
  worker:call('automations.done', {run_key = first, attempt = 1, key = 'pending-done'})
  gone(id)
  expect(F.run(first)).to_be(nil)
  expect(#F.workers('worker')).to_be(before + 1)
end)

-- Worker loss after delete (B3): the delivered runs are cancelled, not requeued, and no worker
-- starts.
test('a worker loss after delete cancels the delivered runs and starts no worker', function()
  local id = automation('loss')
  local a = run_now(id, 'loss-1')
  local one = F.wait_status(a, 'delivered')
  local b = run_now(id, 'loss-2')
  expect(F.wait_status(b, 'delivered').agent).to_be(one.agent)
  alice:call('automations.delete', {id = id, key = 'loss-delete'})
  rex.sleep(2)
  expect(F.run(a).status).to_be('delivered')
  local before = F.running('worker')
  -- Batches 1 and 2 cancel the two runs; the gate holds the purge, so the runs can be read.
  local gate = fault({point = 'action', action = 'hub.sql.commit', when = 'before', mode = 'gate', nth = 3})
  expect(alice:hub('hub.stop', {spawn_id = one.spawn_id}).status).to_be('closed')
  wait('the gated purge', function() return fault_fired(gate) end, 20)
  for _, k in ipairs({a, b}) do
    local run = F.run(k)
    expect(run.status).to_be('cancelled')
    expect(run.error).to_be('worker lost after delete')
    expect(run.attempt).to_be(1)
    expect(F.held(one.agent, k)).to_be(nil)
  end
  expect(notice(one.agent).pending).to_be(false)
  fault_release(gate)
  gone(id)
  rex.sleep(2)
  expect(F.running('worker')).to_be(before - 1)
end)

-- A deleted file automation: the reconcile removes its watch, and the cleanup deletes its
-- markers and runs.
test('delete of a file automation removes its watch, markers and runs', function()
  local dir = F.dir('deleted')
  local id = alice:call('automations.save', {key = 'file', name = 'Life file', trigger = {kind = 'file', path = dir, glob = '*.md'},
    action = {profile = 'worker'}, instruction = 'File task.'}).id
  F.watching(alice, id)
  F.put(dir .. '/a.md')
  local runs = F.wait_runs(alice, id, 1)
  local run = F.wait_status(runs[1].run_key, 'delivered')
  local marker = 'seen/' .. id .. '/' .. runs[1].run_key:match('/f/(.+)$')
  expect(F.seen(marker)).not_to_be(nil)
  F.worker(run.agent):call('automations.done', {run_key = runs[1].run_key, attempt = 1, key = 'file-done'})
  alice:call('automations.delete', {id = id, key = 'file-delete'})
  gone(id)
  expect(F.seen(marker)).to_be(nil)
  expect(F.run(runs[1].run_key)).to_be(nil)
  -- The watch is gone: a new file makes no run.
  F.put(dir .. '/b.md')
  rex.sleep(3)
  expect(#alice:call('automations.runs', {id = id}).runs).to_be(0)
end)

test('a deleted automation is not listed, and every change to it is refused', function()
  local id = automation('refused')
  local r = alice:call('automations.delete', {id = id, key = 'refused-delete'})
  -- A replay with the same key gives the same result; other content is a conflict.
  expect(alice:call('automations.delete', {id = id, key = 'refused-delete'}).status).to_be(r.status)
  expect(F.view(alice, id)).to_be(nil)
  expect_error(function() alice:call('automations.run', {id = id, key = 'refused-run'}) end, 'not_found')
  expect_error(function() alice:call('automations.set_enabled', {id = id, enabled = false, key = 'refused-off'}) end, 'not_found')
  expect_error(function() alice:call('automations.delete', {id = id, key = 'refused-delete-2'}) end, 'not_found')
  expect_error(function() alice:call('automations.save', {id = id, if_rev = '1', key = 'refused-save', name = 'x', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'x'}) end, 'not_found')
  gone(id)
end)

-- retry (B7): a start failure retries with a new spawn key; an agent failure retries with
-- attempt + 1.
test('retry queues a failed run again: a new spawn key after a start failure, attempt 2 after an agent failure', function()
  local id = automation('retry')
  local first = manual(id, 1)
  local refuse = fault({point = 'spawn-create', mode = 'refuse', op = spawn_key(first)})
  run_now(id, 'retry-1')
  F.wait_status(first, 'failed')
  expect(fault_fired(refuse)).to_be(true)
  local r = alice:call('automations.retry', {run_key = first, key = 'retry-a'})
  expect(r.status).to_be('queued')
  expect(alice:call('automations.retry', {run_key = first, key = 'retry-a'}).status).to_be('queued')
  local run = F.wait_status(first, 'delivered')
  expect(run.starts).to_be(2)
  expect(run.attempt).to_be(1)
  expect(run.retries).to_be(1)
  expect(F.state(id).spawning).to_be(nil)
  expect_error(function() alice:call('automations.retry', {run_key = first, key = 'retry-delivered'}) end, 'not_retryable')
  local worker = F.worker(run.agent)
  worker:call('automations.done', {run_key = first, attempt = 1, key = 'retry-fail', outcome = 'failed', summary = 'No.'})
  alice:call('automations.retry', {run_key = first, key = 'retry-b'})
  run = F.wait_status(first, 'delivered')
  expect(run.attempt).to_be(2)
  expect(run.summary).to_be(nil)
  expect(run.agent).to_be(worker.id)
  worker:call('automations.done', {run_key = first, attempt = 2, key = 'retry-ok'})
  expect(F.wait_status(first, 'done').attempt).to_be(2)
  expect_error(function() alice:call('automations.retry', {run_key = first, key = 'retry-done'}) end, 'not_retryable')
  expect_error(function() alice:call('automations.retry', {run_key = manual(id, 9), key = 'retry-a'}) end, 'conflict')
end)

-- Disable stops new admission only (design v2, 5f): a run already queued continues. A disabled
-- automation refuses run and retry.
test('disable keeps admitted runs going and refuses new runs and retries', function()
  local id = automation('off')
  local first, second = manual(id, 1), manual(id, 2)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(first)})
  run_now(id, 'off-1')
  wait('the gated spawn', function() return fault_fired(gate) end, 10)
  run_now(id, 'off-2')
  local r = alice:call('automations.set_enabled', {id = id, enabled = false, key = 'off'})
  expect(alice:call('automations.set_enabled', {id = id, enabled = false, key = 'off'}).rev).to_be(r.rev)
  expect(F.view(alice, id).enabled).to_be(false)
  fault_release(gate)
  local one = F.wait_status(first, 'delivered')
  expect(F.wait_status(second, 'delivered').agent).to_be(one.agent)
  expect_error(function() alice:call('automations.run', {id = id, key = 'off-3'}) end, 'disabled')
  local worker = F.worker(one.agent)
  worker:call('automations.done', {run_key = second, attempt = 1, key = 'off-fail', outcome = 'failed'})
  expect_error(function() alice:call('automations.retry', {run_key = second, key = 'off-retry'}) end, 'disabled')
  alice:call('automations.set_enabled', {id = id, enabled = true, key = 'on'})
  expect(alice:call('automations.retry', {run_key = second, key = 'on-retry'}).status).to_be('queued')
  expect(F.wait_status(second, 'delivered').attempt).to_be(2)
end)

-- cancel_run takes only a queued run. The cancel deletes the queue entry in the same batch, so
-- the next queued run is not blocked.
test('cancel of a queued run behind a start; the next run still goes; a delivered run is refused', function()
  local id = automation('cancel')
  local first, second, third = manual(id, 1), manual(id, 2), manual(id, 3)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(first)})
  run_now(id, 'cancel-1')
  wait('the gated spawn', function() return fault_fired(gate) end, 10)
  run_now(id, 'cancel-2')
  run_now(id, 'cancel-3')
  expect_error(function() alice:call('automations.cancel_run', {run_key = first, key = 'cancel-starting'}) end, 'not_cancellable')
  expect(alice:call('automations.cancel_run', {run_key = second, key = 'cancel-a'}).status).to_be('cancelled')
  expect(alice:call('automations.cancel_run', {run_key = second, key = 'cancel-a'}).status).to_be('cancelled')
  expect(F.queued(qkey(id, 2))).to_be(nil)
  fault_release(gate)
  local one = F.wait_status(first, 'delivered')
  expect(F.wait_status(third, 'delivered').agent).to_be(one.agent)
  expect(F.run(second).status).to_be('cancelled')
  expect_error(function() alice:call('automations.cancel_run', {run_key = third, key = 'cancel-delivered'}) end, 'not_cancellable')
end)

-- unknown_start (design v2, 5d.6) and dismiss_start (5g). The dismissed run keeps its spawn key
-- and loses its queue entry, and the next queued run starts a new worker with its own key.
test('a start without an outcome for 10 minutes is unknown_start; dismiss lets the next run start', function()
  local id = automation('dismiss')
  local first, second = manual(id, 1), manual(id, 2)
  local drop = fault({point = 'spawn-create', mode = 'drop', op = spawn_key(first)})
  run_now(id, 'dismiss-1')
  wait('the dropped spawn', function() return fault_fired(drop) end, 10)
  F.wait_status(first, 'starting')
  run_now(id, 'dismiss-2')
  expect_error(function() alice:call('automations.dismiss_start', {run_key = first, key = 'dismiss-early'}) end, 'not_dismissable')
  F.set_clock(T0 + 601)
  F.wait_status(first, 'unknown_start')
  expect(F.run(second).status).to_be('queued')
  expect(F.state(id).spawning.request.key).to_be(spawn_key(first))
  expect(alice:call('automations.dismiss_start', {run_key = first, key = 'dismiss'}).status).to_be('dismissed')
  local run = F.run(first)
  expect(run.status).to_be('dismissed')
  expect(run.q).to_be(nil)
  expect(F.queued(qkey(id, 1))).to_be(nil)
  expect(run.dismissed[1].key).to_be(spawn_key(first))
  expect(F.state(id).dismissed_spawn.key).to_be(spawn_key(first))
  local two = F.wait_status(second, 'delivered')
  expect(two.starts).to_be(1)
  expect_error(function() alice:call('automations.dismiss_start', {run_key = second, key = 'dismiss-delivered'}) end, 'not_dismissable')
  local dismissed
  for _, r in ipairs(alice:call('automations.runs', {id = id}).runs) do if r.run_key == first then dismissed = r end end
  expect(dismissed.dismissed[1].key).to_be(spawn_key(first))
  F.set_clock(T0)
end)
