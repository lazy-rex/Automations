-- The cutover (SDK port plan, "The cutover", slice 2): the start states, the copy from hub.store
-- and its gate, the revision counter, and the replay of old operation keys after the copy.
--
-- The fixture comes from the plugin itself: it runs on SQL, then the test writes each row to
-- hub.store in the layout of the slice 1 version (with the index records q/, t/, dv/ and box/),
-- stops the plugin, empties the tables and starts it again. The new instance then starts as the
-- first start of the cutover version on an old store does. A plugin stop and start keeps the hub
-- process, so the injections that the test arms while the plugin is stopped stay.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')
local MAX_T = 999999999999
local BACKLOG = 60
local MAX_REV = '9223372036854775807'
local TABLES = F.TABLES

local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end
-- A revision is a decimal string: compare by length, then as text.
local function below(a, b)
  if #a ~= #b then return #a < #b end
  return a < b
end
local function meta(name) local r = sql('SELECT value FROM meta WHERE name = ?', {name})[1] return r and r.value end
local function count(t) return #sql('SELECT 1 AS x FROM ' .. t) end
local function counts()
  local out = {}
  for _, t in ipairs(TABLES) do out[t] = count(t) end
  return out
end

-- The fixture on SQL: automation a with two delivered runs to one worker and a Run now of that
-- worker (its spawn ID becomes a legacy ID later), the vault-health preset (b), a deleted
-- highest ID (c), and a backlog of cancelled runs with their terminal entries.
local ids, worker = {}, {}
local function fixture()
  local made = rex.exec({'mkdir', '-p', H.args.lab .. '/home/knowledge'})
  assert(made and made.ok, 'mkdir failed')
  local a = alice:call('automations.save', {key = 'cut-a', name = 'Cutover a', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Cutover task.'}).id
  local first = alice:call('automations.run', {id = a, key = 'cut-a-1'})
  local one = F.wait_status(first.run_key, 'delivered', 30)
  local w = F.worker(one.agent)
  local second = w:call('automations.run', {id = a, key = 'cut-w-1'})
  F.wait_status(second.run_key, 'delivered', 30)
  local p
  for _, x in ipairs(alice:call('automations.presets', {}).presets) do if x.preset == 'vault-health' then p = x end end
  local b = alice:call('automations.save', {key = 'cut-b', preset = 'vault-health', name = p.name, trigger = p.trigger,
    action = {profile = 'worker', cwd = p.action.cwd}, instruction = p.instruction}).id
  local c = alice:call('automations.save', {key = 'cut-c', name = 'Cutover c', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Cutover task.'}).id
  alice:call('automations.delete', {id = c, key = 'cut-c-delete'})
  wait('automation ' .. c .. ' to be gone', function() return F.store('auto/' .. c).rev == '0' end, 30)
  local st_rec = F.store('state/' .. a)
  local base = st_rec.value.next_t or 0
  for lo = 1, BACKLOG, 30 do
    local ops = {}
    for n = lo, math.min(lo + 29, BACKLOG) do
      local seq = base + n
      ops[#ops + 1] = {key = manual(a, 100 + n), if_rev = '0', value = {kind = 'm', k = string.format('%06d', 100 + n), status = 'cancelled',
        attempt = 0, starts = 0, t = string.format('t/%s/%012d', a, MAX_T - seq), tseq = seq, task = F.run(first.run_key).task,
        cancelled = {by = 'alice', at = 1}}}
    end
    F.write(ops)
  end
  local st = F.store('state/' .. a)
  st.value.next_t = base + BACKLOG
  F.write({{key = 'state/' .. a, if_rev = st.rev, value = st.value}})
  ids = {a = a, b = b, c = c, first = first.run_key, second = second.run_key}
  worker = {agent = one.agent, pane = w}
end

-- check compares every SQL row with its store record, and every store record with its row.
local function check()
  local n = 0
  local function compare(key, row)
    local rec = store(key)
    expect(rec.rev).to_be(row.rev)
    if not same(rex.json.decode(row.doc), rec.value) then error('the document of ' .. key .. ' differs from the store record') end
    n = n + 1
  end
  for _, r in ipairs(sql('SELECT id, rev, doc FROM automations')) do compare('auto/' .. r.id, r) end
  for _, r in ipairs(sql('SELECT id, rev, doc FROM states')) do compare('state/' .. r.id, r) end
  for _, r in ipairs(sql('SELECT run_key, rev, doc FROM runs')) do compare(r.run_key, r) end
  for _, r in ipairs(sql('SELECT key, rev, doc FROM seen')) do compare(r.key, r) end
  for _, r in ipairs(sql('SELECT key, rev, doc FROM retired')) do compare(r.key, r) end
  for _, r in ipairs(sql('SELECT name, rev, automation_id FROM presets')) do
    local rec = store('preset/' .. r.name)
    expect(rec.rev).to_be(r.rev)
    expect(rec.value.id).to_be(r.automation_id)
  end
  expect(count('automations')).to_be(2)
  expect(count('states')).to_be(2)
  expect(count('runs')).to_be(2 + BACKLOG)
  expect(store('auto/' .. ids.c).rev).to_be('0')
  expect(meta('next_id')).to_be(tostring(store('meta/next_id').value.n))
  expect(meta('next_id_rev')).to_be(store('meta/next_id').rev)
  -- R is the store's revision of meta/cutover: above every copied revision.
  local r = meta('rev')
  expect(r).to_be(store('meta/cutover').rev)
  for _, t in ipairs({'automations', 'states', 'runs', 'presets', 'seen', 'retired'}) do
    for _, row in ipairs(sql('SELECT rev FROM ' .. t)) do
      if not below(row.rev, r) then error('the copied revision ' .. row.rev .. ' of ' .. t .. ' is not below R ' .. r) end
    end
  end
  local drift = sql([[SELECT run_key FROM runs WHERE status IS NOT json_extract(doc, '$.status') OR q IS NOT json_extract(doc, '$.q')
    OR t IS NOT json_extract(doc, '$.t') OR agent IS NOT json_extract(doc, '$.agent')]])
  expect(#drift).to_be(0)
  return n
end
local function marker() return meta('import') end

-- The gate check while the copy is held: every export and view answers the import text, and
-- nothing changes.
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

test('the first start copies the store exactly; the gate holds until done', function()
  wait('the first copy', function() return marker() == 'cutover-1:done' end, 30)
  fixture()
  rex.sleep(2)
  F.to_store()
  -- The copy fails at its first run page 10 times (a retry each second), then goes on.
  local inj
  F.reload(function()
    F.empty_tables()
    inj = inject({match = {sql_commit_writes = 'runs'}, fail = 'held for the gate test', fail_code = 'unavailable', times = 10})
  end)
  wait('the held run page', function() return injection(inj).consumed >= 1 end, 30)
  expect(marker()).to_be('cutover-1:copying')
  expect_closed('importing')
  wait('the copy', function() return marker() == 'cutover-1:done' end, 60)
  expect(check()).to_be(2 + 2 + 2 + BACKLOG)
end)

test('after the copy: old keys replay from ops, also under a legacy ID, and the next ID is new', function()
  -- The worker's pane takes a conversation identity: the spawn ID is now its legacy ID.
  worker.pane:report('claude', 'automations-cutover-1')
  rex.sleep(2.5)
  expect(worker.pane:call('automations.run', {id = ids.a, key = 'cut-w-1'}).run_key).to_be(ids.second)
  expect_error(function() worker.pane:call('automations.run', {id = ids.b, key = 'cut-w-1'}) end, 'conflict')
  expect(alice:call('automations.run', {id = ids.a, key = 'cut-a-1'}).run_key).to_be(ids.first)
  local d = alice:call('automations.save', {key = 'cut-d', name = 'Cutover d', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Cutover task.'}).id
  expect(tonumber(d) > tonumber(ids.c)).to_be(true)
  -- An old revision is a conflict.
  local a = F.store('auto/' .. ids.a)
  local stale = store('auto/' .. ids.a).rev
  expect(stale).to_be(a.rev)
  alice:call('automations.set_enabled', {id = ids.a, enabled = false, key = 'cut-a-off'})
  local view = F.view(alice, ids.a)
  expect_error(function() alice:call('automations.save', {id = ids.a, if_rev = stale, key = 'cut-a-stale', name = view.name,
    trigger = view.trigger, action = view.action, instruction = view.instruction}) end, 'conflict')
end)

test('a delivery after the copy: the task and its notice commit together; a lost reply delivers once', function()
  alice:call('automations.set_enabled', {id = ids.a, enabled = true, key = 'cut-a-on'})
  -- The fixture's two tasks end first, so the worker has no pending notice.
  local agent = F.run(ids.first).agent
  for _, rk in ipairs({ids.first, ids.second}) do
    worker.pane:call('automations.done', {run_key = rk, attempt = F.run(rk).attempt, key = 'cut-done-' .. rk})
  end
  wait('no pending notice', function() return notice(agent).pending == false end, 10)
  -- The delivery commit is held: the commits with this run key as a parameter are the creation
  -- (skip = 1) and then each try of the delivery, which fails until the test cancels it.
  local rk = manual(ids.a, (F.store('state/' .. ids.a).value.next_manual or 0) + 1)
  local _, base = calls('none')
  local held = inject({match = {sql_commit_writes = 'runs', sql_param = rk}, skip = 1, fail = 'held delivery', fail_code = 'unavailable',
    times = 'always'})
  expect(alice:call('automations.run', {id = ids.a, key = 'cut-a-2'}).run_key).to_be(rk)
  wait('the held delivery commit', function() return injection(held).consumed >= 2 end, 30)
  -- Before the commit: the run is queued, and the worker has no task and no notice.
  expect(F.run(rk).status).to_be('queued')
  expect(F.store('box/' .. agent .. '/' .. rk).rev).to_be('0')
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
  -- The run, its delivery and its notice used no hub.store call: after the copy, no path reads or
  -- writes the store, and the notice went through hub.sql (a store notify would be notices_moved).
  for _, action in ipairs({'hub.store.batch', 'hub.store.get', 'hub.store.scan', 'hub.store.op'}) do
    local list, reply = calls(action, {after = base.next})
    expect(reply.dropped).to_be(false)
    expect(#list).to_be(0)
  end
  -- A lost reply: the commit happens, and the plugin gets an error. The run is delivered once.
  local lost = inject({match = {sql_commit_writes = 'runs'}, skip = 1, fail = 'lost delivery reply', after = true, times = 1})
  local r2 = alice:call('automations.run', {id = ids.a, key = 'cut-a-3'})
  local run2 = F.wait_status(r2.run_key, 'delivered', 30)
  rex.sleep(3)
  expect(injection(lost).consumed).to_be(1)
  expect(F.store(r2.run_key).value.attempt).to_be(run2.attempt)
  local tasks = F.worker(run2.agent):call('automations.read', {}).tasks
  local n = 0
  for _, t in ipairs(tasks) do if t.run_key == r2.run_key then n = n + 1 end end
  expect(n).to_be(1)
end)

test('the revision counter refuses at the int64 maximum and changes nothing', function()
  local function save(key)
    return alice:call('automations.save', {key = key, name = 'Counter ' .. key, trigger = {kind = 'daily', at = '09:00'},
      action = {profile = 'worker'}, instruction = 'Counter task.'})
  end
  -- A save writes three rows (automation, state, next ID): from MAX - 3 it takes the last three.
  sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {'9223372036854775804'})
  save('max-1')
  expect(meta('rev')).to_be(MAX_REV)
  local before = counts()
  local err = expect_error(function() save('max-2') end, 'internal')
  expect(err.message).to_match('maximum')
  expect(same(counts(), before)).to_be(true)
  expect(meta('rev')).to_be(MAX_REV)
  -- A counter that is not canonical refuses too.
  sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {'0123'})
  expect_error(function() save('bad-1') end, 'internal')
  expect(same(counts(), before)).to_be(true)
  -- A value above the maximum, and text that is not a number, refuse too.
  for i, bad in ipairs({'9223372036854775808', '12a'}) do
    sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {bad})
    expect_error(function() save('bad-' .. (i + 1)) end, 'internal')
    expect(same(counts(), before)).to_be(true)
    expect(meta('rev')).to_be(bad)
  end
  -- A commit whose later write finds the maximum rolls back its earlier writes and the counter:
  -- from MAX - 2, a save takes two revisions, and its third write fails.
  local next_id = meta('next_id')
  sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {'9223372036854775805'})
  err = expect_error(function() save('max-3') end, 'internal')
  expect(err.message).to_match('maximum')
  expect(same(counts(), before)).to_be(true)
  expect(meta('rev')).to_be('9223372036854775805')
  expect(meta('next_id')).to_be(next_id)
  -- The counter stays at the maximum: a lower value could give a revision again. The crash test
  -- after this one copies again and takes a new R.
  sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {MAX_REV})
end)

-- Each refused start state: no write, and the exports and views give the reason.
local function refused(setup, text)
  F.reload(setup)
  rex.sleep(3)
  local before = counts()
  expect_closed(text)
  rex.sleep(2)
  expect(same(counts(), before)).to_be(true)
end
test('a start on rows without a valid marker refuses and writes nothing', function()
  local saved = {import = meta('import'), cursor = meta('import_cursor'), rev = meta('rev')}
  refused(function() sql_write("DELETE FROM meta WHERE name = 'import'") end, 'not known')
  refused(function() sql_write("INSERT INTO meta (name, value) VALUES ('import', 'cutover-9:done')") end, 'unknown import marker')
  refused(function() sql_write("UPDATE meta SET value = 'cutover-1:copying' WHERE name = 'import'")
    sql_write("INSERT INTO meta (name, value) VALUES ('import_cursor', '99:') ON CONFLICT (name) DO UPDATE SET value = excluded.value") end, 'cursor')
  refused(function() sql_write("UPDATE meta SET value = '4:auto/1' WHERE name = 'import_cursor'") end, 'cursor')
  refused(function() sql_write("UPDATE meta SET value = 'cutover-1:done' WHERE name = 'import'")
    sql_write("DELETE FROM meta WHERE name = 'rev'") end, 'revision counter')
  -- The lab import layout of f962e2b is refused too.
  refused(function() sql_write("DELETE FROM meta WHERE name = 'import'")
    sql_write("INSERT INTO meta (name, value) VALUES ('imported', 'store')") end, 'not known')
  sql_write("DELETE FROM meta WHERE name = 'imported'")
  sql_write("INSERT INTO meta (name, value) VALUES ('import', ?)", {saved.import})
  sql_write("INSERT INTO meta (name, value) VALUES ('rev', ?)", {saved.rev})
  -- A restart on done keeps the SQL-only changes and does not copy again.
  local cutover_rev = store('meta/cutover').rev
  F.reload()
  wait('the start on done', function()
    local ok = pcall(alice.call, alice, 'automations.list', {})
    return ok
  end, 30)
  expect(store('meta/cutover').rev).to_be(cutover_rev)
  expect(F.store('auto/' .. ids.a).rev ~= store('auto/' .. ids.a).rev).to_be(true)
end)

test('a crash during the copy resumes from its committed cursor', function()
  -- The hub crash ends the injection with the hub process.
  local inj
  F.reload(function()
    F.empty_tables()
    inj = inject({match = {sql_commit_writes = 'runs'}, skip = 1, fail = 'held for the crash test', fail_code = 'unavailable', times = 'always'})
  end)
  wait('the held second run page', function() return injection(inj).consumed >= 1 end, 60)
  local keys = sql('SELECT run_key FROM runs ORDER BY run_key')
  expect(#keys).to_be(50)
  expect(meta('import_cursor')).to_be('4:' .. keys[50].run_key)
  hub:restart({crash = true})
  wait('the copy', function() return marker() == 'cutover-1:done' end, 60)
  expect(check()).to_be(2 + 2 + 2 + BACKLOG)
end)
