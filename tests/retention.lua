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
local function exists(key) return F.store(key).rev ~= '0' end

-- hold starts run 1 behind a gate, so later runs stay queued: run 1 is starting, and no worker
-- runs. It returns the gate.
local function hold(id, key)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(manual(id, 1))})
  expect(run_now(id, key .. '-1')).to_be(manual(id, 1))
  wait('the gated start of ' .. key, function() return fault_fired(gate) end, 10)
  expect(F.store(manual(id, 1)).value.status).to_be('starting')
  return gate
end
-- cancel_runs makes runs from to upto and cancels each: one terminal sequence each, in order.
local function cancel_runs(id, key, from, upto)
  for n = from, upto do
    local run_key = run_now(id, key .. '-' .. n)
    expect(run_key).to_be(manual(id, n))
    expect(F.store(run_key).value.status).to_be('queued')
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
  for n = 2, 6 do expect(exists(tkey(id, n - 1))).to_be(false) end
  for n = 7, 106 do
    local run = F.store(manual(id, n)).value
    expect(run.tseq).to_be(n - 1)
    expect(run.t).to_be(tkey(id, n - 1))
    expect(F.store(run.t).value.run).to_be(manual(id, n))
  end
  expect(F.store('state/' .. id).value.next_t).to_be(105)
  -- Run 1 is the oldest run, but it is active.
  expect(F.store(manual(id, 1)).value.status).to_be('starting')
  -- A retry of the oldest kept run deletes its entry; its next end takes sequence 106.
  alice:call('automations.retry', {run_key = manual(id, 7), key = 'keep-retry'})
  expect(exists(tkey(id, 6))).to_be(false)
  expect(F.store(manual(id, 7)).value.t).to_be(nil)
  cancel(manual(id, 7), 'keep-recancel')
  expect(F.store(manual(id, 7)).value.tseq).to_be(106)
  rex.sleep(2)
  expect(exists(manual(id, 8))).to_be(true)
  -- Sequence 107 makes 101 entries: sequence 7 (run 8) goes, and run 7 stays.
  cancel_runs(id, 'keep', 107, 107)
  wait('run 8 to go', function() return not exists(manual(id, 8)) end, 20)
  expect(exists(manual(id, 7))).to_be(true)
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
  expect(F.store(manual(id, 102)).value.tseq).to_be(101)
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
  run = F.store(run_key).value
  expect(run.tseq).to_be(1)
  expect(F.store(tkey(id, 1)).value.run).to_be(run_key)
  expect(F.store('state/' .. id).value.next_t).to_be(1)
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
  expect(F.store(file_run).value.tseq).to_be(1)
  -- The worker stops, so later runs need a start: the gated start keeps them queued.
  expect(alice:hub('hub.stop', {spawn_id = run.spawn_id}).status).to_be('closed')
  local gate = hold(id, 'file')
  cancel_runs(id, 'file', 2, 101) -- sequences 2 to 101
  wait('the file run to be pruned', function() return not exists(file_run) end, 20)
  expect(exists(tkey(id, 1))).to_be(false)
  expect(exists(marker)).to_be(true)
  expect(fault_fired(ack)).to_be(true)
  fault_release(ack)
  rex.sleep(3)
  expect(exists(file_run)).to_be(false)
  expect(#F.runs(alice, id, 'f')).to_be(0)
  expect(exists(marker)).to_be(true)
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
      ops[#ops + 1] = {key = rk(n), if_rev = '0', value = {v = 1, auto = id, name = 'Keep crash', kind = 'm', by = 'alice', at = T0,
        task = {instruction = 'Keep task.', profile = 'worker'}, status = 'cancelled', attempt = 0, starts = 0,
        cancelled = {by = 'alice', at = T0}, t = tkey(id, n), tseq = n}}
      ops[#ops + 1] = {key = tkey(id, n), if_rev = '0', value = {run = rk(n), seq = n}}
    end
    return ops
  end
  local function with_state(ops, next_t)
    local rec = F.store('state/' .. id)
    local st = rec.value
    st.next_t = next_t
    ops[#ops + 1] = {key = 'state/' .. id, if_rev = rec.rev, value = st}
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
    expect(exists(tkey(id, n))).to_be(false)
  end
  for n = 1, 10 do expect(exists(rk(n))).to_be(true) end
  for n = 61, 160 do expect(exists(rk(n))).to_be(true) end
  hub:restart({crash = true})
  wait('the second prune batch after the restart', function()
    for n = 1, 10 do if exists(rk(n)) or exists(tkey(id, n)) then return false end end
    return true
  end, 30)
  for n = 61, 160 do
    local run = F.store(rk(n)).value
    expect(run.t).to_be(tkey(id, n))
    expect(F.store(tkey(id, n)).value.run).to_be(rk(n))
  end
  for n = 11, 60 do expect(exists(rk(n))).to_be(false) end
  expect(F.store('state/' .. id).value.next_t).to_be(160)
end)

-- The reviewer's race (review of 451691c, R1): the prune chose sequence 1 from 101 entries, and a
-- retry makes sequence 101 active before the prune batch commits. Then 100 terminal runs are
-- left, so sequence 1 must stay. The injection commits the retry's records when the plugin
-- begins its next transaction, the prune batch that deletes entry 1; the retry writes
-- state/<id>, so the prune's state fence fails.
test('a retry between the prune read and its batch keeps the oldest run', function()
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
      ops[#ops + 1] = {key = rk(n), if_rev = '0', value = cancelled(n)}
      ops[#ops + 1] = {key = tkey(id, n), if_rev = '0', value = {run = rk(n), seq = n}}
    end
    F.write(ops)
  end
  local rec = F.store('state/' .. id)
  local st = rec.value
  st.next_t = 101
  F.write({{key = 'state/' .. id, if_rev = rec.rev, value = st}})
  -- The retry of run 101: queued with a queue entry, its entry deleted, and the state written.
  local retried = cancelled(101)
  retried.status, retried.t, retried.tseq, retried.retries = 'queued', nil, nil, 1
  retried.q = string.format('q/%s/%012d', id, 2)
  local after = F.store('state/' .. id).value
  after.next_q = 2
  local race = F.inject_begin({
    {key = rk(101), value = retried}, {key = tkey(id, 101), delete = true},
    {key = retried.q, value = {run = rk(101)}}, {key = 'state/' .. id, value = after}})
  F.write({{key = rk(101), if_rev = '0', value = cancelled(101)}, {key = tkey(id, 101), if_rev = '0', value = {run = rk(101), seq = 101}}})
  wait('the concurrent retry', function() return injection(race).consumed == 1 end, 20)
  rex.sleep(2)
  expect(F.store(rk(101)).value.status).to_be('queued')
  expect(exists(rk(1))).to_be(true)
  expect(exists(tkey(id, 1))).to_be(true)
  for n = 2, 100 do expect(exists(rk(n))).to_be(true) end
  fault_release(gate)
end)
