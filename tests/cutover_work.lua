-- The work that waits during the copy (SDK port plan, "The cutover", point 2). The copy runs in a
-- new instance; the gate holds every engine step until it is done. A file event waits in the hub
-- (the watch, its watch_id and its unread page stay), and a pending start waits in its stored
-- request. After the copy, each happens once.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function spawn_key(run_key, starts) return 'automations/spawn/' .. run_key .. '/' .. (starts or 1) end

test('a file that appears during the copy and a pending start each run once after it', function()
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
  expect(F.store(run_key).value.status).to_be('starting')
  local running = F.running('worker')
  F.to_store()
  -- The new instance copies; its first run page fails 10 times, so the copy waits about 10 s. The
  -- file appears while the plugin is stopped, before the copy.
  local inj = {}
  F.reload(function()
    F.empty_tables()
    inj.id = inject({match = {sql_commit_writes = 'runs'}, fail = 'held for the work test', fail_code = 'unavailable', times = 10})
    F.put(dir .. '/during.md', 'new')
  end)
  wait('the held run page', function() return injection(inj.id).consumed >= 1 end, 30)
  expect(F.copied()).to_be(false)
  -- No file run while the copy waits (the exports answer unavailable: the tables show it).
  rex.sleep(2)
  expect(#sql('SELECT run_key FROM runs WHERE automation_id = ? AND run_key LIKE ?', {f, 'run/' .. f .. '/f/%'})).to_be(0)
  wait('the copy', F.copied, 60)
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
