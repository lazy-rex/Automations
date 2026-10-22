-- The SQL storage of Automations (SDK port plan, slice 2: document tables; coordinator decision,
-- 2026-10-22). Each record value of the hub.store layout stays one JSON document. The fields that
-- queries need are extra columns, and only the write functions below set them, from the document,
-- in the same statement. The store keys of today name the rows, so the import copies each record
-- as it is. No production path reads these tables yet; the import runs at start.
-- Load it with dofile(...)(A): A.app (the SDK app), A.scan (the hub.store scan of the plugin), A.hub
-- (the plugin's hub call).
return function(A)
  local db = A.app.db
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
  -- conflict, for example a second run with the same queue entry, fails the step. This module has
  -- import writes only: the runtime writes come with the cutover, with their revision checks.
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

  -- The import (plan, "The one-time import"). Each step copies one page of one store prefix in one
  -- transaction and moves meta.import_cursor in it. The index records (q/, t/, dv/, box/) are not
  -- copied: the run documents carry their fields.
  local IMPORT_PAGE = 50
  local PREFIXES = {
    {prefix = 'meta/', put = function(key, rec)
      if key == 'meta/next_id' then
        copy('meta', {'name', 'value'}, {'next_id', tostring(rec.value.n)})
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
    db.exec('INSERT OR REPLACE INTO meta (name, value) VALUES (?, ?)', name, value)
  end
  function M.imported() return meta('imported') ~= nil end

  -- import_step copies the next page. It answers true when the import is done. The cursor is
  -- "<prefix number>:<last key>" ("1:" before the first page).
  function M.import_step()
    return db.transaction(function()
      if meta('imported') then return true end
      local cursor = meta('import_cursor') or '1:'
      local n, after = cursor:match('^(%d+):(.*)$')
      n = tonumber(n)
      local p = PREFIXES[n]
      local keys, records, more = fetch(p, after ~= '' and after or nil)
      for _, key in ipairs(keys) do p.put(key, records[key]) end
      if more then
        -- The store gives the cursor of the next page; a page can be empty and still have one.
        set_meta('import_cursor', n .. ':' .. tostring(more))
      elseif n < #PREFIXES then
        set_meta('import_cursor', (n + 1) .. ':')
      else
        set_meta('imported', 'store')
        return true
      end
      return false
    end)
  end

  return M
end
