-- The storage of Automations: typed reads and writes of the domain
-- tables, the revision counter, and commit(fn, op), the transaction of one engine step or one
-- operation. Load it with dofile(...)(A): A.app (the SDK app), A.fail.
--
-- Each row keeps its value as one JSON document (a preset row has only its automation ID). A
-- read answers the value and its revision, or nil and '0' when the row does not exist. The runs
-- columns q, t, status and agent come from the run document, in the same statement.
return function(A)
  local db, fail = A.app.db, A.fail
  local encode, decode = rex.json.encode, rex.json.decode
  local M = {}
  -- T is the open commit: its revision counter (a table field: see the Lua rules in
  -- automations.lua).
  local T = {}

  -- --- Revisions ---

  -- One counter, meta.rev, a canonical decimal string. The copy sets it above every revision
  -- that hub.store gave. Each written row takes the next value. Lua never holds it as a number: the
  -- increment is on the text. A commit reads it once and writes it back once, guarded by the
  -- value that it read. At the int64 maximum a write fails; the commit then rolls back, also the
  -- counter.
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
  local function stamp()
    local c = T.counter
    if not c then fail('internal', 'A write outside a commit') end
    if not c.value then
      local row = db.first("SELECT value FROM meta WHERE name = 'rev'")
      local value = row and row.value
      if not M.valid_counter(value) then fail('internal', 'The revision counter is not valid: ' .. tostring(value)) end
      c.start, c.value = value, value
    end
    if not below_max(c.value) then fail('internal', 'The revision counter is at its maximum') end
    c.value = increment(c.value)
    return c.value
  end
  local function save_counter()
    local c = T.counter
    if c.value and c.value ~= c.start then
      local r = db.exec("UPDATE meta SET value = ? WHERE name = 'rev' AND value = ?", c.value, c.start)
      if r.changes ~= 1 then fail('internal', 'The revision counter changed during a commit') end
    end
  end

  -- A conflict: a row that a write checks has another revision. commit rolls back and answers it.
  local function conflict(what, key) error({revision_conflict = true, what = what, key = key}, 0) end

  -- --- Rows with a document (automations, states, seen, retired) ---

  local function doc_get(tbl, col, key)
    local row = db.first('SELECT rev, doc FROM ' .. tbl .. ' WHERE ' .. col .. ' = ?', key)
    if not row then return nil, '0' end
    return decode(row.doc), row.rev
  end
  -- write_row writes cols = vals (the key first). if_rev nil writes in any case; '0' only a new
  -- row; another value only the row at that revision. It answers the new revision.
  local function write_row(what, tbl, cols, vals, if_rev)
    local key = vals[1]
    local r
    if if_rev ~= nil and if_rev ~= '0' then
      -- A value can be nil (runs.q, t, agent), so the counts come from cols, never from #vals.
      local sets, args = {}, {}
      for i = 2, #cols do
        sets[i - 1] = cols[i] .. ' = ?'
        args[i - 1] = vals[i]
      end
      args[#cols], args[#cols + 1] = key, if_rev
      r = db.exec('UPDATE ' .. tbl .. ' SET ' .. table.concat(sets, ', ') .. ' WHERE ' .. cols[1] .. ' = ? AND rev = ?', unpack(args, 1, #cols + 1))
    else
      local marks, sets = {}, {}
      for i, c in ipairs(cols) do
        marks[i] = '?'
        if i > 1 then sets[#sets + 1] = c .. ' = excluded.' .. c end
      end
      -- ON CONFLICT names the key column only: a conflict on another UNIQUE index (runs.q,
      -- runs.t) fails the statement, and never deletes another row as REPLACE would.
      r = db.exec('INSERT INTO ' .. tbl .. ' (' .. table.concat(cols, ', ') .. ') VALUES (' .. table.concat(marks, ', ') .. ') ON CONFLICT ('
        .. cols[1] .. ') ' .. (if_rev == '0' and 'DO NOTHING' or ('DO UPDATE SET ' .. table.concat(sets, ', '))), unpack(vals, 1, #cols))
    end
    if if_rev ~= nil and r.changes ~= 1 then conflict(what, key) end
  end
  -- delete_row deletes the row key. if_rev nil deletes it in any case (a missing row too); '0'
  -- holds only when the row does not exist; another value only for the row at that revision.
  local function delete_row(what, tbl, col, key, if_rev)
    if if_rev == '0' then
      if db.first('SELECT rev FROM ' .. tbl .. ' WHERE ' .. col .. ' = ?', key) then conflict(what, key) end
      return
    end
    if if_rev == nil then
      db.exec('DELETE FROM ' .. tbl .. ' WHERE ' .. col .. ' = ?', key)
      return
    end
    if db.exec('DELETE FROM ' .. tbl .. ' WHERE ' .. col .. ' = ? AND rev = ?', key, if_rev).changes ~= 1 then conflict(what, key) end
  end
  local function doc_put(what, tbl, col, key, if_rev, value)
    local rev = stamp()
    write_row(what, tbl, {col, 'rev', 'doc'}, {key, rev, encode(value)}, if_rev)
    return rev
  end
  -- A page of doc rows in key order after the key after, where cond holds: at most limit rows
  -- {key, rev, value}, and whether more follow (also when one reply did not hold them).
  local function doc_page(tbl, col, cond, args, after, limit)
    local values = {}
    for i, v in ipairs(args) do values[i] = v end
    values[#values + 1] = after or ''
    values[#values + 1] = limit + 1
    local rows, partial = db.query('SELECT ' .. col .. ' AS key, rev, doc FROM ' .. tbl .. ' WHERE ' .. cond .. ' AND ' .. col .. ' > ? ORDER BY '
      .. col .. ' LIMIT ?', unpack(values, 1, #values))
    local out = {}
    for i = 1, math.min(#rows, limit) do out[i] = {key = rows[i].key, rev = rows[i].rev, value = decode(rows[i].doc)} end
    return out, #rows > limit or partial == true
  end
  local function prefix_cond(col, prefix) return 'substr(' .. col .. ', 1, ?) = ?', {#prefix, prefix} end

  -- Automations: automations.id.
  function M.auto(id) return doc_get('automations', 'id', id) end
  function M.put_auto(id, if_rev, auto) return doc_put('automation ' .. id, 'automations', 'id', id, if_rev, auto) end
  function M.delete_auto(id, if_rev) delete_row('automation ' .. id, 'automations', 'id', id, if_rev) end
  -- autos is a page of automations in ID text order (the order of today's auto/ keys).
  function M.autos(after, limit) return doc_page('automations', 'id', '1 = 1', {}, after, limit) end

  -- States: states.id, the engine's fence for one automation.
  function M.state(id) return doc_get('states', 'id', id) end
  function M.put_state(id, if_rev, st) return doc_put('state ' .. id, 'states', 'id', id, if_rev, st) end
  function M.delete_state(id, if_rev) delete_row('state ' .. id, 'states', 'id', id, if_rev) end

  -- Markers: seen.key = seen/<id>/<appearance key> = {run}; retired.key = rt/<id>/<appearance key> = {seq}.
  function M.marker(key) return doc_get('seen', 'key', key) end
  function M.put_marker(key, if_rev, value) return doc_put('marker ' .. key, 'seen', 'key', key, if_rev, value) end
  function M.delete_marker(key) delete_row('marker ' .. key, 'seen', 'key', key, nil) end
  function M.markers(prefix, after, limit) local c, a = prefix_cond('key', prefix) return doc_page('seen', 'key', c, a, after, limit) end
  function M.put_retired(key, value) return doc_put('retired ' .. key, 'retired', 'key', key, nil, value) end
  function M.delete_retired(key) delete_row('retired ' .. key, 'retired', 'key', key, nil) end
  function M.retired(prefix, after, limit) local c, a = prefix_cond('key', prefix) return doc_page('retired', 'key', c, a, after, limit) end

  -- Runs: runs.run_key = run/<id>/<kind>/<k>.
  function M.run(run_key) return doc_get('runs', 'run_key', run_key) end
  local function text(v) if v == nil then return nil end return tostring(v) end
  function M.put_run(run_key, if_rev, run)
    local id = run_key:match('^run/([^/]+)/')
    if not id then fail('internal', 'A run key without an automation: ' .. run_key) end
    local rev = stamp()
    write_row('run ' .. run_key, 'runs', {'run_key', 'automation_id', 'rev', 'status', 'q', 't', 'agent', 'doc'},
      {run_key, id, rev, tostring(run.status), text(run.q), text(run.t), text(run.agent), encode(run)}, if_rev)
    return rev
  end
  function M.delete_run(run_key, if_rev) delete_row('run ' .. run_key, 'runs', 'run_key', run_key, if_rev) end
  -- run_page is a page of runs (records {key, rev, value}) where cond holds, in the order order.
  function M.run_page(cond, args, limit)
    local values = {}
    for i, v in ipairs(args) do values[i] = v end
    values[#values + 1] = limit + 1
    local rows, partial = db.query('SELECT run_key, rev, doc FROM runs WHERE ' .. cond .. ' LIMIT ?', unpack(values, 1, #values))
    local out = {}
    for i = 1, math.min(#rows, limit) do out[i] = {key = rows[i].run_key, rev = rows[i].rev, value = decode(rows[i].doc)} end
    return out, #rows > limit or partial == true
  end

  -- Presets: presets.name = the automation that installed it.
  function M.preset(name)
    local row = db.first('SELECT rev, automation_id FROM presets WHERE name = ?', name)
    if not row then return nil, '0' end
    return row.automation_id, row.rev
  end
  function M.put_preset(name, if_rev, id)
    local rev = stamp()
    write_row('preset ' .. name, 'presets', {'name', 'rev', 'automation_id'}, {name, rev, tostring(id)}, if_rev)
    return rev
  end
  function M.delete_preset(name, if_rev) delete_row('preset ' .. name, 'presets', 'name', name, if_rev) end

  -- The next automation ID: meta.next_id (the last used ID) and its revision meta.next_id_rev.
  function M.next_id()
    local n, r = db.first("SELECT value FROM meta WHERE name = 'next_id'"), db.first("SELECT value FROM meta WHERE name = 'next_id_rev'")
    if not n then return 0, '0' end
    return tonumber(n.value), r and r.value or '0'
  end
  function M.put_next_id(n, if_rev)
    local _, rev = M.next_id()
    if rev ~= if_rev then conflict('next id', 'meta/next_id') end
    local new = stamp()
    db.exec("INSERT INTO meta (name, value) VALUES ('next_id', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value", tostring(n))
    db.exec("INSERT INTO meta (name, value) VALUES ('next_id_rev', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value", new)
  end

  -- --- Operations ---

  -- op(key) answers the saved reply of an operation key and its fingerprint, or nil.
  function M.op(key)
    local row = db.first('SELECT fingerprint, reply FROM ops WHERE key = ?', key)
    if not row then return nil end
    return {fingerprint = row.fingerprint, reply = decode(row.reply)}
  end

  -- commit runs fn in one transaction, with its writes, its notices (app.notice) and the saved
  -- reply. It answers {reply = <value of fn>}; or nil and the conflict after a revision conflict
  -- (nothing is written, the counter neither; the caller reads again). With op = {key,
  -- fingerprint}: a saved op with the same fingerprint answers {replayed = <its reply>}, and
  -- another fingerprint fails conflict (not a revision conflict: a retry cannot pass). Else the
  -- reply of fn is saved as op.key in the same transaction.
  function M.commit(fn, op)
    if T.counter then fail('internal', 'A commit inside a commit') end
    T.counter = {}
    local ok, out = pcall(db.transaction, function()
      if op then
        local saved = M.op(op.key)
        if saved then
          if (saved.fingerprint or '') ~= (op.fingerprint or '') then fail('conflict', 'The operation key was used for other content') end
          return {replayed = saved.reply}
        end
      end
      local reply = fn()
      if op then db.exec('INSERT INTO ops (key, fingerprint, reply) VALUES (?, ?, ?)', op.key, op.fingerprint, encode(reply == nil and {} or reply)) end
      save_counter()
      return {reply = reply}
    end)
    T.counter = nil
    if ok then return out end
    if type(out) == 'table' and out.revision_conflict then return nil, out end
    if type(out) == 'table' and out.abort then return nil, out.abort end
    error(out, 0)
  end

  -- abort(reason) ends the open commit with no write: commit answers nil and reason.
  function M.abort(reason) error({abort = reason}, 0) end

  -- atomic is commit for an operation that reads its rows in fn. The plugin has one open
  -- transaction at a time (hub docs/sql.md, section 4), so no other commit can change the rows
  -- between the read and the write, and a revision conflict is a defect. It answers the commit,
  -- or nil and the reason of abort.
  function M.atomic(fn, op)
    local done, why = M.commit(fn, op)
    if not done and type(why) == 'table' then fail('internal', 'A revision conflict in one transaction: ' .. tostring(why.what) .. ' ' .. tostring(why.key)) end
    return done, why
  end

  return M
end
