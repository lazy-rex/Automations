-- The schema steps (docs/plugin-sdk.md in the hub, "A base step"): a new database gets the schema
-- of the old steps 1 to 12, and a database that the old steps made keeps its rows. Both tests
-- also pass on the old steps themselves (4fc4938), where the first start copies hub.store.
local dir = H.args.file:match('^(.*)/[^/]*$')
local F = assert(loadfile(dir .. '/support/fixture.lua'))()(H)
local OLD = assert(loadfile(dir .. '/support/schema12.lua'))()
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')
local VERSION = 12

-- The plugin's schema objects: sqlite_master (type, name, the SQL with its white space made
-- one space; not the sqlite_ and lazyrex_ objects), each table's columns and each index's
-- columns, in name order.
local function squash(s) return (s or ''):gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', '') end
local function schema()
  local out = {}
  for _, r in ipairs(sql([[SELECT type, name, tbl_name, sql FROM sqlite_master
      WHERE substr(name, 1, 7) <> 'sqlite_' AND substr(name, 1, 8) <> 'lazyrex_' ORDER BY type, name]])) do
    local o = {type = r.type, name = r.name, tbl = r.tbl_name, sql = squash(r.sql), cols = {}}
    local info = r.type == 'table' and 'pragma_table_info' or 'pragma_index_xinfo'
    for _, c in ipairs(sql('SELECT * FROM ' .. info .. '(?)', {r.name})) do o.cols[#o.cols + 1] = c end
    out[#out + 1] = o
  end
  return out
end
local function user_version() return sql('PRAGMA user_version')[1].user_version end

-- dump reads every row of the plugin's tables, in key order. It runs while the plugin is stopped.
local function dump()
  local out = {}
  for _, t in ipairs(F.TABLES) do out[t] = sql('SELECT * FROM ' .. t .. ' ORDER BY 1') end
  return out
end
-- rebuild makes a version-12 database from the old steps and inserts rows (a dump), all while the
-- plugin is stopped.
local function rebuild(rows)
  for _, t in ipairs(F.TABLES) do sql_write('DROP TABLE ' .. t) end
  sql_write('PRAGMA user_version = 0')
  for _, s in ipairs(OLD) do sql_write(s) end
  for t, list in pairs(rows or {}) do
    local cols = {}
    for _, c in ipairs(sql('SELECT name FROM pragma_table_info(?) ORDER BY cid', {t})) do cols[#cols + 1] = c.name end
    local marks = {}
    for i = 1, #cols do marks[i] = '?' end
    for _, row in ipairs(list) do
      local params = {}
      for i, c in ipairs(cols) do if row[c] == nil then params[i] = {null = true} else params[i] = row[c] end end
      sql_write('INSERT INTO ' .. t .. ' (' .. table.concat(cols, ', ') .. ') VALUES (' .. table.concat(marks, ', ') .. ')', params)
    end
  end
  sql_write('PRAGMA user_version = 12')
end
local function answers() return (pcall(alice.call, alice, 'automations.list', {})) end
-- A revision is a decimal string: compare by length, then as text.
local function above(a, b)
  if #a ~= #b then return #a > #b end
  return a > b
end

test('a new database has the schema of the old steps 1 to 12', function()
  local new = schema()
  expect(user_version()).to_be(VERSION)
  local names = {}
  for _, o in ipairs(new) do names[#names + 1] = o.name end
  expect(#names).to_be(#OLD)
  F.reload(function() rebuild() end)
  expect(user_version()).to_be(VERSION)
  expect(schema()).to_equal(new)
end)

test('a version-12 database from the old steps keeps its rows, its revision and its next ID', function()
  -- An empty database as the copy left it: the done marker and a revision counter.
  F.reload(function() rebuild({meta = {{name = 'import', value = 'cutover-1:done'}, {name = 'import_cursor', value = '9:'},
    {name = 'rev', value = '0'}}}) end)
  wait('the start', answers, 30)
  local made = rex.exec({'mkdir', '-p', H.args.lab .. '/home/knowledge'})
  assert(made and made.ok, 'mkdir failed')
  local a = alice:call('automations.save', {key = 'keep-a', name = 'Keep a', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Keep task.'}).id
  local first = alice:call('automations.run', {id = a, key = 'keep-a-1'})
  local run = F.wait_status(first.run_key, 'delivered', 30)
  F.worker(run.agent)
  local p
  for _, x in ipairs(alice:call('automations.presets', {}).presets) do if x.preset == 'vault-health' then p = x end end
  local b = alice:call('automations.save', {key = 'keep-b', preset = 'vault-health', name = p.name, trigger = p.trigger,
    action = {profile = 'worker', cwd = p.action.cwd}, instruction = p.instruction}).id
  -- No other work: no daily slot comes, and the delivered run waits for its worker's done.
  for _, id in ipairs({a, b}) do alice:call('automations.set_enabled', {id = id, enabled = false, key = 'keep-off-' .. id}) end
  rex.sleep(2)
  -- The old import rows of a database that the copy made (their live values).
  local rows = {}
  F.reload(function()
    rows.before = dump()
    local meta = {}
    for _, r in ipairs(rows.before.meta) do if r.name ~= 'import' and r.name ~= 'import_cursor' then meta[#meta + 1] = r end end
    meta[#meta + 1] = {name = 'import', value = 'cutover-1:done'}
    meta[#meta + 1] = {name = 'import_cursor', value = '9:'}
    table.sort(meta, function(x, y) return x.name < y.name end)
    rows.before.meta = meta
    rebuild(rows.before)
  end)
  wait('the start', answers, 30)
  expect(user_version()).to_be(VERSION)
  expect(dump()).to_equal(rows.before)
  local function meta(name) local r = sql('SELECT value FROM meta WHERE name = ?', {name})[1] return r and r.value end
  local rev = meta('rev')
  -- An old operation key replays its saved reply; a new automation takes the next ID and a
  -- revision above the old counter.
  expect(alice:call('automations.run', {id = a, key = 'keep-a-1'}).run_key).to_be(first.run_key)
  local c = alice:call('automations.save', {key = 'keep-c', name = 'Keep c', trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Keep task.'}).id
  expect(tonumber(c)).to_be(tonumber(b) + 1)
  expect(above(F.rev('automations', c), rev)).to_be(true)
end)
