-- The autonomous delivery path: a daily tick in the plugin, with no agent
-- call in flight, starts one worker from the automation's profile (hub.spawn for the user),
-- stores one task in the worker's box, and sets the notice intent. The worker reads and completes
-- the task through the agent face.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
local alice = agent('alice')

-- A daily automation at 09:00 on a test date. The clock starts before 09:00, so the save makes no
-- run; moving the clock past 09:00 makes the tick fire.
local function daily(name, key, day)
  F.set_clock(F.at(2026, 11, day, 8, 0))
  local saved = alice:call('automations.save', {key = key, name = name, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Check the vault for ' .. name .. '.'})
  expect(saved.id).to_match('^%d+$')
  return saved.id
end

-- off disables an automation through a normal save (the rev from automations.list).
local function off(id, key)
  for _, a in ipairs(alice:call('automations.list', {}).automations) do
    if a.id == id then
      alice:call('automations.save', {id = id, if_rev = a.rev, key = key, name = a.name, enabled = false, trigger = a.trigger,
        action = a.action, instruction = a.instruction})
      return
    end
  end
  error('no automation ' .. id)
end

test('a daily run starts one worker, which reads and completes its task', function()
  local id = daily('first', 'save-first', 3)
  local before = #F.workers('worker')
  local run_key = 'run/' .. id .. '/d/2026-11-03'
  expect(F.run(run_key)).to_be(nil)
  F.set_clock(F.at(2026, 11, 3, 9, 1))
  local run = F.wait_status(run_key, 'delivered')
  expect(run.attempt).to_be(1)
  expect(run.starts).to_be(1)
  expect(run.task.instruction).to_be('Check the vault for first.')
  expect(#F.workers('worker')).to_be(before + 1)
  local st = F.state(id)
  expect(st.worker.agent_id).to_be(run.agent)
  expect(st.daily_high).to_be('2026-11-03')
  expect(st.spawning).to_be(nil)
  -- One box entry and the notice intent.
  expect(F.held(run.agent, run_key).attempt).to_be(1)
  expect(notice(run.agent).pending).to_be(true)

  local worker = F.worker(run.agent)
  local tasks = worker:call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].run_key).to_be(run_key)
  expect(tasks[1].task.instruction).to_be('Check the vault for first.')
  -- Reading changes nothing: a second read (a lost reply) gives the same task.
  expect(worker:call('automations.read', {}).tasks[1].run_key).to_be(run_key)

  local finished = worker:call('automations.done', {run_key = run_key, attempt = 1, key = 'done-first', summary = 'All good.'})
  expect(finished.status).to_be('done')
  expect(F.run(run_key).status).to_be('done')
  expect(F.run(run_key).summary).to_be('All good.')
  expect(F.held(run.agent, run_key)).to_be(nil)
  expect(notice(run.agent).pending).to_be(false)
  expect(#worker:call('automations.read', {}).tasks).to_be(0)
  -- A replay of done with the same key gives the same result and changes nothing.
  expect(worker:call('automations.done', {run_key = run_key, attempt = 1, key = 'done-first', summary = 'All good.'}).status).to_be('done')
  -- The same key with other content is a conflict.
  expect_error(function() worker:call('automations.done', {run_key = run_key, attempt = 1, key = 'done-first', summary = 'Other.'}) end, 'conflict')
  -- The date never runs twice: later ticks on the same date make nothing.
  F.set_clock(F.at(2026, 11, 3, 18, 0))
  rex.sleep(2.5)
  expect(#F.workers('worker')).to_be(before + 1)
  off(id, 'off-first')
end)

test('a second run goes to the running worker, not to a new one', function()
  local id = daily('reuse', 'save-reuse', 5)
  F.set_clock(F.at(2026, 11, 5, 9, 1))
  local first = F.wait_status('run/' .. id .. '/d/2026-11-05', 'delivered')
  local worker = F.worker(first.agent)
  local count = #F.workers('worker')
  local manual = alice:call('automations.run', {id = id, key = 'run-reuse'})
  local second = F.wait_status(manual.run_key, 'delivered')
  expect(second.agent).to_be(first.agent)
  expect(#F.workers('worker')).to_be(count)
  -- A manual run does not move the daily schedule.
  expect(F.state(id).daily_high).to_be('2026-11-05')
  local tasks = worker:call('automations.read', {}).tasks
  expect(#tasks).to_be(2)
  -- One done leaves the other task, so the notice stays pending.
  worker:call('automations.done', {run_key = tasks[1].run_key, attempt = tasks[1].attempt, key = 'done-reuse-1'})
  expect(notice(first.agent).pending).to_be(true)
  worker:call('automations.done', {run_key = tasks[2].run_key, attempt = tasks[2].attempt, key = 'done-reuse-2'})
  expect(notice(first.agent).pending).to_be(false)
  off(id, 'off-reuse')
end)

test('a lost hub.spawn reply replays the same key and starts one worker', function()
  local id = daily('lost', 'save-lost', 7)
  local run_key = 'run/' .. id .. '/d/2026-11-07'
  local spawn_key = 'automations/spawn/' .. run_key .. '/1'
  local f = fault({point = 'action', action = 'hub.spawn', when = 'after', mode = 'lose-reply', key = spawn_key})
  local before = #F.workers('worker')
  F.set_clock(F.at(2026, 11, 7, 9, 1))
  local run = F.wait_status(run_key, 'delivered')
  expect(fault_fired(f)).to_be(true)
  expect(run.starts).to_be(1)
  expect(#F.workers('worker')).to_be(before + 1)
  local worker = F.worker(run.agent)
  expect(worker:call('automations.read', {}).tasks[1].run_key).to_be(run_key)
  worker:call('automations.done', {run_key = run_key, attempt = 1, key = 'done-lost'})
  off(id, 'off-lost')
end)

test('done from another agent or for another attempt is refused and changes nothing', function()
  local id = daily('fence', 'save-fence', 9)
  local run_key = 'run/' .. id .. '/d/2026-11-09'
  F.set_clock(F.at(2026, 11, 9, 9, 1))
  local run = F.wait_status(run_key, 'delivered')
  expect_error(function() alice:call('automations.done', {run_key = run_key, attempt = 1, key = 'alice-done'}) end, 'stale_delivery')
  local worker = F.worker(run.agent)
  expect_error(function() worker:call('automations.done', {run_key = run_key, attempt = 2, key = 'wrong-attempt'}) end, 'stale_delivery')
  expect(F.run(run_key).status).to_be('delivered')
  expect(#alice:call('automations.read', {}).tasks).to_be(0)
  worker:call('automations.done', {run_key = run_key, attempt = 1, key = 'done-fence'})
  off(id, 'off-fence')
end)
