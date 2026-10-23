-- The work that waits while the plugin is stopped. A file event waits in the hub (the watch, its
-- watch_id and its unread page stay), and a pending start waits in its stored request. After the
-- next start, each happens once.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function spawn_key(run_key, starts) return 'automations/spawn/' .. run_key .. '/' .. (starts or 1) end
local function file_runs(f) return #sql('SELECT run_key FROM runs WHERE automation_id = ? AND run_key LIKE ?', {f, 'run/' .. f .. '/f/%'}) end

test('a file that appears while the plugin is stopped and a pending start each run once after its start', function()
  local dir = F.dir('during')
  local f = alice:call('automations.save', {key = 'work-file', name = 'During file', trigger = {kind = 'file', path = dir, glob = '*.md'},
    action = {profile = 'worker'}, instruction = 'During task.'}).id
  F.watching(alice, f)
  local p = alice:call('automations.save', {key = 'work-start', name = 'Pending start', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Pending task.'}).id
  local run_key = 'run/' .. p .. '/m/000001'
  -- The start of run 1 is stored and refused at the hub until the gate opens: a pending start.
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(run_key)})
  alice:call('automations.run', {id = p, key = 'work-start-1'})
  wait('the gated start', function() return fault_fired(gate) end, 10)
  local running = F.running('worker')
  -- While the plugin is stopped: the start is pending, and the file appears.
  local stopped = {}
  F.reload(function()
    stopped.registered = H.hub('hub.test.status', {}).plugins.automations.registered
    stopped.status = F.run(run_key).status
    F.put(dir .. '/during.md', 'new')
    stopped.file_runs = file_runs(f)
  end)
  expect(stopped.registered).to_be(false)
  expect(stopped.status).to_be('starting')
  expect(stopped.file_runs).to_be(0)
  -- The file: one run, from the hub's unread page.
  F.wait_runs(alice, f, 1, 30)
  -- The pending start replays its stored key when the gate opens: one worker for it.
  fault_release(gate)
  local run = F.wait_status(run_key, 'delivered', 30)
  expect(run.starts).to_be(1)
  rex.sleep(5)
  expect(#F.runs(alice, f, 'f')).to_be(1)
  -- Two new workers: the pending start's, and the file automation's first.
  expect(F.running('worker')).to_be(running + 2)
end)
