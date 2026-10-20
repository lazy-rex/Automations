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

  function F.run(key) return H.store(key).value end
  function F.wait_status(key, status, timeout)
    return H.wait('run ' .. key .. ' to be ' .. status, function()
      local run = H.store(key).value
      return run and run.status == status and run
    end, timeout or 20)
  end

  return F
end
