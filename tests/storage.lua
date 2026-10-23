-- The SQL storage: the revision counter of a new database, the replay of saved operation keys, a
-- delivery and its notice in one commit, the start refusals of counters that are not valid, and
-- the counter limit.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')
local MAX_REV = '9223372036854775807'

local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
local function meta(name) local r = sql('SELECT value FROM meta WHERE name = ?', {name})[1] return r and r.value end
local function count(t) return #sql('SELECT 1 AS x FROM ' .. t) end
local function counts()
  local out = {}
  for _, t in ipairs(F.TABLES) do out[t] = count(t) end
  return out
end

-- The gate check of a refused start: every export and view answers the reason, and nothing
-- changes.
local function expect_closed(text)
  local before = counts()
  local err = expect_error(function() alice:call('automations.list', {}) end, 'unavailable')
  expect(err.message).to_match(text)
  expect_error(function() alice:call('automations.save', {key = 'closed-save', name = 'Closed', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Closed.'}) end, 'unavailable')
  local _, tree = F.panel()
  expect(H.node(tree, 'not_ready').text).to_match(text)
  expect(same(counts(), before)).to_be(true)
end

test('a new database starts the revision counter at 0', function()
  expect(meta('rev')).to_be('0')
  expect(meta('next_id')).to_be(nil)
  expect(meta('next_id_rev')).to_be(nil)
end)

-- The fixture: automation a with two delivered runs to one worker, the second from a Run now of
-- that worker, and automation b. ids and worker are table fields: a closure write to a captured
-- local can be lost after a caught error (Rex Lua runtime, docs/rex-protocol.md in the hub).
local ids, worker = {}, {}
test('saved operation keys replay, and the next ID is new', function()
  local a = alice:call('automations.save', {key = 'st-a', name = 'Storage a', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Storage task.'}).id
  local first = alice:call('automations.run', {id = a, key = 'st-a-1'})
  local one = F.wait_status(first.run_key, 'delivered', 30)
  local w = F.worker(one.agent)
  local second = w:call('automations.run', {id = a, key = 'st-w-1'})
  F.wait_status(second.run_key, 'delivered', 30)
  local b = alice:call('automations.save', {key = 'st-b', name = 'Storage b', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Storage task.'}).id
  ids.a, ids.b, ids.first, ids.second = a, b, first.run_key, second.run_key
  worker.agent, worker.pane = one.agent, w
  expect(w:call('automations.run', {id = a, key = 'st-w-1'}).run_key).to_be(second.run_key)
  expect_error(function() w:call('automations.run', {id = b, key = 'st-w-1'}) end, 'conflict')
  expect(alice:call('automations.run', {id = a, key = 'st-a-1'}).run_key).to_be(first.run_key)
  local d = alice:call('automations.save', {key = 'st-d', name = 'Storage d', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Storage task.'}).id
  expect(tonumber(d)).to_be(tonumber(b) + 1)
  -- An old revision is a conflict.
  local stale = F.rev('automations', a)
  alice:call('automations.set_enabled', {id = a, enabled = false, key = 'st-a-off'})
  local view = F.view(alice, a)
  expect_error(function() alice:call('automations.save', {id = a, if_rev = stale, key = 'st-a-stale', name = view.name,
    trigger = view.trigger, action = view.action, instruction = view.instruction}) end, 'conflict')
end)

test('a delivery: the task and its notice commit together; a lost reply delivers once', function()
  alice:call('automations.set_enabled', {id = ids.a, enabled = true, key = 'st-a-on'})
  -- The fixture's two tasks end first, so the worker has no pending notice.
  local agent = F.run(ids.first).agent
  for _, rk in ipairs({ids.first, ids.second}) do
    worker.pane:call('automations.done', {run_key = rk, attempt = F.run(rk).attempt, key = 'st-done-' .. rk})
  end
  wait('no pending notice', function() return notice(agent).pending == false end, 10)
  -- The delivery commit is held: the commits with this run key as a parameter are the creation
  -- (skip = 1) and then each try of the delivery, which fails until the test cancels it.
  local rk = manual(ids.a, (F.state(ids.a).next_manual or 0) + 1)
  local held = inject({match = {sql_commit_writes = 'runs', sql_param = rk}, skip = 1, fail = 'held delivery', fail_code = 'unavailable',
    times = 'always'})
  expect(alice:call('automations.run', {id = ids.a, key = 'st-a-2'}).run_key).to_be(rk)
  wait('the held delivery commit', function() return injection(held).consumed >= 2 end, 30)
  -- Before the commit: the run is queued, and the worker has no task and no notice.
  expect(F.run(rk).status).to_be('queued')
  expect(F.held(agent, rk)).to_be(nil)
  expect(notice(agent).pending).to_be(false)
  for _, t in ipairs(worker.pane:call('automations.read', {}).tasks) do expect(t.run_key).not_to_be(rk) end
  cancel_injection(held)
  local run = F.wait_status(rk, 'delivered', 30)
  expect(run.agent).to_be(agent)
  expect(run.attempt).to_be(1)
  expect(notice(agent).pending).to_be(true)
  local seen = 0
  for _, t in ipairs(worker.pane:call('automations.read', {}).tasks) do if t.run_key == rk then seen = seen + 1 end end
  expect(seen).to_be(1)
  -- A lost reply: the commit happens, and the plugin gets an error. The run is delivered once.
  local lost = inject({match = {sql_commit_writes = 'runs'}, skip = 1, fail = 'lost delivery reply', after = true, times = 1})
  local r2 = alice:call('automations.run', {id = ids.a, key = 'st-a-3'})
  local run2 = F.wait_status(r2.run_key, 'delivered', 30)
  rex.sleep(3)
  expect(injection(lost).consumed).to_be(1)
  expect(F.run(r2.run_key).attempt).to_be(run2.attempt)
  local tasks = F.worker(run2.agent):call('automations.read', {}).tasks
  local n = 0
  for _, t in ipairs(tasks) do if t.run_key == r2.run_key then n = n + 1 end end
  expect(n).to_be(1)
end)

-- Each refused start: no write, and the exports and views give the reason. restore puts the
-- meta rows back while the plugin is stopped.
local function refused(setup, text, restore)
  F.reload(setup)
  rex.sleep(3)
  local before = counts()
  expect_closed(text)
  rex.sleep(2)
  expect(same(counts(), before)).to_be(true)
  F.reload(restore)
  wait('the start after the restore', F.started, 30)
end
test('a start with counters that are not valid refuses and writes nothing; a restart keeps the rows', function()
  local saved = {rev = meta('rev'), n = meta('next_id'), r = meta('next_id_rev')}
  local function restore()
    sql_write("DELETE FROM meta WHERE name IN ('rev', 'next_id', 'next_id_rev')")
    sql_write("INSERT INTO meta (name, value) VALUES ('rev', ?), ('next_id', ?), ('next_id_rev', ?)", {saved.rev, saved.n, saved.r})
  end
  refused(function() sql_write("DELETE FROM meta WHERE name = 'rev'") end, 'revision counter', restore)
  for _, bad in ipairs({'0123', '12a', '9223372036854775808'}) do
    refused(function() sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {bad}) end, 'revision counter', restore)
  end
  refused(function() sql_write("DELETE FROM meta WHERE name = 'next_id_rev'") end, 'next ID', restore)
  refused(function() sql_write("DELETE FROM meta WHERE name = 'next_id'") end, 'next ID', restore)
  refused(function() sql_write("UPDATE meta SET value = 'x' WHERE name = 'next_id'") end, 'next ID', restore)
  refused(function() sql_write("UPDATE meta SET value = '01' WHERE name = 'next_id_rev'") end, 'next ID', restore)
  -- A restart on valid counters keeps every row and starts again.
  local before, rev = counts(), F.rev('automations', ids.a)
  F.reload()
  wait('the start', F.started, 30)
  expect(alice:call('automations.run', {id = ids.a, key = 'st-a-1'}).run_key).to_be(ids.first)
  expect(same(counts(), before)).to_be(true)
  expect(F.rev('automations', ids.a)).to_be(rev)
end)

test('the revision counter refuses at the int64 maximum and changes nothing', function()
  local function save(key)
    return alice:call('automations.save', {key = key, name = 'Counter ' .. key, trigger = {kind = 'daily', at = '09:00'},
      action = {profile = 'worker'}, instruction = 'Counter task.'})
  end
  -- A save writes three rows (automation, state, next ID): from MAX - 3 it takes the last three.
  -- The plugin runs, so each write tries again while a step has a transaction open (busy).
  F.sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {'9223372036854775804'})
  save('max-1')
  expect(meta('rev')).to_be(MAX_REV)
  local before = counts()
  local err = expect_error(function() save('max-2') end, 'internal')
  expect(err.message).to_match('maximum')
  expect(same(counts(), before)).to_be(true)
  expect(meta('rev')).to_be(MAX_REV)
  -- A counter that is not canonical refuses too.
  F.sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {'0123'})
  expect_error(function() save('bad-1') end, 'internal')
  expect(same(counts(), before)).to_be(true)
  -- A value above the maximum, and text that is not a number, refuse too.
  for i, bad in ipairs({'9223372036854775808', '12a'}) do
    F.sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {bad})
    expect_error(function() save('bad-' .. (i + 1)) end, 'internal')
    expect(same(counts(), before)).to_be(true)
    expect(meta('rev')).to_be(bad)
  end
  -- A commit whose later write finds the maximum rolls back its earlier writes and the counter:
  -- from MAX - 2, a save takes two revisions, and its third write fails.
  local next_id = meta('next_id')
  F.sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {'9223372036854775805'})
  err = expect_error(function() save('max-3') end, 'internal')
  expect(err.message).to_match('maximum')
  expect(same(counts(), before)).to_be(true)
  expect(meta('rev')).to_be('9223372036854775805')
  expect(meta('next_id')).to_be(next_id)
  -- The counter stays at the maximum: a lower value could give a revision again. This test is the
  -- file's last.
  F.sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {MAX_REV})
end)
