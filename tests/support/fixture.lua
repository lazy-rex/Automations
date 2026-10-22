-- The shared lab fixture: the test clock, an agent profile whose worker is a real test agent, and
-- calls as that worker. Load it with loadfile(...)(H).
return function(H)
  local F = {}

  -- The plugin reads LAB/clock (manifest test.args clock_file) at each 1 s tick.
  function F.set_clock(t)
    local f = assert(io.open(H.args.lab .. '/clock', 'w'))
    f:write(tostring(t))
    f:close()
  end
  function F.at(y, m, d, hh, mm) return os.time({year = y, month = m, day = d, hour = hh, min = mm, sec = 0}) end

  -- The worker profile starts lazyrex-hub testagent in the spawned pane. It joins as the spawn's
  -- agent ID (LAZYREX_AGENT, set by the hub), and its client label names that ID, so a test can
  -- call as the worker. Profile commands are trusted test code (docs/testing.md, "Isolation").
  -- profile_list is the base list; a test can add profiles to it and write it.
  function F.profile_list()
    return {
      {id = 'worker', name = 'Worker', kind = 'agent', command = {'/bin/sh', '-c',
        'exec "$0" testagent -id "$LAZYREX_AGENT" -join "$LAZYREX_AGENT"', H.args.hub_bin}},
      {id = 'tasked', name = 'Tasked', kind = 'agent', args = {{name = 'task', label = 'Task', required = true}},
        command = {'/bin/sh', '-c', 'exec "$0" testagent -id "$LAZYREX_AGENT" -join "$LAZYREX_AGENT"', H.args.hub_bin, '${task}'}},
      {id = 'logtail', name = 'Log tail', kind = 'accessory', command = {'/bin/sh', '-c', 'exec tail -f /dev/null'}},
    }
  end
  function F.profiles() H.write_profiles({profiles = F.profile_list()}) end

  function F.workers(profile)
    local out = {}
    for _, w in ipairs(H.hub('hub.workers', {}).workers) do
      if not profile or w.profile == profile then out[#out + 1] = w end
    end
    return out
  end

  -- running counts the rows in state running: hub.workers also lists failed spawns.
  function F.running(profile)
    local n = 0
    for _, w in ipairs(F.workers(profile)) do if w.state == 'running' then n = n + 1 end end
    return n
  end

  -- worker returns a caller for the test agent in a spawned pane: call goes through the agent
  -- face (the MCP path), as an agent's tool call.
  function F.worker(agent_id)
    local client = H.wait('the worker ' .. agent_id .. ' to start', function() return H.resolve('lazyrex-testagent:' .. agent_id) end, 20)
    H.wait('the worker ' .. agent_id .. ' to join', function()
      local s = H.perform(client, 'agent.status', {})
      return s.joined
    end, 20)
    return {id = agent_id,
      call = function(_, action, args) return H.perform(client, 'agent.call', {action = action, args = args or {}}) end,
      -- report sends hub.identity.report from a new process in the worker's pane, as an agent hook.
      report = function(_, kind, conversation_id)
        return H.perform(client, 'agent.report', {args = {kind = kind, conversation_id = conversation_id, source = 'startup'}}, 20000)
      end}
  end

  -- Files: the manifest grants LAB/inbox (test.watch_roots). dir makes a directory under it.
  function F.dir(name)
    local d = H.args.lab .. '/inbox/' .. name
    local r, err = rex.exec({'mkdir', '-p', d})
    assert(r and r.ok, 'mkdir failed: ' .. tostring(err or (r and r.stderr)))
    return d
  end
  function F.put(path, text)
    local f = assert(io.open(path, 'w'))
    f:write(text or 'note')
    f:close()
  end
  function F.remove(path) assert(os.remove(path)) end

  function F.view(caller, id)
    for _, a in ipairs(caller:call('automations.list', {}).automations) do
      if a.id == id then return a end
    end
  end
  -- watching waits until the automation's current watch is active: files that exist before
  -- that are the baseline and make no run.
  function F.watching(caller, id)
    return H.wait('the watch of automation ' .. id .. ' to be active', function()
      local a = F.view(caller, id)
      return a and a.watch and a.watch.state == 'active' and a
    end, 20)
  end

  -- runs lists every run of an automation (automations.runs, all pages).
  function F.runs(caller, id, kind)
    local out, after = {}, nil
    repeat
      local page = caller:call('automations.runs', {id = id, after = after, limit = 50})
      for _, r in ipairs(page.runs) do
        if not kind or r.kind == kind then out[#out + 1] = r end
      end
      after = page.next
    until not after
    return out
  end
  function F.wait_runs(caller, id, n, timeout)
    return H.wait(n .. ' file runs of automation ' .. id, function()
      local runs = F.runs(caller, id, 'f')
      return #runs >= n and runs
    end, timeout or 20)
  end

  -- --- Views: the panel and the forms, through the hub's view path (H.user) ---

  function F.items(tree, id)
    local n = H.node(tree, id)
    return n and n.items or {}
  end
  function F.item(tree, list, id)
    for _, item in ipairs(F.items(tree, list)) do if item.id == id then return item end end
  end
  -- field returns a form field of a tree.
  function F.field(tree, form, id)
    local n = H.node(tree, form)
    for _, f in ipairs(n and n.fields or {}) do if f.id == id then return f end end
  end
  -- ok checks that a view operation succeeded and that its effects ran; it returns the result.
  function F.ok(op)
    if op.status ~= 'succeeded' or op.effects == 'failed' then error('the view action failed: ' .. rex.json.encode(op), 2) end
    return op.result or {}
  end
  -- view opens the view of a route that an effect opened, and renders it once (a render sets the
  -- revision that an action sends).
  function F.view_of(route)
    local v = H.user:view(route)
    return v, v:render()
  end
  function F.panel()
    H.user:command('automations')
    return F.view_of('/panels/automations')
  end
  -- open opens the view of one automation from the panel. It follows the panel pages until the
  -- panel lists the automation.
  function F.open(id)
    local p, tree = F.panel()
    for _ = 1, 20 do
      if F.item(tree, 'automations', id) then
        return F.view_of(F.ok(p:action('automations', 'open', {item_id = id})).form)
      end
      if not H.node(tree, 'next_page') then error('the panel does not list automation ' .. id, 2) end
      p, tree = F.view_of(F.ok(p:action('next_page', 'next')).panel.route)
    end
    error('the panel has too many pages', 2)
  end
  -- size is the encoded size of a tree.
  function F.size(tree) return #rex.json.encode(tree) end

  -- The plugin's records in the layout of hub.store keys, on its SQL tables (the layout
  -- of the slice 1 version). F.store(key) reads a record as the harness store(key) did: {rev,
  -- value}, rev '0' when absent. F.write(ops) writes records as the harness write(ops) did, with
  -- if_rev and a new revision from meta.rev for each written row. It is for fixtures: each
  -- statement is its own transaction. An index key (q/, t/, dv/, box/) has no row: F.write checks
  -- that a run gives it after the other ops, and writes nothing for it.
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
    error('no table for the key ' .. key, 3)
  end
  local function index_of(key) local k = key:match('^(%a+)/') if k == 'q' or k == 't' or k == 'dv' or k == 'box' then return k end end
  local RUN_COLS = 'run_key, automation_id, rev, status, q, t, agent, doc'
  local function giver(key)
    local kind = index_of(key)
    if kind == 'q' or kind == 't' then return H.sql('SELECT ' .. RUN_COLS .. ' FROM runs WHERE ' .. kind .. ' = ?', {key})[1] end
    if kind == 'dv' then
      local id, run_key = key:match('^dv/([^/]+)/(run/.+)$')
      return H.sql('SELECT ' .. RUN_COLS .. " FROM runs WHERE run_key = ? AND automation_id = ? AND status = 'delivered'", {run_key, id})[1]
    end
    local agent, run_key = key:match('^box/([^/]+)/(run/.+)$')
    return H.sql('SELECT ' .. RUN_COLS .. " FROM runs WHERE run_key = ? AND agent = ? AND status = 'delivered'", {run_key, agent})[1]
  end
  function F.store(key)
    if key == 'meta/next_id' then
      local n, r = H.sql("SELECT value FROM meta WHERE name = 'next_id'")[1], H.sql("SELECT value FROM meta WHERE name = 'next_id_rev'")[1]
      if not n then return {rev = '0'} end
      return {rev = r and r.value or '0', value = {n = tonumber(n.value)}}
    end
    local kind = index_of(key)
    if kind then
      local row = giver(key)
      if not row then return {rev = '0'} end
      local run = rex.json.decode(row.doc)
      local value = ({q = {run = row.run_key}, t = {run = row.run_key, seq = run.tseq}, dv = {agent = row.agent},
        box = {attempt = run.attempt, auto = row.automation_id}})[kind]
      return {rev = row.rev, value = value}
    end
    local t, k = table_of(key)
    local cols = t.tbl == 'presets' and 'rev, automation_id' or 'rev, doc'
    local row = H.sql('SELECT ' .. cols .. ' FROM ' .. t.tbl .. ' WHERE ' .. t.col .. ' = ?', {k})[1]
    if not row then return {rev = '0'} end
    return {rev = row.rev, value = t.tbl == 'presets' and {id = row.automation_id} or rex.json.decode(row.doc)}
  end
  -- sql_write tries again while the plugin has an open transaction (busy).
  local function sql_write(sql, params)
    for _ = 1, 100 do
      local ok, r = pcall(H.sql_write, sql, params)
      if ok then return r end
      if not tostring(type(r) == 'table' and r.code or r):find('busy') then error(r, 0) end
      rex.sleep(0.05)
    end
    error('the SQL database stays busy', 2)
  end
  local function increment(r)
    local i = #r
    while i > 0 and r:sub(i, i) == '9' do i = i - 1 end
    if i == 0 then return '1' .. string.rep('0', #r) end
    return r:sub(1, i - 1) .. string.char(r:byte(i) + 1) .. string.rep('0', #r - i)
  end
  -- reserve takes the next n values of meta.rev with one compare and set, so a plugin commit
  -- between the read and the write never gives one revision twice.
  local function reserve(n)
    if n == 0 then return {} end
    for _ = 1, 100 do
      local cur = H.sql("SELECT value FROM meta WHERE name = 'rev'")[1].value
      local list, v = {}, cur
      for i = 1, n do v = increment(v); list[i] = v end
      if sql_write("UPDATE meta SET value = ? WHERE name = 'rev' AND value = ?", {v, cur}).changes == 1 then return list end
    end
    error('meta.rev changes too often', 2)
  end
  local function null(v) if v == nil then return {null = true} end return tostring(v) end
  -- statements turns one record op into SQL statements {sql, params}. rev is the new revision: a
  -- value, or {expr = <SQL expression>} for statements that take it from meta.rev when they run.
  local function statements(o, rev)
    local r, rp = '?', rev
    if type(rev) == 'table' then r, rp = rev.expr, nil end
    local function with(list, ...)
      local out = {}
      for _, v in ipairs(list) do
        if v == '<rev>' then if rp ~= nil then out[#out + 1] = rp end else out[#out + 1] = v end
      end
      return out
    end
    if o.key == 'meta/next_id' then
      return {{"INSERT INTO meta (name, value) VALUES ('next_id', ?) ON CONFLICT (name) DO UPDATE SET value = excluded.value", {tostring(o.value.n)}},
        {"INSERT INTO meta (name, value) VALUES ('next_id_rev', " .. r .. ") ON CONFLICT (name) DO UPDATE SET value = excluded.value", with({'<rev>'})}}
    end
    local t, k = table_of(o.key)
    if o.delete then return {{'DELETE FROM ' .. t.tbl .. ' WHERE ' .. t.col .. ' = ?', {k}}} end
    if t.tbl == 'runs' then
      local v = o.value
      return {{'INSERT INTO runs (run_key, automation_id, rev, status, q, t, agent, doc) VALUES (?, ?, ' .. r .. ', ?, ?, ?, ?, ?) '
        .. 'ON CONFLICT (run_key) DO UPDATE SET rev = excluded.rev, status = excluded.status, q = excluded.q, t = excluded.t, '
        .. 'agent = excluded.agent, doc = excluded.doc',
        with({k, k:match('^run/([^/]+)/'), '<rev>', tostring(v.status), null(v.q), null(v.t), null(v.agent), rex.json.encode(v)})}}
    end
    if t.tbl == 'presets' then
      return {{'INSERT INTO presets (name, rev, automation_id) VALUES (?, ' .. r .. ', ?) ON CONFLICT (name) DO UPDATE SET rev = excluded.rev, '
        .. 'automation_id = excluded.automation_id', with({k, '<rev>', tostring(o.value.id)})}}
    end
    return {{'INSERT INTO ' .. t.tbl .. ' (' .. t.col .. ', rev, doc) VALUES (?, ' .. r .. ', ?) ON CONFLICT (' .. t.col .. ') '
      .. 'DO UPDATE SET rev = excluded.rev, doc = excluded.doc', with({k, '<rev>', rex.json.encode(o.value)})}}
  end
  function F.write(ops)
    for _, o in ipairs(ops) do
      if o.if_rev ~= nil then
        local cur = F.store(o.key).rev
        if cur ~= o.if_rev then error({code = 'conflict', message = 'record ' .. o.key .. ' is at rev ' .. cur}, 2) end
      end
    end
    -- The statements of one table merge into one statement (many VALUES rows, or IN for deletes),
    -- in the order that the ops name the tables. So the plugin never sees a half-written table, as
    -- the harness store write was one batch.
    local indexes, n = {}, 0
    for _, o in ipairs(ops) do
      if index_of(o.key) then indexes[#indexes + 1] = o elseif not o.delete then n = n + 1 end
    end
    local revs, r = reserve(n), 0
    local groups, order = {}, {}
    for _, o in ipairs(ops) do
      if not index_of(o.key) then
        local rev
        if not o.delete then r = r + 1; rev = revs[r] end
        for _, st in ipairs(statements(o, rev)) do
          local g = groups[st[1]]
          if not g then g = {sql = st[1], rows = {}}; groups[st[1]] = g; order[#order + 1] = g end
          g.rows[#g.rows + 1] = st[2]
        end
      end
    end
    for _, g in ipairs(order) do
      local head, tuple, tail = g.sql:match('^(.- VALUES )(%b())(.*)$')
      local del = g.sql:match('^(DELETE FROM .- WHERE [%w_]+) = %?$')
      local sql, params = g.sql, {}
      if #g.rows > 1 and head then
        local tuples = {}
        for i = 1, #g.rows do tuples[i] = tuple end
        sql = head .. table.concat(tuples, ', ') .. tail
      elseif #g.rows > 1 and del then
        local marks = {}
        for i = 1, #g.rows do marks[i] = '?' end
        sql = del .. ' IN (' .. table.concat(marks, ', ') .. ')'
      elseif #g.rows > 1 then
        error('F.write cannot merge ' .. g.sql, 2)
      end
      for _, row in ipairs(g.rows) do for _, p in ipairs(row) do params[#params + 1] = p end end
      sql_write(sql, params)
    end
    for _, o in ipairs(indexes) do
      local given = F.store(o.key)
      if o.delete and given.rev ~= '0' then error('F.write: a run still gives ' .. o.key, 2) end
      if not o.delete and given.rev == '0' then error('F.write: no run gives ' .. o.key, 2) end
    end
  end
  -- sql_ops gives the statements of record ops (no if_rev; index ops are left out: the runs
  -- carry them) as {sql, params}. They take their revisions from meta.rev when they run, and
  -- move it, all in the injection's transaction.
  local function sql_ops(ops)
    local out, n = {}, 0
    for _, o in ipairs(ops) do
      if not index_of(o.key) then
        local rev
        if not o.delete then
          n = n + 1
          rev = {expr = "CAST(CAST((SELECT value FROM meta WHERE name = 'rev') AS INTEGER) + " .. n .. " AS TEXT)"}
        end
        for _, s in ipairs(statements(o, rev)) do out[#out + 1] = {sql = s[1], params = s[2]} end
      end
    end
    out[#out + 1] = {sql = "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + " .. n .. " AS TEXT) WHERE name = 'rev'"}
    return out
  end
  -- F.inject_begin(ops, spec) commits record ops as another writer when the plugin next begins a
  -- transaction (inject{match = {sql_begin = true}, sql = ...}; hub/sql-lab 8510d50 or later).
  function F.inject_begin(ops, spec)
    spec = spec or {}
    return H.inject({match = {sql_begin = true}, sql = sql_ops(ops), skip = spec.skip, times = spec.times})
  end

  function F.run(key) return F.store(key).value end
  function F.wait_status(key, status, timeout)
    return H.wait('run ' .. key .. ' to be ' .. status, function()
      local run = F.store(key).value
      return run and run.status == status and run
    end, timeout or 20)
  end

  -- The cutover fixtures (cutover.lua, cutover_work.lua). F.to_store writes every row to hub.store
  -- in the layout of the slice 1 version (with the index records q/, t/, dv/ and box/) and each
  -- saved reply as an operation record; the store gives new revisions. F.empty_tables deletes
  -- every row. F.reload stops the plugin, runs setup (fixtures, injections), and starts a new
  -- instance: the hub process stays, so the injections and faults of setup stay armed.
  F.TABLES = {'meta', 'automations', 'states', 'runs', 'presets', 'seen', 'retired', 'ops'}
  function F.to_store()
    local batch = {ops = {}}
    local function flush() if #batch.ops > 0 then H.write(batch.ops) end batch.ops = {} end
    local function put(key, value) batch.ops[#batch.ops + 1] = {key = key, value = value} if #batch.ops >= 30 then flush() end end
    local next_id = H.sql("SELECT value FROM meta WHERE name = 'next_id'")[1]
    if next_id then put('meta/next_id', {n = tonumber(next_id.value)}) end
    for _, r in ipairs(H.sql('SELECT id, doc FROM automations')) do put('auto/' .. r.id, rex.json.decode(r.doc)) end
    for _, r in ipairs(H.sql('SELECT id, doc FROM states')) do put('state/' .. r.id, rex.json.decode(r.doc)) end
    for _, r in ipairs(H.sql('SELECT name, automation_id FROM presets')) do put('preset/' .. r.name, {id = r.automation_id}) end
    for _, r in ipairs(H.sql('SELECT key, doc FROM seen')) do put(r.key, rex.json.decode(r.doc)) end
    for _, r in ipairs(H.sql('SELECT key, doc FROM retired')) do put(r.key, rex.json.decode(r.doc)) end
    for _, r in ipairs(H.sql('SELECT run_key, automation_id, status, q, t, agent, doc FROM runs')) do
      local run = rex.json.decode(r.doc)
      put(r.run_key, run)
      if r.q then put(r.q, {run = r.run_key}) end
      if r.t then put(r.t, {run = r.run_key, seq = run.tseq}) end
      if r.status == 'delivered' then
        put('dv/' .. r.automation_id .. '/' .. r.run_key, {agent = r.agent})
        put('box/' .. r.agent .. '/' .. r.run_key, {attempt = run.attempt, auto = r.automation_id})
      end
    end
    flush()
    for _, r in ipairs(H.sql('SELECT key, fingerprint, reply FROM ops')) do
      H.put_operation({key = r.key, fingerprint = r.fingerprint, result = rex.json.decode(r.reply)})
    end
  end
  function F.empty_tables()
    for _, t in ipairs(F.TABLES) do sql_write('DELETE FROM ' .. t) end
  end
  function F.reload(setup)
    H.hub('hub.admin.stop', {plugin = 'automations'})
    if setup then setup() end
    H.hub('hub.admin.start', {plugin = 'automations'})
    H.wait('the plugin', function() return H.hub('hub.test.status', {}).plugins.automations.registered end, 30)
  end
  function F.copied()
    local r = H.sql("SELECT value FROM meta WHERE name = 'import'")[1]
    return r and r.value == 'cutover-1:done'
  end

  -- The plugin's first start copies hub.store (empty in a new lab) into the SQL tables; until the
  -- copy is done, every export answers unavailable. Each file starts after it.
  H.wait('the first copy', F.copied, 30)

  return F
end
