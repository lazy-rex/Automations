-- The operation handlers read their rows in the transaction of their commit (cleanup area 1). A
-- failed commit leaves no row, no counter change and no saved reply; the same key then makes the
-- change once. A manual run takes its number from the state in the same transaction.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function meta(name) local r = sql('SELECT value FROM meta WHERE name = ?', {name})[1] return r and r.value end
local function count(tbl) return sql('SELECT count(*) AS n FROM ' .. tbl)[1].n end
local function state(id) return rex.json.decode(sql('SELECT doc FROM states WHERE id = ?', {id})[1].doc) end
local function save(key)
  return alice:call('automations.save', {key = key, name = 'Tx ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Transaction task.'})
end

test('a failed create commits nothing; the same key then creates the automation once', function()
  local id0 = save('tx-first').id
  local next_id, rev, autos, ops = meta('next_id'), meta('rev'), count('automations'), count('ops')
  local failed = inject({match = {sql_commit_writes = 'automations'}, fail = 'the save commit fails', fail_code = 'unavailable', times = 1})
  expect_error(function() save('tx-create') end, 'unavailable')
  expect(injection(failed).consumed).to_be(1)
  expect(meta('next_id')).to_be(next_id)
  expect(meta('rev')).to_be(rev)
  expect(count('automations')).to_be(autos)
  expect(count('ops')).to_be(ops)
  local made = save('tx-create')
  expect(made.id).to_be(tostring(tonumber(id0) + 1))
  expect(save('tx-create').id).to_be(made.id)
  expect(count('automations')).to_be(autos + 1)
end)

test('a failed run commits nothing; manual numbers follow the state, and a replay makes no run', function()
  local id = save('tx-manual').id
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate'})
  local st, rev, ops = state(id), meta('rev'), count('ops')
  local failed = inject({match = {sql_commit_writes = 'runs'}, fail = 'the run commit fails', fail_code = 'unavailable', times = 1})
  expect_error(function() alice:call('automations.run', {id = id, key = 'tx-run-1'}) end, 'unavailable')
  expect(injection(failed).consumed).to_be(1)
  expect(#sql('SELECT run_key FROM runs WHERE automation_id = ?', {id})).to_be(0)
  expect(state(id).next_manual).to_be(st.next_manual)
  expect(state(id).next_q).to_be(st.next_q)
  expect(meta('rev')).to_be(rev)
  expect(count('ops')).to_be(ops)
  local one = alice:call('automations.run', {id = id, key = 'tx-run-1'}).run_key
  local two = alice:call('automations.run', {id = id, key = 'tx-run-2'}).run_key
  expect(one).to_be('run/' .. id .. '/m/000001')
  expect(two).to_be('run/' .. id .. '/m/000002')
  expect(alice:call('automations.run', {id = id, key = 'tx-run-1'}).run_key).to_be(one)
  expect(#sql('SELECT run_key FROM runs WHERE automation_id = ?', {id})).to_be(2)
  expect(state(id).next_manual).to_be(2)
  wait('the held start', function() return fault_fired(gate) end, 10)
  fault_release(gate)
end)
