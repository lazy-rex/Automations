-- The SQL storage of Automations (SDK port plan, slice 2: document tables; coordinator decision,
-- 2026-10-22: the target schema of release 4). Each record value of the hub.store layout stays one
-- JSON document. The fields that queries need are extra columns, and only the write functions set
-- them, from the document, in the same statement. This module has the schema and the copy from
-- hub.store; the runtime reads and writes are in automations_db.lua.
-- Load it with dofile(...)(A): A.app (the SDK app), A.fail, A.scan (the hub.store scan of the
-- plugin), A.hub (the plugin's hub call), A.canonical and A.valid_counter (from automations_db.lua).
return function(A)
  local db, fail = A.app.db, A.fail
  local M = {}

  M.migrations = {
    'CREATE TABLE meta (name TEXT PRIMARY KEY, value TEXT NOT NULL)',
    'CREATE TABLE automations (id TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE states (id TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE runs (run_key TEXT PRIMARY KEY, automation_id TEXT NOT NULL, rev TEXT NOT NULL, status TEXT NOT NULL, q TEXT, t TEXT, agent TEXT, doc TEXT NOT NULL)',
    'CREATE UNIQUE INDEX runs_q ON runs (q) WHERE q IS NOT NULL',
    'CREATE UNIQUE INDEX runs_t ON runs (t) WHERE t IS NOT NULL',
    "CREATE INDEX runs_delivered ON runs (agent, run_key) WHERE status = 'delivered'",
    'CREATE INDEX runs_auto ON runs (automation_id, status)',
    'CREATE TABLE presets (name TEXT PRIMARY KEY, rev TEXT NOT NULL, automation_id TEXT NOT NULL)',
    'CREATE TABLE seen (key TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE retired (key TEXT PRIMARY KEY, rev TEXT NOT NULL, doc TEXT NOT NULL)',
    'CREATE TABLE ops (key TEXT PRIMARY KEY, fingerprint TEXT, reply TEXT NOT NULL)',
  }

  local encode = rex.json.encode
  local function text(v) if v == nil then return nil end return tostring(v) end

  local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end
  -- copy inserts one imported row. Only a conflict on the row's own key does nothing (an import
  -- step that runs again after a crash), and then the stored row must be the same; any other
  -- conflict, for example a second run with the same queue entry, fails the step.
  -- A JSON column is compared as its value: the key order of an encoding is not fixed.
  local JSON = {doc = true, reply = true}
  local function copy(tbl, cols, values)
    local marks = {}
    for i = 1, #cols do marks[i] = '?' end
    local r = db.exec('INSERT INTO ' .. tbl .. ' (' .. table.concat(cols, ', ') .. ') VALUES (' .. table.concat(marks, ', ')
      .. ') ON CONFLICT (' .. cols[1] .. ') DO NOTHING', unpack(values, 1, #cols))
    if r.changes == 1 then return end
    local row = db.first('SELECT ' .. table.concat(cols, ', ') .. ' FROM ' .. tbl .. ' WHERE ' .. cols[1] .. ' = ?', values[1])
    for i, c in ipairs(cols) do
      local equal = row[c] == values[i]
      if not equal and JSON[c] and row[c] and values[i] then equal = same(rex.json.decode(row[c]), rex.json.decode(values[i])) end
      if not equal then
        error({code = 'conflict', message = 'The import of ' .. tostring(values[1]) .. ' meets another ' .. tbl .. ' row (' .. c .. ')'}, 0)
      end
    end
  end
  local put = {}
  function put.automation(id, rev, value) copy('automations', {'id', 'rev', 'doc'}, {id, rev, encode(value)}) end
  function put.state(id, rev, value) copy('states', {'id', 'rev', 'doc'}, {id, rev, encode(value)}) end
  -- A run key is run/<id>/<kind>/<k>; its automation is the second part.
  function put.run(run_key, rev, value)
    local id = run_key:match('^run/([^/]+)/')
    if not id then error({code = 'internal', message = 'A run key without an automation: ' .. run_key}, 0) end
    copy('runs', {'run_key', 'automation_id', 'rev', 'status', 'q', 't', 'agent', 'doc'},
      {run_key, id, rev, tostring(value.status), text(value.q), text(value.t), text(value.agent), encode(value)})
  end
  function put.preset(name, rev, value) copy('presets', {'name', 'rev', 'automation_id'}, {name, rev, tostring(value.id)}) end
  function put.seen(key, rev, value) copy('seen', {'key', 'rev', 'doc'}, {key, rev, encode(value)}) end
  function put.retired(key, rev, value) copy('retired', {'key', 'rev', 'doc'}, {key, rev, encode(value)}) end

  -- The copy (plan, "The cutover", points 1 and 3). Each step copies one page of one store prefix
  -- in one transaction and moves meta.import_cursor in it. The index records (q/, t/, dv/, box/)
  -- are not copied: the run documents carry their fields.
  local IMPORT_PAGE = 50
  local PREFIXES = {
    {prefix = 'meta/', put = function(key, rec)
      if key == 'meta/next_id' then
        copy('meta', {'name', 'value'}, {'next_id', tostring(rec.value.n)})
        copy('meta', {'name', 'value'}, {'next_id_rev', rec.rev})
      end
    end},
    {prefix = 'auto/', put = function(key, rec) put.automation(key:sub(6), rec.rev, rec.value) end},
    {prefix = 'state/', put = function(key, rec) put.state(key:sub(7), rec.rev, rec.value) end},
    {prefix = 'run/', put = function(key, rec) put.run(key, rec.rev, rec.value) end},
    {prefix = 'preset/', put = function(key, rec) put.preset(key:sub(8), rec.rev, rec.value) end},
    {prefix = 'seen/', put = function(key, rec) put.seen(key, rec.rev, rec.value) end},
    {prefix = 'rt/', put = function(key, rec) put.retired(key, rec.rev, rec.value) end},
    -- The saved replies of hub.store operations, exactly: key, fingerprint and result.
    {ops = true, put = function(key, op)
      copy('ops', {'key', 'fingerprint', 'reply'}, {key, op.fingerprint, encode(op.result == nil and {} or op.result)})
    end},
  }
  -- The step after the last prefix: the revision R (see M.copy_step).
  local R_STEP = #PREFIXES + 1
  -- fetch reads one page of a step: a store prefix (hub.store.scan) or the saved operations
  -- (hub.store.ops_scan). It answers the keys in order, the entries by key, and the next cursor.
  local function fetch(p, after)
    if not p.ops then return A.scan(p.prefix, after, IMPORT_PAGE) end
    local page = A.hub('hub.store.ops_scan', {after = after, limit = IMPORT_PAGE})
    local keys, entries = {}, {}
    for _, op in ipairs(page.ops or {}) do keys[#keys + 1] = op.key; entries[op.key] = op end
    return keys, entries, page.next
  end
  local function meta(name)
    local row = db.first('SELECT value FROM meta WHERE name = ?', name)
    return row and row.value
  end
  local function set_meta(name, value)
    db.exec('INSERT INTO meta (name, value) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value', name, value)
  end

  -- The storage state at start: one of the five paths of the plan.
  M.VERSION = 'cutover-1'
  local TABLES = {'meta', 'automations', 'states', 'runs', 'presets', 'seen', 'retired', 'ops'}
  local function parse_cursor(cursor)
    local n, after = (cursor or ''):match('^([1-9]%d*):(.*)$')
    n = tonumber(n)
    if not n or n > R_STEP then return nil end
    local p = PREFIXES[n]
    -- The key after the colon belongs to the step: a key of its prefix, or a saved operation key.
    if after ~= '' and p and not p.ops and after:sub(1, #p.prefix) ~= p.prefix then return nil end
    if n == R_STEP and after ~= '' then return nil end
    return n, after
  end
  -- state() answers 'empty', 'copying' or 'done', or nil and the reason to refuse.
  function M.state()
    local marker = meta('import')
    if marker == nil then
      for _, t in ipairs(TABLES) do
        if db.first('SELECT 1 AS x FROM ' .. t .. ' LIMIT 1') then return nil, 'rows without an import marker (table ' .. t .. ')' end
      end
      return 'empty'
    end
    if marker == M.VERSION .. ':copying' then
      if not parse_cursor(meta('import_cursor')) then return nil, 'a copy cursor that is not valid: ' .. tostring(meta('import_cursor')) end
      return 'copying'
    end
    if marker == M.VERSION .. ':done' then
      if not A.valid_counter(meta('rev')) then return nil, 'a done copy without a valid revision counter: ' .. tostring(meta('rev')) end
      -- meta.next_id is absent when the store never had an automation; then its rev is absent too.
      local n, r = meta('next_id'), meta('next_id_rev')
      if (n == nil) ~= (r == nil) or (n and not (A.canonical(n) and A.canonical(r))) then return nil, 'a next ID that is not valid' end
      return 'done'
    end
    return nil, 'an unknown import marker: ' .. marker
  end
  -- begin() starts the copy on empty tables, in one transaction that checks them again.
  function M.begin()
    return db.transaction(function()
      local s, why = M.state()
      if s ~= 'empty' then fail('internal', 'The copy cannot begin: ' .. tostring(s or why)) end
      set_meta('import', M.VERSION .. ':copying')
      set_meta('import_cursor', '1:')
    end)
  end

  -- copy_step does the next step. It answers true when the copy is done. A prefix step copies
  -- one page; the R step writes meta/cutover to the store and takes its revision R, then sets
  -- meta.rev = R and the done marker in one transaction. A lost store reply or a crash before that
  -- transaction gives a later R at the next try, which is correct: no SQL runtime write happens
  -- before done.
  function M.copy_step()
    local cursor = db.first('SELECT value FROM meta WHERE name = ?', 'import_cursor')
    local n = parse_cursor(cursor and cursor.value)
    if n == R_STEP then
      local stored = A.hub('hub.store.batch', {ops = {{key = 'meta/cutover', value = {version = M.VERSION}}}})
      local r = type(stored.revs) == 'table' and stored.revs['meta/cutover']
      if not A.canonical(r) then fail('internal', 'The store gave no revision for meta/cutover') end
      return db.transaction(function()
        if meta('import') ~= M.VERSION .. ':copying' or meta('import_cursor') ~= R_STEP .. ':' then fail('internal', 'The copy state changed') end
        set_meta('rev', r)
        set_meta('import', M.VERSION .. ':done')
        return true
      end)
    end
    return db.transaction(function()
      if meta('import') ~= M.VERSION .. ':copying' then fail('internal', 'The copy is not running') end
      local step, after = parse_cursor(meta('import_cursor'))
      if not step then fail('internal', 'The copy cursor is not valid') end
      local p = PREFIXES[step]
      local keys, records, more = fetch(p, after ~= '' and after or nil)
      for _, key in ipairs(keys) do p.put(key, records[key]) end
      if more then
        -- The store gives the cursor of the next page; a page can be empty and still have one.
        set_meta('import_cursor', step .. ':' .. tostring(more))
      else
        set_meta('import_cursor', (step + 1) .. ':')
      end
      return false
    end)
  end

  return M
end
