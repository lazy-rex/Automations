-- Run retention (design v2 section 10; retention amendment 1): the newest 100 terminal runs of an
-- automation stay. The order is the terminal sequence in state/<id> (next_t), never the clock.
-- Active runs and markers are never pruned.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
local T0 = F.at(2026, 11, 3, 10, 0)
F.set_clock(T0)
local alice = agent('alice')
local MAX_T = 999999999999

local function automation(key, trigger)
  return alice:call('automations.save', {key = key, name = 'Keep ' .. key, trigger = trigger or {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Keep task.'}).id
end
local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function tkey(id, n) return string.format('t/%s/%012d', id, MAX_T - n) end
local function spawn_key(run_key, starts) return 'automations/spawn/' .. run_key .. '/' .. (starts or 1) end
local function run_now(id, key) return alice:call('automations.run', {id = id, key = key}).run_key end
local function cancel(run_key, key) return alice:call('automations.cancel_run', {run_key = run_key, key = key}) end
local function exists(run_key) return F.run(run_key) ~= nil end
local function ended(t) return F.ended(t) ~= nil end

-- hold starts run 1 behind a gate, so later runs stay queued: run 1 is starting, and no worker
-- runs. It returns the gate.
local function hold(id, key)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(manual(id, 1))})
  expect(run_now(id, key .. '-1')).to_be(manual(id, 1))
  wait('the gated start of ' .. key, function() return fault_fired(gate) end, 10)
  expect(F.run(manual(id, 1)).status).to_be('starting')
  return gate
end
-- cancel_runs makes runs from to upto and cancels each: one terminal sequence each, in order.
local function cancel_runs(id, key, from, upto)
  for n = from, upto do
    local run_key = run_now(id, key .. '-' .. n)
    expect(run_key).to_be(manual(id, n))
    expect(F.run(run_key).status).to_be('queued')
    expect(cancel(run_key, key .. '-c' .. n).status).to_be('cancelled')
  end
end

test('the newest 100 terminal runs stay; an older active run stays; a retry takes a new sequence', function()
  local id = automation('keep')
  local gate = hold(id, 'keep')
  cancel_runs(id, 'keep', 2, 106) -- terminal sequences 1 to 105
  wait('the 5 oldest terminal runs to go', function()
    for n = 2, 6 do if exists(manual(id, n)) then return false end end
    return true
  end, 20)
  for n = 2, 6 do expect(ended(tkey(id, n - 1))).to_be(false) end
  for n = 7, 106 do
    local run = F.run(manual(id, n))
    expect(run.tseq).to_be(n - 1)
    expect(run.t).to_be(tkey(id, n - 1))
    expect(F.ended(run.t)).to_be(manual(id, n))
  end
  expect(F.state(id).next_t).to_be(105)
  -- Run 1 is the oldest run, but it is active.
  expect(F.run(manual(id, 1)).status).to_be('starting')
  -- A retry of the oldest kept run deletes its entry; its next end takes sequence 106.
  alice:call('automations.retry', {run_key = manual(id, 7), key = 'keep-retry'})
  expect(ended(tkey(id, 6))).to_be(false)
  expect(F.run(manual(id, 7)).t).to_be(nil)
  cancel(manual(id, 7), 'keep-recancel')
  expect(F.run(manual(id, 7)).tseq).to_be(106)
  rex.sleep(2)
  expect(exists(manual(id, 8))).to_be(true)
  -- Sequence 107 makes 101 entries: sequence 7 (run 8) goes, and run 7 stays.
  cancel_runs(id, 'keep', 107, 107)
  wait('run 8 to go', function() return not exists(manual(id, 8)) end, 20)
  expect(exists(manual(id, 7))).to_be(true)
  fault_release(gate)
end)

-- Run documents near the run budget (review of f71fc6e). An instruction of 4000 backslashes is
-- 8000 bytes encoded, and twice that inside a hub.sql reply, which holds about 1 MB: the full
-- documents of 101 runs need two replies. The prune's t/ scan must still see 100 entries, so the
-- oldest go and exactly the newest 100 stay.
test('with run documents near the budget, exactly the newest 100 terminal runs stay', function()
  local id = alice:call('automations.save', {key = 'big', name = 'Keep big', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = string.rep('\\', 4000)}).id
  local gate = hold(id, 'big')
  cancel_runs(id, 'big', 2, 106) -- terminal sequences 1 to 105
  local stored = sql('SELECT sum(length(doc)) AS n FROM runs WHERE automation_id = ?', {id})[1].n
  expect(tonumber(stored) > 101 * 8000).to_be(true) -- more than one reply of full documents
  wait('the 5 oldest terminal runs to go', function()
    for n = 2, 6 do if exists(manual(id, n)) then return false end end
    return true
  end, 30)
  for n = 7, 106 do expect(exists(manual(id, n))).to_be(true) end
  expect(#sql("SELECT run_key FROM runs WHERE automation_id = ? AND t IS NOT NULL", {id})).to_be(100)
  fault_release(gate)
end)

-- A clock moved back changes no order: the run that ended last stays.
test('with the clock moved back, the latest terminal run stays and the oldest goes', function()
  F.set_clock(T0 + 86400)
  local id = automation('clock')
  local gate = hold(id, 'clock')
  cancel_runs(id, 'clock', 2, 101) -- sequences 1 to 100
  rex.sleep(2)
  expect(exists(manual(id, 2))).to_be(true)
  F.set_clock(T0)
  cancel_runs(id, 'clock', 102, 102) -- sequence 101, with an earlier clock
  wait('the oldest terminal run to go', function() return not exists(manual(id, 2)) end, 20)
  expect(F.run(manual(id, 102)).tseq).to_be(101)
  expect(exists(manual(id, 102))).to_be(true)
  expect(exists(manual(id, 3))).to_be(true)
  fault_release(gate)
end)

-- done takes a sequence under the state fence; a replay with the same key gives the same result.
test('done takes a terminal sequence, and its replay gives the same result', function()
  local id = automation('done')
  local run_key = run_now(id, 'done-1')
  local run = F.wait_status(run_key, 'delivered')
  local worker = F.worker(run.agent)
  local r = worker:call('automations.done', {run_key = run_key, attempt = 1, key = 'done-a', summary = 'Done.'})
  expect(r.status).to_be('done')
  expect(worker:call('automations.done', {run_key = run_key, attempt = 1, key = 'done-a', summary = 'Done.'}).status).to_be('done')
  run = F.run(run_key)
  expect(run.tseq).to_be(1)
  expect(F.ended(tkey(id, 1))).to_be(run_key)
  expect(F.state(id).next_t).to_be(1)
end)

-- The reviewer's case for B2, the prune half: the file changes before the ack, its run is pruned,
-- and the created row comes again. The marker stays, so no second run comes.
test('a file run pruned before its ack makes no second run: the marker stays', function()
  local dir = F.dir('pruned')
  local id = automation('file', {kind = 'file', path = dir, glob = '*.md'})
  F.watching(alice, id)
  local ack = fault({point = 'action', action = 'hub.watch.ack', when = 'before', mode = 'gate', key = 'a-' .. id .. '-1'})
  F.put(dir .. '/z.md', 'one')
  local runs = F.wait_runs(alice, id, 1)
  local file_run = runs[1].run_key
  local marker = 'seen/' .. id .. '/' .. file_run:match('/f/(.+)$')
  wait('the gated ack', function() return fault_fired(ack) end, 10)
  local run = F.wait_status(file_run, 'delivered')
  F.put(dir .. '/z.md', 'two, longer')
  F.worker(run.agent):call('automations.done', {run_key = file_run, attempt = 1, key = 'file-done'})
  expect(F.run(file_run).tseq).to_be(1)
  -- The worker stops, so later runs need a start: the gated start keeps them queued.
  expect(alice:hub('hub.stop', {spawn_id = run.spawn_id}).status).to_be('closed')
  local gate = hold(id, 'file')
  cancel_runs(id, 'file', 2, 101) -- sequences 2 to 101
  wait('the file run to be pruned', function() return not exists(file_run) end, 20)
  expect(ended(tkey(id, 1))).to_be(false)
  expect(F.seen(marker) ~= nil).to_be(true)
  expect(fault_fired(ack)).to_be(true)
  fault_release(ack)
  rex.sleep(3)
  expect(exists(file_run)).to_be(false)
  expect(#F.runs(alice, id, 'f')).to_be(0)
  expect(F.seen(marker) ~= nil).to_be(true)
  fault_release(gate)
end)

-- The reviewer's crash point: the backlog comes from the harness write (complete run records with
-- their entries), so 60 excess entries exist before the prune starts. Newest first, the excess
-- pages are 60 down to 11 (batch 1), then 10 down to 1 (batch 2). The injection fails exactly the
-- batch that deletes entry 10. The hub keeps injections in memory, so the restart ends it.
test('a crash between prune batches leaves exactly the newest 100', function()
  local id = automation('crash')
  local function rk(n) return 'run/' .. id .. '/m/' .. string.format('%06d', 500 + n) end
  local function records(from, upto)
    local ops = {}
    for n = from, upto do
      ops[#ops + 1] = {tbl = 'runs', key = rk(n), new = true, value = {v = 1, auto = id, name = 'Keep crash', kind = 'm', by = 'alice', at = T0,
        task = {instruction = 'Keep task.', profile = 'worker'}, status = 'cancelled', attempt = 0, starts = 0,
        cancelled = {by = 'alice', at = T0}, t = tkey(id, n), tseq = n}}
    end
    return ops
  end
  local function with_state(ops, next_t)
    local st, rev = F.state(id), F.rev('states', id)
    st.next_t = next_t
    ops[#ops + 1] = {tbl = 'states', key = id, if_rev = rev, value = st}
    return ops
  end
  local function send(ops)
    expect(#rex.json.encode(ops) < 40000).to_be(true)
    F.write(ops)
  end
  send(records(1, 40))
  send(records(41, 80))
  send(with_state(records(81, 100), 100))
  rex.sleep(2)
  expect(exists(rk(1))).to_be(true)
  -- skip = 1: the first prune commit (excess 60 down to 11) passes; the second fails until the crash.
  local held = inject({match = {sql_commit_writes = 'runs'}, skip = 1, fail = 'held', fail_code = 'unavailable', times = 'always'})
  send(with_state(records(101, 160), 160))
  wait('the held second prune batch', function() return injection(held).consumed >= 1 end, 20)
  for n = 11, 60 do
    expect(exists(rk(n))).to_be(false)
    expect(ended(tkey(id, n))).to_be(false)
  end
  for n = 1, 10 do expect(exists(rk(n))).to_be(true) end
  for n = 61, 160 do expect(exists(rk(n))).to_be(true) end
  hub:restart({crash = true})
  wait('the second prune batch after the restart', function()
    for n = 1, 10 do if exists(rk(n)) or ended(tkey(id, n)) then return false end end
    return true
  end, 30)
  for n = 61, 160 do
    local run = F.run(rk(n))
    expect(run.t).to_be(tkey(id, n))
    expect(F.ended(tkey(id, n))).to_be(rk(n))
  end
  for n = 11, 60 do expect(exists(rk(n))).to_be(false) end
  expect(F.state(id).next_t).to_be(160)
end)

-- The reviewer's race (review of 451691c, R1): 101 terminal runs, and a retry makes sequence
-- 101 active. Then 100 terminal runs are left, so sequence 1 must stay. The injection commits the
-- retry's records when the plugin begins its next transaction: the prune reads its cutoff in
-- that transaction, after the retry. (It does not show a writer inside the transaction.)
test('a retry that commits before the prune transaction keeps the oldest run', function()
  local id = automation('race')
  local gate = hold(id, 'race')
  local function rk(n) return 'run/' .. id .. '/m/' .. string.format('%06d', 500 + n) end
  local function cancelled(n)
    return {v = 1, auto = id, name = 'Keep race', kind = 'm', by = 'alice', at = T0, task = {instruction = 'Keep task.', profile = 'worker'},
      status = 'cancelled', attempt = 0, starts = 0, cancelled = {by = 'alice', at = T0}, t = tkey(id, n), tseq = n}
  end
  for lo = 1, 81, 40 do
    local ops = {}
    for n = lo, math.min(lo + 39, 100) do
      ops[#ops + 1] = {tbl = 'runs', key = rk(n), new = true, value = cancelled(n)}
    end
    F.write(ops)
  end
  local st, rev = F.state(id), F.rev('states', id)
  st.next_t = 101
  F.write({{tbl = 'states', key = id, if_rev = rev, value = st}})
  -- The retry of run 101: queued with a queue entry, its entry deleted, and the state written.
  local retried = cancelled(101)
  retried.status, retried.t, retried.tseq, retried.retries = 'queued', nil, nil, 1
  retried.q = string.format('q/%s/%012d', id, 2)
  local after = F.state(id)
  after.next_q = 2
  local race = F.inject_begin({
    {tbl = 'runs', key = rk(101), value = retried}, {tbl = 'states', key = id, value = after}})
  F.write({{tbl = 'runs', key = rk(101), new = true, value = cancelled(101)}})
  wait('the concurrent retry', function() return injection(race).consumed == 1 end, 20)
  rex.sleep(2)
  expect(F.run(rk(101)).status).to_be('queued')
  expect(exists(rk(1))).to_be(true)
  expect(ended(tkey(id, 1))).to_be(true)
  for n = 2, 100 do expect(exists(rk(n))).to_be(true) end
  fault_release(gate)
end)
