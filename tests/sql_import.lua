-- The import from hub.store into the SQL tables (SDK port plan, slice 2). No production path reads
-- the tables yet, so these tests compare them with the store. Needs hub.sql and the harness sql()
-- and sql_write() (lab branch hub/sql-r2, c840c92 or later).
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')
local MAX_T = 999999999999
local BACKLOG = 60

local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function same(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= 'table' then return a == b end
  for k, v in pairs(a) do if not same(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

-- The fixture: two delivered runs, a preset, a deleted highest ID, and a backlog of
-- cancelled runs that the harness writes (more than one import page).
local ids = {}
local function fixture()
  local made = rex.exec({'mkdir', '-p', H.args.lab .. '/home/knowledge'})
  assert(made and made.ok, 'mkdir failed')
  local a = alice:call('automations.save', {key = 'imp-a', name = 'Import a', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Import task.'}).id
  alice:call('automations.run', {id = a, key = 'imp-a-1'})
  F.wait_status(manual(a, 1), 'delivered', 30)
  alice:call('automations.run', {id = a, key = 'imp-a-2'})
  F.wait_status(manual(a, 2), 'delivered', 30)
  local p
  for _, x in ipairs(alice:call('automations.presets', {}).presets) do if x.preset == 'vault-health' then p = x end end
  local b = alice:call('automations.save', {key = 'imp-b', preset = 'vault-health', name = p.name, trigger = p.trigger,
    action = {profile = 'worker', cwd = p.action.cwd}, instruction = p.instruction}).id
  local c = alice:call('automations.save', {key = 'imp-c', name = 'Import c', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Import task.'}).id
  alice:call('automations.delete', {id = c, key = 'imp-c-delete'})
  wait('automation ' .. c .. ' to be gone', function() return store('auto/' .. c).rev == '0' end, 30)
  -- The backlog: cancelled runs of automation a, with their terminal entries and sequence.
  local st_rec = store('state/' .. a)
  local base = st_rec.value.next_t or 0
  for lo = 1, BACKLOG, 30 do
    local ops = {}
    for n = lo, math.min(lo + 29, BACKLOG) do
      local seq = base + n
      local run_key = manual(a, 100 + n)
      local t = string.format('t/%s/%012d', a, MAX_T - seq)
      ops[#ops + 1] = {key = run_key, if_rev = '0', value = {kind = 'm', k = string.format('%06d', 100 + n), status = 'cancelled',
        attempt = 0, starts = 0, t = t, tseq = seq, task = F.run(manual(a, 1)).task, cancelled = {by = 'alice', at = 1}}}
      ops[#ops + 1] = {key = t, if_rev = '0', value = {run = run_key, seq = seq}}
    end
    write(ops)
  end
  local st = st_rec.value
  st.next_t = base + BACKLOG
  write({{key = 'state/' .. a, if_rev = st_rec.rev, value = st}})
  ids = {a = a, b = b, c = c}
end

-- reimport empties the tables and restarts the hub: the plugin starts on a store without an
-- import, as the first start of the ported plugin does.
local function empty_tables()
  for _, t in ipairs({'meta', 'automations', 'states', 'runs', 'presets', 'seen', 'retired', 'ops'}) do sql_write('DELETE FROM ' .. t) end
end
local function imported() local r = sql('SELECT value FROM meta WHERE name = ?', {'imported'}) return r[1] and r[1].value end

-- check compares every SQL row with its store record, and every store record of the fixture with
-- its row. It also checks that the query columns equal the fields of their document.
local function check()
  local count = 0
  local function compare(key, row)
    local rec = store(key)
    expect(rec.rev).to_be(row.rev)
    if not same(rex.json.decode(row.doc), rec.value) then error('the document of ' .. key .. ' differs from the store record') end
    count = count + 1
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
  -- The store side: each record of the fixture has its row.
  expect(#sql('SELECT id FROM automations')).to_be(2)
  expect(#sql('SELECT id FROM states')).to_be(2)
  expect(#sql('SELECT run_key FROM runs')).to_be(2 + BACKLOG)
  expect(sql('SELECT automation_id FROM presets WHERE name = ?', {'vault-health'})[1].automation_id).to_be(ids.b)
  expect(store('auto/' .. ids.c).rev).to_be('0')
  expect(sql('SELECT value FROM meta WHERE name = ?', {'next_id'})[1].value).to_be(tostring(store('meta/next_id').value.n))
  local drift = sql([[SELECT run_key FROM runs WHERE status IS NOT json_extract(doc, '$.status') OR q IS NOT json_extract(doc, '$.q')
    OR t IS NOT json_extract(doc, '$.t') OR agent IS NOT json_extract(doc, '$.agent')
    OR automation_id IS NOT substr(run_key, 5, instr(substr(run_key, 5), '/') - 1)]])
  expect(#drift).to_be(0)
  -- The saved replies: the six mutations of the fixture, exactly as the store saved them.
  local ops = sql('SELECT key, fingerprint, reply FROM ops ORDER BY key')
  expect(#ops).to_be(6)
  local save_a = sql('SELECT fingerprint, reply FROM ops WHERE key = ?', {'save/5:alice5:imp-a'})[1]
  expect(save_a.fingerprint:sub(1, 8)).to_be('save-v1/')
  expect(rex.json.decode(save_a.reply).id).to_be(ids.a)
  return count
end

test('the import copies each record exactly, with its rev, and the columns equal the document', function()
  fixture()
  rex.sleep(3)
  empty_tables()
  hub:restart()
  wait('the import', imported, 60)
  expect(imported()).to_be('store')
  expect(check()).to_be(2 + 2 + 2 + BACKLOG)
end)

-- A crash between import pages. Faults and injections live in the hub process, and the import runs
-- at the plugin start, so the test cannot stop it between two pages from outside. It writes the
-- state that such a crash leaves instead (a fixture): the rows of the first page of runs, the
-- cursor after that page, and no imported mark. Then it crashes the hub: the import resumes from
-- the cursor, and each record is copied once.
test('a crash between import pages: the import resumes from its cursor and copies each record once', function()
  local keys = sql('SELECT run_key FROM runs ORDER BY run_key')
  expect(#keys).to_be(2 + BACKLOG)
  sql_write('DELETE FROM runs WHERE run_key > ?', {keys[50].run_key})
  sql_write('DELETE FROM presets')
  sql_write('DELETE FROM meta WHERE name = ?', {'imported'})
  sql_write('UPDATE meta SET value = ? WHERE name = ?', {'4:' .. keys[50].run_key, 'import_cursor'})
  expect(#sql('SELECT run_key FROM runs')).to_be(50)
  hub:restart({crash = true})
  wait('the import', imported, 60)
  expect(sql('SELECT value FROM meta WHERE name = ?', {'import_cursor'})[1].value:match('^8:')).to_be_truthy()
  expect(check()).to_be(2 + 2 + 2 + BACKLOG)
end)
