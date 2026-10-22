-- automations.runs pages. The phases come in this order: S (the
-- starting run), D (delivered), Q (queued) and T (ended, the newest end first). The cursor is the
-- last consumed index entry, and a page reads at most 50 entries, so a page can be empty and still
-- have next.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function automation(key, action)
  return alice:call('automations.save', {key = key, name = 'Runs ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = action or {profile = 'worker'}, instruction = 'Runs task.'}).id
end
local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function run_now(id, key) return alice:call('automations.run', {id = id, key = key}).run_key end
local function gate_start(id, n)
  return fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = 'automations/spawn/' .. manual(id, n) .. '/1'})
end
-- pages reads every page and returns the run keys in order and the number of pages.
local function pages(id, limit)
  local keys, after, n = {}, nil, 0
  repeat
    local page = alice:call('automations.runs', {id = id, after = after, limit = limit})
    n = n + 1
    for _, r in ipairs(page.runs) do keys[#keys + 1] = r.run_key end
    after = page.next
  until not after or n > 100
  return keys, n
end

test('a mixed set over byte-limited pages: every run once, in phase order', function()
  local a, b = F.dir('mixed-a'), F.dir('mixed-b')
  local id = automation('mixed', {profile = 'worker', cwd = a})
  -- T: 30 runs done with 2000-byte summaries, done in order, so run 30 is the newest end.
  for n = 1, 30 do run_now(id, 'mixed-' .. n) end
  local first = F.wait_status(manual(id, 30), 'delivered', 60)
  local w1 = F.worker(first.agent)
  for n = 1, 30 do
    local run = F.wait_status(manual(id, n), 'delivered')
    w1:call('automations.done', {run_key = manual(id, n), attempt = run.attempt, key = 'mixed-done-' .. n, summary = string.rep('s', 2000)})
  end
  -- D: 31 to 33 stay delivered to W1.
  for n = 31, 33 do run_now(id, 'mixed-' .. n) end
  F.wait_status(manual(id, 33), 'delivered')
  -- S: an action change makes run 34 start a new worker, held by a gate. Q: 35 to 37.
  local v = F.view(alice, id)
  alice:call('automations.save', {id = id, if_rev = v.rev, key = 'mixed-b', name = v.name, trigger = v.trigger,
    action = {profile = 'worker', cwd = b}, instruction = v.instruction})
  local gate = gate_start(id, 34)
  run_now(id, 'mixed-34')
  wait('the gated start', function() return fault_fired(gate) end, 10)
  for n = 35, 37 do run_now(id, 'mixed-' .. n) end
  local want = {manual(id, 34), manual(id, 31), manual(id, 32), manual(id, 33), manual(id, 35), manual(id, 36), manual(id, 37)}
  for n = 30, 1, -1 do want[#want + 1] = manual(id, n) end
  local got, n = pages(id, 50)
  expect(table.concat(got, ' ')).to_be(table.concat(want, ' '))
  expect(n >= 2).to_be(true)
  got = pages(id, 5)
  expect(table.concat(got, ' ')).to_be(table.concat(want, ' '))
  fault_release(gate)
end)

-- 50 terminal entries that the T phase skips: on SQL an entry is a run's t column, so these are
-- 50 runs with a t/ entry and a status that is not terminal (queued, without a queue entry). In
-- the store layout they were stale t/ entries of the done run. The first page consumes 49 of them
-- after the S read and returns no run.
test('a page of only skipped entries is empty and has next; the next page has the run', function()
  local id = automation('skipped')
  local run_key = run_now(id, 'skipped-1')
  local run = F.wait_status(run_key, 'delivered')
  F.worker(run.agent):call('automations.done', {run_key = run_key, attempt = run.attempt, key = 'skipped-done'})
  F.wait_status(run_key, 'done')
  local ops = {}
  local task = F.run(run_key).task
  for n = 1, 50 do
    ops[n] = {tbl = 'runs', key = 'run/' .. id .. '/m/' .. string.format('%06d', 100 + n), new = true, value = {v = 1, auto = id, kind = 'm',
      k = string.format('%06d', 100 + n), status = 'queued', attempt = 0, starts = 0, task = task, t = string.format('t/%s/%012d', id, n), tseq = 0}}
  end
  F.write(ops)
  local one = alice:call('automations.runs', {id = id})
  expect(#one.runs).to_be(0)
  expect(one.next).to_be(string.format('T:t/%s/%012d', id, 49))
  local two = alice:call('automations.runs', {id = id, after = one.next})
  expect(#two.runs).to_be(1)
  expect(two.runs[1].run_key).to_be(run_key)
  expect(two.next).to_be(nil)
  local clean = {}
  for n = 1, 50 do clean[n] = {tbl = 'runs', key = 'run/' .. id .. '/m/' .. string.format('%06d', 100 + n), delete = true} end
  F.write(clean)
end)

test('the cursor crosses an empty phase: from the starting run to the queue', function()
  local id = automation('cross')
  local gate = gate_start(id, 1)
  run_now(id, 'cross-1')
  wait('the gated start', function() return fault_fired(gate) end, 10)
  run_now(id, 'cross-2')
  local one = alice:call('automations.runs', {id = id, limit = 1})
  expect(#one.runs).to_be(1)
  expect(one.runs[1].run_key).to_be(manual(id, 1))
  expect(one.runs[1].status).to_be('starting')
  expect(one.next).to_be('D')
  local two = alice:call('automations.runs', {id = id, after = one.next, limit = 1})
  expect(#two.runs).to_be(1)
  expect(two.runs[1].run_key).to_be(manual(id, 2))
  expect(two.runs[1].status).to_be('queued')
  local rest = pages(id, 1)
  expect(#rest).to_be(2)
  -- Malformed cursors.
  for _, after in ipairs({'X', 'X:1', 'D:', 'S:2', 'Q:q/' .. id .. '9/000000000001', 'T:t/' .. id .. '/', 'Q:dv/' .. id .. '/x'}) do
    expect_error(function() alice:call('automations.runs', {id = id, after = after}) end, 'invalid_input')
  end
  fault_release(gate)
end)
