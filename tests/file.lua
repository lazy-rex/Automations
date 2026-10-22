-- File triggers (design v2 sections 4 and 6; amendment 1, B2). One run for each appearance of a
-- matching file. The marker seen/<id>/<appearance_key> is the dedup proof. It retires only after
-- an acknowledged removed or created_removed row.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function automation(key, dir, action, instruction)
  local id = alice:call('automations.save', {key = key, name = 'File ' .. key, trigger = {kind = 'file', path = dir, glob = '*.md'},
    action = action or {profile = 'worker'}, instruction = instruction or 'File task.'}).id
  F.watching(alice, id)
  return id
end

-- A new automation has gen 1, so its watch key is a-<id>-1 (B1).
local function wkey(id) return 'a-' .. id .. '-1' end
local function appearance(run) return run.run_key:match('/f/(.+)$') end
local function marker(id, run) return F.seen('seen/' .. id .. '/' .. appearance(run)) end
local function retire(id, run) return F.retired('rt/' .. id .. '/' .. appearance(run)) end

local function names(runs)
  local out = {}
  for _, r in ipairs(runs) do out[#out + 1] = r.item.name end
  table.sort(out)
  return table.concat(out, ' ')
end

test('a new file gives one run; an existing file and another name give none', function()
  local dir = F.dir('one')
  F.put(dir .. '/before.md')
  local id = automation('one', dir)
  F.put(dir .. '/a.md')
  local runs = F.wait_runs(alice, id, 1)
  expect(runs[1].item.name).to_be('a.md')
  expect(runs[1].item.path).to_be(dir .. '/a.md')
  local run = F.wait_status(runs[1].run_key, 'delivered')
  expect(marker(id, runs[1]).run).to_be(runs[1].run_key)
  F.put(dir .. '/b.md')
  F.put(dir .. '/c.txt')
  F.wait_runs(alice, id, 2)
  rex.sleep(2)
  expect(names(F.runs(alice, id, 'f'))).to_be('a.md b.md')
  -- The worker reads the file item with each task (box key order, not arrival order).
  local tasks = F.worker(run.agent):call('automations.read', {}).tasks
  expect(#tasks).to_be(2)
  expect(names(tasks)).to_be('a.md b.md')
end)

-- The ack fails, so the hub returns the created row again. The marker exists: no second run.
test('a failed ack gives no second run', function()
  local dir = F.dir('ack')
  local id = automation('ack', dir)
  local f = fault({point = 'action', action = 'hub.watch.ack', when = 'before', mode = 'fail', key = wkey(id)})
  F.put(dir .. '/x.md')
  local runs = F.wait_runs(alice, id, 1)
  wait('the failed ack', function() return fault_fired(f) end, 10)
  rex.sleep(3)
  runs = F.runs(alice, id, 'f')
  expect(#runs).to_be(1)
  expect(F.wait_status(runs[1].run_key, 'delivered').attempt).to_be(1)
end)

-- The ack is refused for as long as a gate is closed. The page's run and marker committed, so
-- the run goes on to its worker: a refused ack does not hold the delivery.
test('a refused ack does not hold the delivery of the run', function()
  local dir = F.dir('held')
  local id = automation('held', dir)
  local gate = fault({point = 'action', action = 'hub.watch.ack', when = 'before', mode = 'gate', key = wkey(id)})
  F.put(dir .. '/h.md')
  local runs = F.wait_runs(alice, id, 1)
  wait('the gated ack', function() return fault_fired(gate) end, 10)
  expect(F.wait_status(runs[1].run_key, 'delivered').attempt).to_be(1)
  fault_release(gate)
  rex.sleep(3)
  expect(#F.runs(alice, id, 'f')).to_be(1)
end)

-- The reviewer's case for B2: the file changes after its run and before the ack. The next read
-- returns created again, with the same appearance_key. The marker stops a second run.
test('a file that changes before the ack gives no second run', function()
  local dir = F.dir('changed')
  local id = automation('changed', dir)
  local gate = fault({point = 'action', action = 'hub.watch.ack', when = 'before', mode = 'gate', key = wkey(id)})
  F.put(dir .. '/z.md', 'one')
  local runs = F.wait_runs(alice, id, 1)
  wait('the gated ack', function() return fault_fired(gate) end, 10)
  F.put(dir .. '/z.md', 'two, longer')
  rex.sleep(2)
  fault_release(gate)
  rex.sleep(3)
  runs = F.runs(alice, id, 'f')
  expect(#runs).to_be(1)
  -- The file is still there, so its marker stays.
  expect(marker(id, runs[1])).not_to_be(nil)
end)

-- The file comes and goes while the ack is refused: the hub returns created_removed with the same
-- appearance_key. No second run. The marker retires only after the ack.
test('created_removed after a refused ack: no second run, and the marker retires after the ack', function()
  local dir = F.dir('gone')
  local id = automation('gone', dir)
  local gate = fault({point = 'action', action = 'hub.watch.ack', when = 'before', mode = 'gate', key = wkey(id)})
  F.put(dir .. '/y.md')
  local runs = F.wait_runs(alice, id, 1)
  wait('the gated ack', function() return fault_fired(gate) end, 10)
  F.remove(dir .. '/y.md')
  wait('the removal row', function() return retire(id, runs[1]) ~= nil end, 10)
  expect(marker(id, runs[1])).not_to_be(nil)
  fault_release(gate)
  wait('the marker to retire', function() return marker(id, runs[1]) == nil end, 10)
  expect(retire(id, runs[1])).to_be(nil)
  expect(#F.runs(alice, id, 'f')).to_be(1)
end)

-- A removed file: the ack applies, its reply is lost, and the hub crashes. After the restart the
-- cursor proves the ack, so the marker retires. A new file of the same name is a new appearance.
test('a removed file retires its marker after a lost ack reply and a crash', function()
  local dir = F.dir('removed')
  local id = automation('removed', dir)
  F.put(dir .. '/r.md')
  local runs = F.wait_runs(alice, id, 1)
  rex.sleep(2)
  local lost = fault({point = 'action', action = 'hub.watch.ack', when = 'after', mode = 'lose-reply', key = wkey(id)})
  F.remove(dir .. '/r.md')
  wait('the lost ack reply', function() return fault_fired(lost) end, 10)
  expect(marker(id, runs[1])).not_to_be(nil)
  hub:restart({crash = true})
  wait('the marker to retire', function() return marker(id, runs[1]) == nil end, 20)
  expect(retire(id, runs[1])).to_be(nil)
  F.put(dir .. '/r.md')
  local both = F.wait_runs(alice, id, 2)
  expect(names(both)).to_be('r.md r.md')
  expect(both[1].run_key).not_to_be(both[2].run_key)
end)

-- A run over the 12 KiB budget (amendment 1, detail 1): an 8 KiB encoded instruction, a long
-- directory and a file name of control characters (6 bytes encoded each). The run fails with
-- "path too long" and keeps no path. Its marker still stops a second run.
test('a file whose run passes the budget gives one failed run without the path', function()
  local dir = F.dir('long/' .. string.rep('p', 200) .. '/' .. string.rep('q', 200) .. '/' .. string.rep('r', 200))
  local name = string.rep('\1', 240) .. '.md'
  local id = automation('long', dir, {profile = 'tasked', args = {task = string.rep('t', 480)}}, string.rep('\1', 1365))
  F.put(dir .. '/' .. name)
  local runs = F.wait_runs(alice, id, 1)
  expect(runs[1].status).to_be('failed')
  expect(runs[1].error).to_be('path too long')
  expect(runs[1].item.path).to_be(nil)
  expect(runs[1].item.path_bytes).to_be(#dir + 1 + #name)
  expect(#runs[1].item.name <= 256).to_be(true)
  expect(marker(id, runs[1])).not_to_be(nil)
  -- The run has no path, so a retry would fail again.
  expect_error(function() alice:call('automations.retry', {run_key = runs[1].run_key, key = 'long-retry'}) end, 'not_retryable')
  F.put(dir .. '/' .. name, 'changed')
  rex.sleep(3)
  expect(#F.runs(alice, id, 'f')).to_be(1)
end)

-- A backlog over several read pages (50 rows each): every file gets exactly one run. The gate
-- holds the first start, so no run changes its phase while the test lists the pages (a run that
-- moves from Q to D between two pages is not in the list).
test('a backlog of 120 files gives 120 runs', function()
  local dir = F.dir('backlog')
  local id = automation('backlog', dir)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate'})
  for i = 1, 120 do F.put(string.format('%s/n%03d.md', dir, i)) end
  local function count() return #sql('SELECT run_key FROM runs WHERE automation_id = ?', {id}) end
  wait('120 file runs', function() return count() >= 120 end, 60)
  wait('the held start', function() return fault_fired(gate) end, 10)
  -- No second run of a file comes later.
  rex.sleep(3)
  expect(count()).to_be(120)
  local runs = F.runs(alice, id, 'f')
  expect(#runs).to_be(120)
  local seen = {}
  for _, r in ipairs(runs) do
    expect(seen[r.item.name]).to_be(nil)
    seen[r.item.name] = true
  end
  for i = 1, 120 do expect(seen[string.format('n%03d.md', i)]).to_be(true) end
  fault_release(gate)
end)
