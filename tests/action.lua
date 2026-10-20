-- The action cwd and the worker spec (commit 6a plan, amendment 1). A run snapshots its action;
-- its start passes cwd to hub.spawn. One current worker for each automation (the coordinator's
-- rule, 2026-10-20): a new run goes to it only when its spec (profile, args, cwd) is the same.
-- An older worker finishes the tasks that it has and gets no new ones.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function automation(key, action)
  return alice:call('automations.save', {key = key, name = 'Action ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = action, instruction = 'Action task.'}).id
end
-- change saves the automation again with another action (the rev from automations.list).
local function change(id, key, action)
  local a = F.view(alice, id)
  return alice:call('automations.save', {id = id, if_rev = a.rev, key = key, name = a.name, trigger = a.trigger,
    action = action, instruction = a.instruction})
end
local function run_now(id, key) return alice:call('automations.run', {id = id, key = key}).run_key end
local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function row(spawn_id)
  for _, w in ipairs(F.workers()) do if w.spawn_id == spawn_id then return w end end
end
-- in says that a worker's resolved cwd is the directory (the lab resolves /tmp to /private/tmp).
local function in_dir(spawn_id, dir)
  local cwd = row(spawn_id).cwd
  return cwd == dir or cwd == '/private' .. dir
end
local function done(run, key) F.worker(run.agent):call('automations.done', {run_key = run.key, attempt = run.attempt, key = key}) end

test('save checks the directory of action.cwd', function()
  local dir = F.dir('cwd-ok')
  local id = automation('cwd', {profile = 'worker', cwd = dir})
  expect(F.view(alice, id).action.cwd).to_be(dir)
  expect_error(function() automation('missing', {profile = 'worker', cwd = dir .. '/nope'}) end, 'not an existing directory')
  local file = dir .. '/file.md'
  F.put(file)
  expect_error(function() automation('file', {profile = 'worker', cwd = file}) end, 'not an existing directory')
  expect_error(function() automation('relative', {profile = 'worker', cwd = 'inbox'}) end, 'action.cwd is an absolute')
  expect_error(function() automation('unclean', {profile = 'worker', cwd = dir .. '//x'}) end, 'action.cwd must be clean')
  local r = rex.exec({'mkdir', '-p', H.args.lab .. '/home/work'})
  assert(r and r.ok)
  local home = automation('home', {profile = 'worker', cwd = '~/work'})
  expect(F.view(alice, home).action.cwd).to_be(H.args.lab .. '/home/work')
end)

test('a run starts its worker in action.cwd', function()
  local dir = F.dir('vault')
  local id = automation('start', {profile = 'worker', cwd = dir})
  local run = F.wait_status(run_now(id, 'start-1'), 'delivered')
  expect(run.task.cwd).to_be(dir)
  expect(in_dir(run.spawn_id, dir)).to_be(true)
  local tasks = F.worker(run.agent):call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].task.cwd).to_be(dir)
end)

-- A cwd change: the next run starts a new worker in the new directory; the old worker keeps its
-- task and can complete it.
test('a changed cwd starts a new worker, and the old worker keeps its task', function()
  local a, b = F.dir('cwd-a'), F.dir('cwd-b')
  local id = automation('moved', {profile = 'worker', cwd = a})
  local one = F.wait_status(run_now(id, 'moved-1'), 'delivered')
  change(id, 'moved-b', {profile = 'worker', cwd = b})
  local two = F.wait_status(run_now(id, 'moved-2'), 'delivered')
  expect(two.agent).not_to_be(one.agent)
  expect(in_dir(two.spawn_id, b)).to_be(true)
  expect(in_dir(one.spawn_id, a)).to_be(true)
  rex.sleep(2)
  local first = store(manual(id, 1)).value
  expect(first.status).to_be('delivered')
  expect(first.agent).to_be(one.agent)
  expect(first.attempt).to_be(1)
  F.worker(one.agent):call('automations.done', {run_key = manual(id, 1), attempt = 1, key = 'moved-done'})
  expect(F.wait_status(manual(id, 1), 'done').agent).to_be(one.agent)
  expect(F.wait_status(run_now(id, 'moved-3'), 'delivered').agent).to_be(two.agent)
end)

test('changed args start a new worker, and the old worker keeps its task', function()
  local id = automation('args', {profile = 'tasked', args = {task = 'one'}})
  local one = F.wait_status(run_now(id, 'args-1'), 'delivered')
  change(id, 'args-two', {profile = 'tasked', args = {task = 'two'}})
  local two = F.wait_status(run_now(id, 'args-2'), 'delivered')
  expect(two.agent).not_to_be(one.agent)
  rex.sleep(2)
  expect(store(manual(id, 1)).value.agent).to_be(one.agent)
  expect(store(manual(id, 1)).value.attempt).to_be(1)
end)

-- A pending start keeps its stored request across an edit: it opens in the old directory, and
-- the queued run behind it starts a worker in the new one.
test('a pending start across an edit opens with its stored request', function()
  local a, b = F.dir('pend-a'), F.dir('pend-b')
  local id = automation('pending', {profile = 'worker', cwd = a})
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = 'automations/spawn/' .. manual(id, 1) .. '/1'})
  run_now(id, 'pending-1')
  wait('the gated start', function() return fault_fired(gate) end, 10)
  change(id, 'pending-b', {profile = 'worker', cwd = b})
  run_now(id, 'pending-2')
  expect(store('state/' .. id).value.spawning.request.cwd).to_be(a)
  fault_release(gate)
  local one = F.wait_status(manual(id, 1), 'delivered')
  expect(in_dir(one.spawn_id, a)).to_be(true)
  local two = F.wait_status(manual(id, 2), 'delivered')
  expect(two.agent).not_to_be(one.agent)
  expect(in_dir(two.spawn_id, b)).to_be(true)
end)

-- The old worker stops after an action change: its task is requeued, and its next start uses
-- the run's own snapshot (cwd A), not the current action.
test('an old worker lost after an action change: its task starts a worker with its own spec', function()
  local a, b = F.dir('lost-a'), F.dir('lost-b')
  local id = automation('lost', {profile = 'worker', cwd = a})
  local one = F.wait_status(run_now(id, 'lost-1'), 'delivered')
  change(id, 'lost-b', {profile = 'worker', cwd = b})
  local two = F.wait_status(run_now(id, 'lost-2'), 'delivered')
  expect(alice:hub('hub.stop', {spawn_id = one.spawn_id}).status).to_be('closed')
  local again = wait('run 1 attempt 2', function()
    local r = store(manual(id, 1)).value
    return r.status == 'delivered' and r.attempt == 2 and r
  end, 25)
  expect(again.agent).not_to_be(one.agent)
  expect(again.agent).not_to_be(two.agent)
  expect(in_dir(again.spawn_id, a)).to_be(true)
  expect(store(manual(id, 2)).value.agent).to_be(two.agent)
end)

-- A -> B -> A: one current worker only, so the second A starts a third worker; the first A
-- worker keeps its task.
test('A, then B, then A again starts a third worker', function()
  local a, b = F.dir('aba-a'), F.dir('aba-b')
  local id = automation('aba', {profile = 'worker', cwd = a})
  local one = F.wait_status(run_now(id, 'aba-1'), 'delivered')
  change(id, 'aba-b', {profile = 'worker', cwd = b})
  local two = F.wait_status(run_now(id, 'aba-2'), 'delivered')
  change(id, 'aba-a', {profile = 'worker', cwd = a})
  local three = F.wait_status(run_now(id, 'aba-3'), 'delivered')
  expect(three.agent).not_to_be(one.agent)
  expect(three.agent).not_to_be(two.agent)
  expect(in_dir(three.spawn_id, a)).to_be(true)
  expect(store(manual(id, 1)).value.agent).to_be(one.agent)
  expect(store(manual(id, 2)).value.agent).to_be(two.agent)
end)

-- The reviewer's case for the paged scan: 20 tasks of a live W1 fill the first dv page, and the
-- task of a stopped W2 is on the second page. It must move. Then a hub crash while both workers
-- hold tasks changes nothing.
test('a lost task after 20 live tasks moves, and a crash keeps every holder', function()
  local a, b = F.dir('many-a'), F.dir('many-b')
  local id = automation('many', {profile = 'worker', cwd = a})
  local one
  for n = 1, 20 do one = F.wait_status(run_now(id, 'many-' .. n), 'delivered') end
  change(id, 'many-b', {profile = 'worker', cwd = b})
  local two = F.wait_status(run_now(id, 'many-21'), 'delivered')
  expect(two.agent).not_to_be(one.agent)
  expect(alice:hub('hub.stop', {spawn_id = two.spawn_id}).status).to_be('closed')
  local moved = wait('run 21 attempt 2', function()
    local r = store(manual(id, 21)).value
    return r.status == 'delivered' and r.attempt == 2 and r
  end, 25)
  expect(in_dir(moved.spawn_id, b)).to_be(true)
  for n = 1, 20 do
    local r = store(manual(id, n)).value
    expect(r.agent).to_be(one.agent)
    expect(r.attempt).to_be(1)
  end
  hub:restart({crash = true})
  rex.sleep(5)
  for n = 1, 20 do
    local r = store(manual(id, n)).value
    expect(r.status).to_be('delivered')
    expect(r.agent).to_be(one.agent)
    expect(r.attempt).to_be(1)
  end
  local r21 = store(manual(id, 21)).value
  expect(r21.agent).to_be(moved.agent)
  expect(r21.attempt).to_be(2)
end)
