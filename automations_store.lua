-- The bridge (SDK port plan, "The cutover", point 4): the hub.store interface that the engine
-- uses (get, scan, batch with if_rev, the op records) on the SQL tables. It is a temporary
-- adapter: it gets no new callers, and slice 3 deletes it in the steps of "The bridge inventory".
-- Load it with dofile(...)(A): A.app (the SDK app), A.fail.
--
-- Record keys: auto/<id>, state/<id>, run/<id>/..., preset/<name>, seen/..., rt/... and
-- meta/next_id name a row. The index keys q/, t/, dv/ and box/ have no row: a run gives them
-- (its q or t column, or a delivered status with its agent), and their rev is the run's rev.
return function(A)
  local db, fail = A.app.db, A.fail
  local encode, decode = rex.json.encode, rex.json.decode
  local M = {}

  -- --- Revisions ---

  -- One counter, meta.rev, a canonical decimal string. The copy sets it to R, the store's own
  -- revision of meta/cutover, so it is above every revision that the store gave. Each written row
  -- takes the next value. Lua never holds it as a number.
  local MAX_REV = '9223372036854775807'
  function M.canonical(r) return type(r) == 'string' and (r == '0' or r:match('^[1-9]%d*$') ~= nil) end
  local function below_max(r) return #r < #MAX_REV or (#r == #MAX_REV and r < MAX_REV) end
  function M.valid_counter(r) return M.canonical(r) and (below_max(r) or r == MAX_REV) end
  local function increment(r)
    local i = #r
    while i > 0 and r:sub(i, i) == '9' do i = i - 1 end
    if i == 0 then return '1' .. string.rep('0', #r) end
    return r:sub(1, i - 1) .. string.char(r:byte(i) + 1) .. string.rep('0', #r - i)
  end
  M.increment = increment
  -- counter reads meta.rev once for a batch. next() refuses at the int64 maximum, before any
  -- value above it exists; the batch then fails and its transaction rolls back.
  local function counter()
    local row = db.first("SELECT value FROM meta WHERE name = 'rev'")
    local value = row and row.value
    if not M.valid_counter(value) then fail('internal', 'The revision counter is not valid: ' .. tostring(value)) end
    local c = {value = value, start = value}
    function c.next()
      if not below_max(c.value) then fail('internal', 'The revision counter is at its maximum') end
      c.value = increment(c.value)
      return c.value
    end
    function c.save()
      if c.value ~= c.start then db.exec("UPDATE meta SET value = ? WHERE name = 'rev'", c.value) end
    end
    return c
  end

  -- --- Record keys ---

  -- A stored record: its table, its key column, and the part of the record key in that column.
  local TABLES = {
    {prefix = 'auto/', tbl = 'automations', col = 'id', strip = true},
    {prefix = 'state/', tbl = 'states', col = 'id', strip = true},
    {prefix = 'run/', tbl = 'runs', col = 'run_key'},
    {prefix = 'preset/', tbl = 'presets', col = 'name', strip = true},
    {prefix = 'seen/', tbl = 'seen', col = 'key'},
    {prefix = 'rt/', tbl = 'retired', col = 'key'},
  }
  local function table_of(key)
    for _, t in ipairs(TABLES) do
      if key:sub(1, #t.prefix) == t.prefix then return t, t.strip and key:sub(#t.prefix + 1) or key end
    end
  end
  local function index_of(key) local kind = key:match('^(%a+)/') if kind == 'q' or kind == 't' or kind == 'dv' or kind == 'box' then return kind end end

  local function doc_of(t, row)
    if t.tbl == 'presets' then return {id = row.automation_id} end
    return decode(row.doc)
  end
  local function columns(t) return t.tbl == 'presets' and 'name, rev, automation_id' or (t.col .. ', rev, doc') end

  -- The run that gives an index key, as the tables are now (inside the batch: after its writes).
  -- INDEX_COLS are the columns of an index record: never the document, so a page of index
  -- records stays small, as the store's index records were (a run document is up to 12 KiB, and
  -- one hub.sql reply holds about 1 MB: 100 runs with full documents can need two replies, and a
  -- short page then stops the prune). RUN_COLS add the document, for the run that gives one key.
  local INDEX_COLS = "run_key, automation_id, rev, status, q, t, agent, json_extract(doc, '$.tseq') AS tseq, "
    .. "json_extract(doc, '$.attempt') AS attempt"
  local RUN_COLS = INDEX_COLS .. ', doc'
  local function giver(key)
    local kind = index_of(key)
    if kind == 'q' then return db.first('SELECT ' .. RUN_COLS .. ' FROM runs WHERE q = ?', key) end
    if kind == 't' then return db.first('SELECT ' .. RUN_COLS .. ' FROM runs WHERE t = ?', key) end
    if kind == 'dv' then
      local id, run_key = key:match('^dv/([^/]+)/(run/.+)$')
      if not id then return nil end
      return db.first('SELECT ' .. RUN_COLS .. " FROM runs WHERE run_key = ? AND automation_id = ? AND status = 'delivered'", run_key, id)
    end
    local agent, run_key = key:match('^box/([^/]+)/(run/.+)$')
    if not agent then return nil end
    return db.first('SELECT ' .. RUN_COLS .. " FROM runs WHERE run_key = ? AND agent = ? AND status = 'delivered'", run_key, agent)
  end
  -- The value of an index record, from the run that gives it (the values of today's records).
  local function index_value(kind, row)
    if kind == 'q' then return {run = row.run_key} end
    if kind == 't' then return {run = row.run_key, seq = tonumber(row.tseq)} end
    if kind == 'dv' then return {agent = row.agent} end
    return {attempt = tonumber(row.attempt), auto = row.automation_id}
  end

  local function same(a, b)
    if type(a) ~= type(b) then return false end
    if type(a) ~= 'table' then return a == b end
    for k, v in pairs(a) do if not same(v, b[k]) then return false end end
    for k in pairs(b) do if a[k] == nil then return false end end
    return true
  end

  -- record answers {rev, value} for a key, or {rev = '0'} when it does not exist.
  local function record(key)
    if key == 'meta/next_id' then
      local n, r = db.first("SELECT value FROM meta WHERE name = 'next_id'"), db.first("SELECT value FROM meta WHERE name = 'next_id_rev'")
      if not n then return {rev = '0'} end
      return {rev = r and r.value or '0', value = {n = tonumber(n.value)}}
    end
    local kind = index_of(key)
    if kind then
      local row = giver(key)
      if not row then return {rev = '0'} end
      return {rev = row.rev, value = index_value(kind, row)}
    end
    local t, k = table_of(key)
    if not t then fail('internal', 'The bridge has no table for the key ' .. key) end
    local row = db.first('SELECT ' .. columns(t) .. ' FROM ' .. t.tbl .. ' WHERE ' .. t.col .. ' = ?', k)
    if not row then return {rev = '0'} end
    return {rev = row.rev, value = doc_of(t, row)}
  end

  local function text(v) if v == nil then return nil end return tostring(v) end
  local function write(key, rev, value)
    if key == 'meta/next_id' then
      db.exec("INSERT INTO meta (name, value) VALUES ('next_id', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value", tostring(value.n))
      db.exec("INSERT INTO meta (name, value) VALUES ('next_id_rev', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value", rev)
      return
    end
    local t, k = table_of(key)
    if not t or index_of(key) then fail('internal', 'The bridge has no table for the key ' .. key) end
    -- ON CONFLICT names the key column only: a conflict on another UNIQUE index (runs.q, runs.t)
    -- fails the batch, and never deletes another row as REPLACE would.
    if t.tbl == 'runs' then
      local id = key:match('^run/([^/]+)/')
      if not id then fail('internal', 'A run key without an automation: ' .. key) end
      db.exec('INSERT INTO runs (run_key, automation_id, rev, status, q, t, agent, doc) VALUES (?, ?, ?, ?, ?, ?, ?, ?) '
        .. 'ON CONFLICT (run_key) DO UPDATE SET rev = excluded.rev, status = excluded.status, q = excluded.q, t = excluded.t, '
        .. 'agent = excluded.agent, doc = excluded.doc',
        key, id, rev, tostring(value.status), text(value.q), text(value.t), text(value.agent), encode(value))
    elseif t.tbl == 'presets' then
      db.exec('INSERT INTO presets (name, rev, automation_id) VALUES (?, ?, ?) ON CONFLICT (name) DO UPDATE SET rev = excluded.rev, '
        .. 'automation_id = excluded.automation_id', k, rev, tostring(value.id))
    else
      db.exec('INSERT INTO ' .. t.tbl .. ' (' .. t.col .. ', rev, doc) VALUES (?, ?, ?) ON CONFLICT (' .. t.col .. ') '
        .. 'DO UPDATE SET rev = excluded.rev, doc = excluded.doc', k, rev, encode(value))
    end
  end
  local function remove(key)
    if key == 'meta/next_id' then fail('internal', 'The bridge never deletes meta/next_id') end
    local t, k = table_of(key)
    if not t then fail('internal', 'The bridge has no table for the key ' .. key) end
    db.exec('DELETE FROM ' .. t.tbl .. ' WHERE ' .. t.col .. ' = ?', k)
  end

  -- --- The interface ---

  -- get(keys) answers {key = {rev, value}}, as hub.store.get.
  function M.get(keys)
    local out = {}
    for _, key in ipairs(keys) do out[key] = record(key) end
    return out
  end

  -- scan(prefix, after, limit) answers {records, next}, as hub.store.scan: records after the key
  -- after, in key order, and next (the last key) when more exist.
  local function page(rows, limit, more, key_of, rec_of)
    local records, last = {}, nil
    for i, row in ipairs(rows) do
      if i > limit then more = true break end
      last = key_of(row)
      records[last] = rec_of(row)
    end
    return {records = records, next = more and last or nil}
  end
  function M.scan(prefix, after, limit)
    limit = limit or 100
    after = after or ''
    local n = limit + 1
    local kind = index_of(prefix)
    if kind == 'q' or kind == 't' then
      local col = kind
      local rows, more = db.query('SELECT ' .. INDEX_COLS .. ' FROM runs WHERE ' .. col .. ' > ? AND substr(' .. col .. ', 1, ?) = ? ORDER BY '
        .. col .. ' LIMIT ?', after, #prefix, prefix, n)
      return page(rows, limit, more, function(row) return row[col] end, function(row) return {rev = row.rev, value = index_value(kind, row)} end)
    end
    if kind == 'dv' then
      local id = prefix:match('^dv/([^/]+)/$')
      if not id then fail('internal', 'The bridge scans dv/<id>/ only, not ' .. prefix) end
      local from = after:sub(1, #prefix) == prefix and after:sub(#prefix + 1) or ''
      local rows, more = db.query('SELECT ' .. INDEX_COLS .. " FROM runs WHERE automation_id = ? AND status = 'delivered' AND run_key > ? ORDER BY run_key LIMIT ?",
        id, from, n)
      return page(rows, limit, more, function(row) return prefix .. row.run_key end, function(row) return {rev = row.rev, value = index_value(kind, row)} end)
    end
    if kind == 'box' then
      local agent = prefix:match('^box/([^/]+)/$')
      if not agent then fail('internal', 'The bridge scans box/<agent>/ only, not ' .. prefix) end
      local from = after:sub(1, #prefix) == prefix and after:sub(#prefix + 1) or ''
      local rows, more = db.query('SELECT ' .. INDEX_COLS .. " FROM runs WHERE agent = ? AND status = 'delivered' AND run_key > ? ORDER BY run_key LIMIT ?",
        agent, from, n)
      return page(rows, limit, more, function(row) return prefix .. row.run_key end, function(row) return {rev = row.rev, value = index_value(kind, row)} end)
    end
    local t = table_of(prefix)
    if not t then fail('internal', 'The bridge has no table for the prefix ' .. prefix) end
    local p = t.strip and prefix:sub(#t.prefix + 1) or prefix
    local from = after
    if t.strip then from = after:sub(1, #t.prefix) == t.prefix and after:sub(#t.prefix + 1) or '' end
    local rows, more = db.query('SELECT ' .. columns(t) .. ' FROM ' .. t.tbl .. ' WHERE ' .. t.col .. ' > ? AND substr(' .. t.col .. ', 1, ?) = ? ORDER BY '
      .. t.col .. ' LIMIT ?', from, #p, p, n)
    return page(rows, limit, more, function(row) return t.strip and (t.prefix .. row[t.col]) or row[t.col] end,
      function(row) return {rev = row.rev, value = doc_of(t, row)} end)
  end

  -- op(key) answers {found, fingerprint, result}, as hub.store.op.
  function M.op(key)
    local row = db.first('SELECT fingerprint, reply FROM ops WHERE key = ?', key)
    if not row then return {found = false} end
    return {found = true, fingerprint = row.fingerprint, result = decode(row.reply)}
  end

  -- batch(request) applies {ops, op} in one transaction and answers as hub.store.batch: {revs},
  -- {conflict = {kind, key, rev?}} or {op_exists = {fingerprint, result}}. The checks come before
  -- any write, as in the store: a saved op first, then each if_rev against the tables before the
  -- batch. An index write must match the run that the batch leaves; else the batch fails.
  function M.batch(request)
    return db.transaction(function()
      local op = request.op
      if op and op.key then
        local saved = M.op(op.key)
        if saved.found then
          if (saved.fingerprint or '') == (op.fingerprint or '') then return {op_exists = {fingerprint = saved.fingerprint, result = saved.result}} end
          return {conflict = {kind = 'operation', key = op.key}}
        end
      end
      for _, o in ipairs(request.ops or {}) do
        if o.key and o.if_rev ~= nil then
          local cur = record(o.key).rev
          if cur ~= o.if_rev then return {conflict = {kind = 'revision', key = o.key, rev = cur}} end
        end
      end
      local c = counter()
      local revs, indexes = {}, {}
      for _, o in ipairs(request.ops or {}) do
        if o.notify then
          A.app.notice(o.notify.agent, o.notify.pending)
        elseif index_of(o.key) then
          indexes[#indexes + 1] = o
        elseif o.delete then
          remove(o.key)
          revs[o.key] = '0'
        else
          local rev = c.next()
          write(o.key, rev, o.value)
          revs[o.key] = rev
        end
      end
      for _, o in ipairs(indexes) do
        local row = giver(o.key)
        local kind = index_of(o.key)
        if o.delete then
          if row and (kind == 'q' or kind == 't') then
            -- In the store, the entry goes and the run stays: the run is then not in the queue or
            -- the terminal order (the purge deletes the t/ entries before the runs). Here the
            -- entry is the run's column, so the delete clears it and its document field.
            local run = decode(row.doc)
            run[kind] = nil
            write(row.run_key, c.next(), run)
          elseif row then
            fail('internal', 'The bridge: ' .. o.key .. ' is deleted, but run ' .. row.run_key .. ' still gives it')
          end
          revs[o.key] = '0'
        else
          if not row or not same(index_value(kind, row), o.value) then
            fail('internal', 'The bridge: no run of this batch gives ' .. o.key .. ' with its value')
          end
          revs[o.key] = row.rev
        end
      end
      if op and op.key then
        local result = op.result == nil and {} or op.result
        if type(op.result_revs) == 'table' then
          local filled = {}
          for k, v in pairs(result) do filled[k] = v end
          for field, key in pairs(op.result_revs) do filled[field] = revs[key] end
          result = filled
        end
        db.exec('INSERT INTO ops (key, fingerprint, reply) VALUES (?, ?, ?)', op.key, op.fingerprint, encode(result))
      end
      c.save()
      return {revs = revs}
    end)
  end

  return M
end
