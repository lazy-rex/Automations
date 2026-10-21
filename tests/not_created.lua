-- A start that the hub never sent (hub Fix A, hub main 8aa9426): hub.spawn answers status failed
-- with an error that starts with not_created. The plugin fails the run as a definite failure, never
-- as an unknown outcome. Needs the spawn-create fault mode fail-sending (hub 89cab8f or later).
-- Not covered here: a hub crash between the admission and the sending commits (the hub's own tests
-- cover the restart path), and a not_created call error when the hub cannot store the failure.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function spawn_key(run_key, n) return 'automations/spawn/' .. run_key .. '/' .. n end
local function not_created(w) return w.state == 'failed' and type(w.error) == 'string' and w.error:sub(1, 12) == 'not_created:' end

test('a not_created start fails its run, and Retry starts one worker with a new key', function()
  local id = alice:call('automations.save', {key = 'nc', name = 'Not created', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Not created task.'}).id
  local run_key = 'run/' .. id .. '/m/000001'
  local q = string.format('q/%s/%012d', id, 1)
  local before, running = #F.workers('worker'), F.running('worker')
  local f = fault({point = 'spawn-create', mode = 'fail-sending', op = spawn_key(run_key, 1)})
  expect(alice:call('automations.run', {id = id, key = 'nc-run'}).run_key).to_be(run_key)
  -- Each poll sees starting or failed. A poll does not see every state, so the source review
  -- covers the rest: a failed result never takes the pending branch.
  local run = wait('the run to fail', function()
    local r = F.run(run_key)
    expect(r.status ~= 'unknown_start').to_be(true)
    return r.status == 'failed' and r
  end, 20)
  expect(fault_fired(f)).to_be(true)
  expect(run.error:sub(1, 12)).to_be('not_created:')
  expect(run.starts).to_be(1)
  expect(run.dismissed).to_be(nil)
  expect(run.q).to_be(nil)
  expect(store(q).rev).to_be('0')
  expect(store('state/' .. id).value.spawning).to_be(nil)
  expect(store(run.t).value.run).to_be(run_key)
  -- The hub lists the start of key /1 as failed, and no worker of it runs.
  local workers = F.workers('worker')
  expect(#workers).to_be(before + 1)
  expect(not_created(workers[#workers])).to_be(true)
  expect(F.running('worker')).to_be(running)

  -- A gate holds the second start, so the test reads its stored key before it opens.
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(run_key, 2)})
  alice:call('automations.retry', {run_key = run_key, key = 'nc-retry'})
  wait('the gated second start', function() return fault_fired(gate) end, 10)
  expect(store('state/' .. id).value.spawning.request.key).to_be(spawn_key(run_key, 2))
  fault_release(gate)
  run = F.wait_status(run_key, 'delivered')
  expect(run.starts).to_be(2)
  expect(run.attempt).to_be(1)
  expect(run.retries).to_be(1)
  expect(run.t).to_be(nil)
  expect(F.running('worker')).to_be(running + 1)
  workers = F.workers('worker')
  expect(#workers).to_be(before + 2)
  local n = 0
  for _, w in ipairs(workers) do if not_created(w) then n = n + 1 end end
  expect(n).to_be(1)
  local tasks = F.worker(run.agent):call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].run_key).to_be(run_key)
end)
