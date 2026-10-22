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
  local inj
  F.reload(function()
    F.empty_tables()
    inj = inject({match = {sql_commit_writes = 'runs'}, fail = 'held for the work test', fail_code = 'unavailable', times = 10})
    F.put(dir .. '/during.md', 'new')
  end)
  wait('the held run page', function() return injection(inj).consumed >= 1 end, 30)
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

-- The bridge rule for a q/ or t/ delete (plan, "The cutover", point 4): the purge of a deleted
-- automation deletes its t/ entries before its runs. On SQL the delete clears the run's t column
-- and the t field of its document, with a new revision, in the purge batch, which writes the
-- state fence too. The test stops the purge after that batch: the next commit with the run key as
-- a parameter (the run delete) fails until the test cancels it.
test('the purge clears the terminal entry of a run, with a new revision and the state fence', function()
  local id = alice:call('automations.save', {key = 'purge', name = 'Purge', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Purge task.'}).id
  local r = alice:call('automations.run', {id = id, key = 'purge-1'})
  local run = F.wait_status(r.run_key, 'delivered', 30)
  F.worker(run.agent):call('automations.done', {run_key = r.run_key, attempt = run.attempt, key = 'purge-done'})
  F.wait_status(r.run_key, 'done')
  local before = F.store(r.run_key)
  expect(before.value.t).not_to_be(nil)
  -- skip = 1: the t/ phase batch (it writes the run) commits; the run phase batch fails.
  local held = inject({match = {sql_commit_writes = 'runs', sql_param = r.run_key}, skip = 1, fail = 'held purge', fail_code = 'unavailable',
    times = 'always'})
  alice:call('automations.delete', {id = id, key = 'purge-delete'})
  wait('the held run delete', function() return injection(held).consumed >= 1 end, 30)
  local after = F.store(r.run_key)
  expect(after.rev).not_to_be(before.rev)
  expect(after.value.t).to_be(nil)
  expect(after.value.status).to_be('done')
  expect(after.value.tseq).to_be(before.value.tseq)
  expect(sql('SELECT t FROM runs WHERE run_key = ?', {r.run_key})[1].t).to_be(nil)
  expect(F.store(before.value.t).rev).to_be('0')
  -- The same batch wrote the state fence: one batch takes consecutive revisions (lab revisions are
  -- small, so tonumber is exact here).
  local st = F.store('state/' .. id)
  expect(st.value.deleted).to_be(true)
  expect(math.abs(tonumber(st.rev) - tonumber(after.rev))).to_be(1)
  cancel_injection(held)
  wait('the purge', function() return F.store('auto/' .. id).rev == '0' and F.store('state/' .. id).rev == '0' end, 30)
  expect(F.store(r.run_key).rev).to_be('0')
end)
