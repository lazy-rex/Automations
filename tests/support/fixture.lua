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
  -- Before the test agent starts, the pane reports the conversation identity
  -- claude:w-<spawn's agent ID>, as an agent CLI's start hook does; the plugin delivers to that
  -- identity. The pane's process is the same before and after exec. F.silent is a profile that
  -- reports nothing: its worker has no identity until a test reports one. A test adds it to the list.
  -- profile_list is the base list; a test can add profiles to it and write it.
  local REPORT = [["$0" testagent report "{\"kind\":\"claude\",\"conversation_id\":\"w-$LAZYREX_AGENT\",\"source\":\"startup\"}"; ]]
  local AGENT = [[exec "$0" testagent -id "$LAZYREX_AGENT" -join "$LAZYREX_AGENT"]]
  function F.profile_list()
    return {
      {id = 'worker', name = 'Worker', kind = 'agent', command = {'/bin/sh', '-c', REPORT .. AGENT, H.args.hub_bin}},
      {id = 'tasked', name = 'Tasked', kind = 'agent', args = {{name = 'task', label = 'Task', required = true}},
        command = {'/bin/sh', '-c', REPORT .. AGENT, H.args.hub_bin, '${task}'}},
      {id = 'logtail', name = 'Log tail', kind = 'accessory', command = {'/bin/sh', '-c', 'exec tail -f /dev/null'}},
    }
  end
  function F.silent() return {id = 'silent', name = 'Silent', kind = 'agent', command = {'/bin/sh', '-c', AGENT, H.args.hub_bin}} end
  -- identity is the identity that a worker profile reports for a spawn's agent ID.
  function F.identity(agent_id) return 'claude:w-' .. agent_id end
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
  -- face (the MCP path), as an agent's tool call. id is the identity that the profile reported
  -- (a run's agent) or the spawn's agent ID. The caller's id is the given id.
  function F.worker(id)
    local agent_id = id:match('^claude:w%-(.+)$') or id
    local client = H.wait('the worker ' .. agent_id .. ' to start', function() return H.resolve('lazyrex-testagent:' .. agent_id) end, 20)
    H.wait('the worker ' .. agent_id .. ' to join', function()
      local s = H.perform(client, 'agent.status', {})
      return s.joined
    end, 20)
    return {id = id,
      call = function(_, action, args) return H.perform(client, 'agent.call', {action = action, args = args or {}}) end,
      -- report sends hub.identity.report from a new process in the worker's pane, as an agent hook.
      report = function(_, kind, conversation_id)
        return H.perform(client, 'agent.report', {args = {kind = kind, conversation_id = conversation_id, source = 'startup'}}, 20000)
      end,
      -- exit ends the test agent process, as the user quits an agent CLI.
      exit = function() pcall(H.perform, client, 'agent.exit', {}) end}
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

  -- The plugin's rows, by table. A reader answers the row's document, or nil when the row is
  -- absent; F.rev(tbl, key) answers the row's revision. The run readers by column answer the run
  -- that a queue key (q) or an end key (t) names, and the run while it is delivered.
  local KEYS = {automations = 'id', states = 'id', runs = 'run_key', presets = 'name', seen = 'key', retired = 'key'}
  local function row(tbl, cols, key)
    local col = KEYS[tbl] or error('no table ' .. tostring(tbl), 3)
    return H.sql('SELECT ' .. cols .. ' FROM ' .. tbl .. ' WHERE ' .. col .. ' = ?', {key})[1]
  end
  local function doc(tbl, key) local r = row(tbl, 'doc', key) return r and rex.json.decode(r.doc) end
  function F.auto(id) return doc('automations', id) end
  function F.state(id) return doc('states', id) end
  function F.run(run_key) return doc('runs', run_key) end
  function F.seen(key) return doc('seen', key) end
  function F.retired(key) return doc('retired', key) end
  -- F.preset answers the id of the automation that installed the preset.
  function F.preset(name) local r = row('presets', 'automation_id', name) return r and r.automation_id end
  function F.rev(tbl, key) local r = row(tbl, 'rev', key) return r and r.rev end
  -- F.next_id answers meta.next_id (a number) and its revision, or nil before the first create.
  function F.next_id()
    local n, r = H.sql("SELECT value FROM meta WHERE name = 'next_id'")[1], H.sql("SELECT value FROM meta WHERE name = 'next_id_rev'")[1]
    if not n then return nil end
    return tonumber(n.value), r and r.value
  end
  function F.queued(q) local r = H.sql('SELECT run_key FROM runs WHERE q = ?', {q})[1] return r and r.run_key end
  function F.ended(t) local r = H.sql('SELECT run_key FROM runs WHERE t = ?', {t})[1] return r and r.run_key end
  -- F.delivered answers the run while it is delivered; F.held, while it is delivered to agent.
  function F.delivered(id, run_key)
    local r = H.sql("SELECT doc FROM runs WHERE run_key = ? AND automation_id = ? AND status = 'delivered'", {run_key, id})[1]
    return r and rex.json.decode(r.doc)
  end
  function F.held(agent, run_key)
    local r = H.sql("SELECT doc FROM runs WHERE run_key = ? AND agent = ? AND status = 'delivered'", {run_key, agent})[1]
    return r and rex.json.decode(r.doc)
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
  F.sql_write = sql_write
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
  -- A row op is {tbl, key, value} or {tbl, key, delete = true}. statement turns it into one SQL
  -- statement {sql, params}. The value of a presets row is the automation id; of another row, its
  -- document. rev is the new revision: a value, or {expr = <SQL expression>} for a statement that
  -- takes it from meta.rev when it runs.
  local function statement(o, rev)
    local col = KEYS[o.tbl] or error('no table ' .. tostring(o.tbl), 3)
    if o.delete then return {'DELETE FROM ' .. o.tbl .. ' WHERE ' .. col .. ' = ?', {o.key}} end
    local r, rp = '?', {rev}
    if type(rev) == 'table' then r, rp = rev.expr, {} end
    local function with(head, tail)
      local out = {}
      for _, v in ipairs(head) do out[#out + 1] = v end
      for _, v in ipairs(rp) do out[#out + 1] = v end
      for _, v in ipairs(tail) do out[#out + 1] = v end
      return out
    end
    if o.tbl == 'runs' then
      local v = o.value
      return {'INSERT INTO runs (run_key, automation_id, rev, status, q, t, agent, doc) VALUES (?, ?, ' .. r .. ', ?, ?, ?, ?, ?) '
        .. 'ON CONFLICT (run_key) DO UPDATE SET rev = excluded.rev, status = excluded.status, q = excluded.q, t = excluded.t, '
        .. 'agent = excluded.agent, doc = excluded.doc',
        with({o.key, o.key:match('^run/([^/]+)/')}, {tostring(v.status), null(v.q), null(v.t), null(v.agent), rex.json.encode(v)})}
    end
    if o.tbl == 'presets' then
      return {'INSERT INTO presets (name, rev, automation_id) VALUES (?, ' .. r .. ', ?) ON CONFLICT (name) DO UPDATE SET rev = excluded.rev, '
        .. 'automation_id = excluded.automation_id', with({o.key}, {tostring(o.value)})}
    end
    return {'INSERT INTO ' .. o.tbl .. ' (' .. col .. ', rev, doc) VALUES (?, ' .. r .. ', ?) ON CONFLICT (' .. col .. ') '
      .. 'DO UPDATE SET rev = excluded.rev, doc = excluded.doc', with({o.key}, {rex.json.encode(o.value)})}
  end
  -- F.write(ops) writes row ops, each written row with a new revision from meta.rev. An op with
  -- new = true needs an absent row; with if_rev, a row at that revision. It is for fixtures. The
  -- statements of one table merge into one statement (many VALUES rows, or IN for deletes), in
  -- the order that the ops name the tables, so the plugin never sees a half-written table.
  function F.write(ops)
    local n = 0
    for _, o in ipairs(ops) do
      local cur = F.rev(o.tbl, o.key)
      if o.new and cur ~= nil then error({code = 'conflict', message = o.tbl .. ' row ' .. o.key .. ' exists at rev ' .. cur}, 2) end
      if o.if_rev ~= nil and cur ~= o.if_rev then error({code = 'conflict', message = o.tbl .. ' row ' .. o.key .. ' is at rev ' .. tostring(cur)}, 2) end
      if not o.delete then n = n + 1 end
    end
    local revs, r = reserve(n), 0
    local groups, order = {}, {}
    for _, o in ipairs(ops) do
      local rev
      if not o.delete then r = r + 1; rev = revs[r] end
      local st = statement(o, rev)
      local g = groups[st[1]]
      if not g then g = {sql = st[1], rows = {}}; groups[st[1]] = g; order[#order + 1] = g end
      g.rows[#g.rows + 1] = st[2]
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
      for _, row_params in ipairs(g.rows) do for _, p in ipairs(row_params) do params[#params + 1] = p end end
      sql_write(sql, params)
    end
  end
  -- F.inject_begin(ops, spec) commits row ops as another writer when the plugin next begins a
  -- transaction (inject{match = {sql_begin = true}, sql = ...}). The statements take their
  -- revisions from meta.rev when they run, and move it, all in the injection's transaction.
  function F.inject_begin(ops, spec)
    spec = spec or {}
    local sql, n = {}, 0
    for _, o in ipairs(ops) do
      local rev
      if not o.delete then
        n = n + 1
        rev = {expr = "CAST(CAST((SELECT value FROM meta WHERE name = 'rev') AS INTEGER) + " .. n .. " AS TEXT)"}
      end
      local st = statement(o, rev)
      sql[#sql + 1] = {sql = st[1], params = st[2]}
    end
    sql[#sql + 1] = {sql = "UPDATE meta SET value = CAST(CAST(value AS INTEGER) + " .. n .. " AS TEXT) WHERE name = 'rev'"}
    return H.inject({match = {sql_begin = true}, sql = sql, skip = spec.skip, times = spec.times})
  end

  function F.wait_status(key, status, timeout)
    return H.wait('run ' .. key .. ' to be ' .. status, function()
      local run = F.run(key)
      return run and run.status == status and run
    end, timeout or 20)
  end

  -- F.TABLES are the plugin's tables. F.reload stops the plugin, runs setup (fixtures,
  -- injections), and starts a new instance: the hub process stays, so the injections and faults of
  -- setup stay armed. F.started is true when the panel shows no start text (the start ended).
  F.TABLES = {'meta', 'automations', 'states', 'runs', 'presets', 'seen', 'retired', 'ops'}
  function F.reload(setup)
    H.hub('hub.admin.stop', {plugin = 'automations'})
    if setup then setup() end
    H.hub('hub.admin.start', {plugin = 'automations'})
    H.wait('the plugin', function() return H.hub('hub.test.status', {}).plugins.automations.registered end, 30)
  end
  function F.started()
    local ok, tree = pcall(function() local _, t = F.panel() return t end)
    return ok and type(tree) == 'table' and H.node(tree, 'not_ready') == nil
  end

  -- Until the start ends, every export answers unavailable. Each file starts after it.
  H.wait('the start', F.started, 30)

  return F
end
