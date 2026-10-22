-- The Automations panel and forms. The main file loads this
-- file with dofile and an absolute path, and passes the functions that the views use. No RPC runs
-- at load time. A user action calls the same export handler as the agent tool, with the user as
-- the caller and the view operation key as the key.
--
-- Routes (a value in a query uses the Worktrees encoding):
--   /panels/automations[?after=<auto key>]               one page of automations, and the presets
--   /forms/automation/<id>[?after=<runs cursor>]          one automation and a page of its runs
--   /forms/automation/new[?profile=<id>]                  step 1 (the profile), then step 2 (fields)
--   /forms/automation/edit/<id>?rev=<rev>[&step=profile][&profile=<id>]
--   /forms/automation/preset/<name>[?profile=<id>]
--   /forms/automation/delete/<id>                         the delete confirmation
-- A profile picker page takes &profiles_after=<id>.
return function(A)
  local fail, hub, D, size, cut = A.fail, A.hub, A.D, A.size, A.cut
  local USER, BUDGET = A.USER, A.PAGE_BUDGET
  local PANEL_PAGE, PROFILE_PAGE, RUNS_PAGE = 20, 50, 20
  local LABEL, DETAIL = 60, 200

  local function enc(v)
    return (tostring(v):gsub('([^%w%-%._~])', function(c) return string.format('%%%02X', string.byte(c)) end))
  end
  local function dec(v)
    if v:gsub('%%%x%x', ''):find('%%') then fail('invalid_input', 'The route has a malformed escape') end
    return (v:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end))
  end
  -- route builds base?k=v&k=v from a list of {k, v}; a nil value is left out.
  local function route(base, q)
    local parts = {}
    for _, kv in ipairs(q or {}) do
      if kv[2] ~= nil then parts[#parts + 1] = kv[1] .. '=' .. enc(kv[2]) end
    end
    if #parts == 0 then return base end
    return base .. '?' .. table.concat(parts, '&')
  end
  local function parse(r)
    if type(r) ~= 'string' or r == '' then fail('invalid_input', 'Unknown route') end
    local base, query = r:match('^([^?]*)%?(.*)$')
    if not base then return r, {} end
    local q = {}
    for pair in query:gmatch('[^&]+') do
      local k, v = pair:match('^([%w_]+)=(.*)$')
      if not k then fail('invalid_input', 'The route has a malformed query') end
      q[k] = dec(v)
    end
    return base, q
  end

  local function cancel_node()
    return {id = 'cancel', type = 'widget', text = '', action = {name = '$cancel', label = 'Cancel', enabled = true}}
  end
  local function nav(name, label, enabled)
    return {name = name, label = label, enabled = enabled ~= false, user_only = 'navigation'}
  end
  local function when(t) return type(t) == 'number' and os.date('%Y-%m-%d %H:%M', t) or '' end
  local function trigger_text(t)
    if type(t) ~= 'table' then return '' end
    if t.kind == 'file' then return 'New ' .. tostring(t.glob or '*') .. ' file in ' .. tostring(t.path) end
    return 'Daily at ' .. tostring(t.at)
  end
  local function short(id, run_key) return run_key:sub(#A.run_prefix(id) + 1) end
  local function blocked(tree)
    tree.status = {state = 'blocked', kind = 'question', msg = 'Waiting for input'}
    return tree
  end
  local function gone(id)
    return {title = 'Automation ' .. id, nodes = {{id = 'gone', type = 'widget', text = 'Automation ' .. id .. ' no longer exists.'}, cancel_node()}}
  end
  -- measured fails when a tree is over the page budget: a render must never be cut.
  local function measured(tree)
    local n = size(tree)
    if n > BUDGET then fail('too_large', 'The view is ' .. n .. ' bytes encoded; the limit is ' .. BUDGET) end
    return tree
  end

  -- --- The panel ---

  -- panel_item reads, for one automation: the spawning run, the queue size (up to 21, shown as
  -- 20+) and the run that ended last, after its state: a page of 20 makes at most 1 + 4 * 20
  -- reads, plus the preset reads.
  local function panel_item(auto, st, listed)
    local id = auto.id
    local lines = {}
    if auto.deleted then
      lines[1] = 'Deleting: the cleanup waits for its active runs. Open it to cancel or dismiss them.'
    else
      lines[1] = trigger_text(auto.trigger) .. ' · ' .. (auto.enabled and 'enabled' or 'disabled') .. ' · profile ' .. tostring(auto.action.profile)
      if auto.trigger.kind == 'file' and auto.enabled then
        local w = A.watch_view(id, listed[A.watch_key(id, st.gen)])
        lines[#lines + 1] = 'Watch: ' .. tostring(w.state) .. (w.error and (': ' .. w.error) or '') .. (w.hint and ('. ' .. w.hint) or '')
      end
    end
    local sp = type(st.spawning) == 'table' and st.spawning.run or nil
    local status = auto.deleted and 'deleting' or (auto.enabled and 'on' or 'off')
    local sprun = sp and D.run(sp) or nil
    if sprun and sprun.status == 'unknown_start' then
      lines[#lines + 1] = 'Needs action: a worker start has no outcome. Open it to dismiss the start.'
      status = 'needs action'
    elseif sprun then
      lines[#lines + 1] = 'Starting a worker.'
    end
    -- The spawning run keeps its place in the queue, and it is the first one.
    local queued = A.queue_size(id, 21) - (sp and 1 or 0)
    if queued > 0 then lines[#lines + 1] = 'Queued: ' .. (queued >= 20 and '20+' or tostring(queued)) .. ' runs.' end
    local lr = A.last_run(id)
    if lr then lines[#lines + 1] = 'Last run: ' .. tostring(lr.status) .. ' (' .. when(lr.done_at or lr.at) .. ')' end
    return {id = id, label = auto.name .. (auto.deleted and ' (deleting)' or ''), detail = table.concat(lines, '\n'), status = status,
      action = nav('open', 'Open…')}
  end

  local function preset_items()
    local items = {}
    for _, n in ipairs(A.PRESET_NAMES) do
      local p, installed = A.PRESETS[n], D.preset(n)
      items[#items + 1] = {id = n, label = p.name, detail = installed and ('Installed as automation ' .. tostring(installed) .. '.') or p.about,
        action = nav('add', 'Add…', installed == nil)}
    end
    return items
  end

  -- panel_page returns the items of one page and the next cursor. A page ends early, with next,
  -- when an item does not fit the budget.
  local function panel_page(after, room)
    if after ~= nil and (after:sub(1, 5) ~= 'auto/' or #after > 64) then fail('invalid_input', 'after is an automation key') end
    local page, more = D.autos(after and after:sub(6), PANEL_PAGE)
    local listed = {}
    for _, w in ipairs(hub('hub.watch.list').watches or {}) do listed[w.key] = w end
    local P = {items = {}, used = room, last = after}
    for _, a in ipairs(page) do
      local item = panel_item(a.value, D.state(a.key) or {}, listed)
      local n = size(item) + 1
      if P.used + n > BUDGET then
        if P.last == after then fail('too_large', 'Automation ' .. a.key .. ' is too large for the panel') end
        return P.items, P.last
      end
      P.items[#P.items + 1] = item
      P.used = P.used + n
      P.last = 'auto/' .. a.key
    end
    if more then return P.items, P.last end
    return P.items, nil
  end

  local function render_panel(q)
    local presets = preset_items()
    local head = {id = 'new', type = 'widget', text = 'An automation runs an agent task for a new file in a directory, or every day at a time.',
      action = nav('new', 'New Automation…')}
    local base = {title = 'Automations', nodes = {head, {id = 'automations', type = 'list', label = 'Automations', items = {}},
      {id = 'presets', type = 'list', label = 'Presets', items = presets}}}
    local items, next_after = panel_page(q.after, size(base) + 1024)
    local nodes = {head}
    if #items == 0 then
      nodes[#nodes + 1] = {id = 'none', type = 'widget', text = q.after and 'No automations on this page.' or 'No automations yet. Add one, or add a preset.'}
    end
    nodes[#nodes + 1] = {id = 'automations', type = 'list', label = 'Automations', items = items}
    if next_after then nodes[#nodes + 1] = {id = 'next_page', type = 'widget', text = '', action = nav('next', 'Next page')} end
    if q.after then nodes[#nodes + 1] = {id = 'first_page', type = 'widget', text = '', action = nav('first', 'First page')} end
    nodes[#nodes + 1] = {id = 'presets', type = 'list', label = 'Presets', items = presets}
    return measured({title = 'Automations', nodes = nodes}), next_after
  end

  -- --- One automation ---

  local function load_auto(id)
    local auto, rev = D.auto(id)
    return auto, rev, D.state(id) or {}
  end

  local RETRYABLE = {failed = true, dismissed = true, cancelled = true}
  local function run_item(id, auto, r)
    local lines = {when(r.at) .. ((r.attempt or 0) > 0 and (' · attempt ' .. r.attempt) or '') .. (r.agent and (' · ' .. r.agent) or '')}
    if type(r.item) == 'table' and r.item.name then lines[#lines + 1] = 'File: ' .. cut(tostring(r.item.name), LABEL) end
    if r.error then lines[#lines + 1] = 'Error: ' .. cut(tostring(r.error), DETAIL) end
    if r.summary then lines[#lines + 1] = cut(tostring(r.summary), DETAIL) end
    local action
    if r.status == 'queued' then
      action = {name = 'cancel', label = 'Cancel run', enabled = true, tool = 'automations.cancel_run'}
    elseif r.status == 'unknown_start' then
      lines[#lines + 1] = 'The worker start has no outcome after 10 minutes. Dismiss ends this run. Its pane can still appear as a duplicate worker; stop it with hub.stop.'
      action = {name = 'dismiss', label = 'Dismiss pending start', enabled = true, tool = 'automations.dismiss_start'}
    elseif RETRYABLE[r.status] and not auto.deleted then
      local pathless = r.kind == 'f' and type(r.item) == 'table' and r.item.path == nil
      if pathless then lines[#lines + 1] = 'Retry is not possible: the run has no file path (path too long).'
      elseif not auto.enabled then lines[#lines + 1] = 'Retry: enable the automation first.' end
      action = {name = 'retry', label = 'Retry', enabled = auto.enabled and not pathless, tool = 'automations.retry'}
    end
    return {id = r.run_key, label = short(id, r.run_key) .. ' · ' .. tostring(r.status), detail = table.concat(lines, '\n'), status = r.status, action = action}
  end

  local function about_text(auto, st)
    local lines = {trigger_text(auto.trigger) .. ' · ' .. (auto.enabled and 'enabled' or 'disabled')}
    local a = auto.action
    lines[#lines + 1] = 'Profile: ' .. tostring(a.profile) .. (a.cwd and (' · in ' .. a.cwd) or '') .. (a.title and (' · tab ' .. a.title) or '')
    if auto.preset then lines[#lines + 1] = 'Preset: ' .. auto.preset end
    if type(st.worker) == 'table' then lines[#lines + 1] = 'Worker: ' .. tostring(st.worker.agent_id) end
    lines[#lines + 1] = 'Instruction: ' .. cut(auto.instruction or '', 500)
    return table.concat(lines, '\n')
  end

  local function render_auto(id, q)
    local auto, _, st = load_auto(id)
    if not auto then return gone(id) end
    local page = A.runs(USER, {id = id, after = q.after, limit = RUNS_PAGE})
    local items = {}
    for _, r in ipairs(page.runs) do items[#items + 1] = run_item(id, auto, r) end
    local nodes = {}
    if auto.deleted then
      nodes[1] = {id = 'about', type = 'widget', text = 'Deleting: no new run, start or delivery. A run that is starting or delivered continues until it ends; then the automation and its run history go.'}
    else
      nodes[1] = {id = 'about', type = 'widget', text = about_text(auto, st)}
      nodes[#nodes + 1] = {id = 'run', type = 'widget', text = auto.enabled and '' or 'Disabled: enable it to run it.',
        action = {name = 'run', label = 'Run now', enabled = auto.enabled == true, tool = 'automations.run'}}
      nodes[#nodes + 1] = {id = 'enabled', type = 'widget', text = '', action = {name = auto.enabled and 'disable' or 'enable',
        label = auto.enabled and 'Disable' or 'Enable', enabled = true, tool = 'automations.set_enabled'}}
      nodes[#nodes + 1] = {id = 'edit', type = 'widget', text = '', action = nav('edit', 'Edit…')}
      nodes[#nodes + 1] = {id = 'delete', type = 'widget', text = '', action = nav('delete', 'Delete…')}
    end
    if #items == 0 then nodes[#nodes + 1] = {id = 'no_runs', type = 'widget', text = q.after and 'No runs on this page.' or 'No runs yet.'} end
    nodes[#nodes + 1] = {id = 'runs', type = 'list', label = 'Runs', items = items}
    if page.next then nodes[#nodes + 1] = {id = 'more_runs', type = 'widget', text = '', action = nav('more', 'More runs')} end
    if q.after then nodes[#nodes + 1] = {id = 'first_runs', type = 'widget', text = '', action = nav('first', 'First runs')} end
    nodes[#nodes + 1] = cancel_node()
    return measured({title = auto.name .. (auto.deleted and ' (deleting)' or ''), nodes = nodes})
  end

  -- --- Forms: step 1 (the profile) and step 2 (the fields) ---

  local function profiles()
    local all = {}
    for _, p in ipairs(hub('hub.profiles').profiles or {}) do
      if type(p) == 'table' and type(p.id) == 'string' and p.kind == 'agent' then all[#all + 1] = p end
    end
    table.sort(all, function(a, b) return a.id < b.id end)
    return all
  end
  local function profile_of(id)
    for _, p in ipairs(hub('hub.profiles').profiles or {}) do
      if type(p) == 'table' and p.id == id then return p end
    end
    return nil
  end
  -- picker_page gives at most PROFILE_PAGE options after the id `after`, while the tree fits.
  local function picker_page(after, room)
    local all = profiles()
    local i = 1
    while after and i <= #all and all[i].id <= after do i = i + 1 end
    local P = {options = {}, used = room, last = nil}
    while i <= #all and #P.options < PROFILE_PAGE do
      local o = {value = all[i].id, label = cut(tostring(all[i].name or all[i].id), LABEL) .. ' (' .. all[i].id .. ')'}
      local n = size(o) + 1
      if P.used + n > BUDGET then break end
      P.options[#P.options + 1] = o
      P.used = P.used + n
      P.last = all[i].id
      i = i + 1
    end
    return P.options, i <= #all and P.last or nil, #all
  end

  -- F describes a form route: title, base (the step 2 route without the profile), keep (query
  -- values that every step keeps: rev), the current profile, the defaults of the fields, and the
  -- automation id and preset for the save.
  local function picker(F, q)
    local form = {id = 'profile', type = 'form', fields = {{id = 'profile', label = 'Agent profile', kind = 'select', required = true, value = '', options = {}}},
      submit_action = nav('submit', 'Next')}
    local skeleton = {title = F.title, nodes = {form, {id = 'more_profiles', type = 'widget', text = '', action = nav('more', 'More profiles…')},
      {id = 'first_profiles', type = 'widget', text = '', action = nav('first', 'First profiles')}, cancel_node()}}
    local options, more, total = picker_page(q.profiles_after, size(skeleton) + 256)
    local nodes = {}
    if #options == 0 then
      nodes[1] = {id = 'none', type = 'widget', text = total == 0 and 'No agent profile exists. Add one to the profiles file (hub.profiles).' or 'No more profiles.'}
    else
      local value = options[1].value
      for _, o in ipairs(options) do if o.value == F.profile then value = o.value end end
      form.fields[1].value = value
      form.fields[1].options = options
      nodes[1] = form
    end
    if more then nodes[#nodes + 1] = skeleton.nodes[2] end
    if q.profiles_after then nodes[#nodes + 1] = skeleton.nodes[3] end
    nodes[#nodes + 1] = {id = 'help', type = 'widget', text = 'Step 1 of 2: the agent profile that a run starts. The fields come in step 2.'}
    nodes[#nodes + 1] = cancel_node()
    return blocked(measured({title = F.title, nodes = nodes})), more
  end

  local function change_node()
    return {id = 'change_profile', type = 'widget', text = 'The entered fields are not kept.', action = nav('change', 'Change profile…')}
  end

  local function fields_form(F, profile_id)
    local v = F.values
    local profile = profile_of(profile_id)
    local nodes = {{id = 'profile', type = 'widget', text = 'Profile: ' .. (profile and (cut(tostring(profile.name or profile_id), LABEL) .. ' (' .. profile_id .. ')') or profile_id)}}
    if not profile or profile.kind ~= 'agent' then
      nodes[#nodes + 1] = {id = 'profile_warning', type = 'widget', text = 'Profile ' .. profile_id .. ' is no longer an agent profile; change the profile.'}
    end
    for _, w in ipairs(F.warnings or {}) do nodes[#nodes + 1] = w end
    local fields = {
      {id = 'name', label = 'Name', kind = 'text', required = true, value = v.name or ''},
      {id = 'enabled', label = 'Enabled', kind = 'boolean', value = v.enabled ~= false},
      {id = 'trigger', label = 'Trigger', kind = 'select', required = true, value = v.kind or 'file',
        options = {{value = 'file', label = 'A new file in a directory'}, {value = 'daily', label = 'Every day at a time'}}},
      {id = 'path', label = 'Directory (for a new file)', kind = 'text', value = v.path or '', browse = 'native'},
      {id = 'glob', label = 'File name pattern (for a new file)', kind = 'text', value = v.glob or '*'},
      {id = 'at', label = 'Time HH:MM, local (for every day)', kind = 'text', value = v.at or ''},
      {id = 'cwd', label = 'Working directory of the worker (optional)', kind = 'text', value = v.cwd or '', browse = 'native'},
      {id = 'title', label = 'Tab title (optional)', kind = 'text', value = v.title or ''},
      {id = 'instruction', label = 'Instruction for the agent', kind = 'multiline', required = true, value = v.instruction or ''},
    }
    local given = type(v.args) == 'table' and v.args or {}
    for _, arg in ipairs(profile and profile.args or {}) do
      if type(arg) == 'table' and type(arg.name) == 'string' then
        fields[#fields + 1] = {id = 'arg/' .. arg.name, label = cut(tostring(arg.label or arg.name), LABEL), kind = 'text',
          required = arg.required == true, value = given[arg.name] or arg.default or ''}
      end
    end
    nodes[#nodes + 1] = {id = 'automation', type = 'form', fields = fields,
      submit_action = {name = 'submit', label = F.id and 'Save' or 'Create automation', enabled = true, tool = 'automations.save'}}
    nodes[#nodes + 1] = change_node()
    nodes[#nodes + 1] = cancel_node()
    local tree = {title = F.title, nodes = nodes}
    local n = size(tree)
    if n > BUDGET then
      -- The form cannot be cut: a refusal instead, with the bytes named.
      local text = (profile and #(profile.args or {}) > 0 and ('Profile ' .. profile_id .. ' has too many args for this form') or 'This form is too large')
        .. ' (' .. n .. ' bytes encoded; the limit is ' .. BUDGET .. '); use automations.save, or choose another profile.'
      tree = {title = F.title, nodes = {{id = 'too_large', type = 'widget', text = text}, change_node(), cancel_node()}}
    end
    return blocked(measured(tree))
  end

  local function nonempty(x)
    if type(x) == 'string' and x ~= '' then return x end
    return nil
  end
  -- form_save builds the save arguments from the submitted values, as an agent would.
  local function form_save(F, profile_id, values, key)
    local v = type(values) == 'table' and values or {}
    local trigger
    if v.trigger == 'file' then trigger = {kind = 'file', path = nonempty(v.path), glob = nonempty(v.glob)}
    elseif v.trigger == 'daily' then trigger = {kind = 'daily', at = nonempty(v.at)}
    else fail('invalid_input', 'Choose a trigger') end
    local named = {}
    for k, x in pairs(v) do
      if type(k) == 'string' and k:sub(1, 4) == 'arg/' and type(x) == 'string' and x ~= '' then named[k:sub(5)] = x end
    end
    local action = {profile = profile_id, cwd = nonempty(v.cwd), title = nonempty(v.title)}
    if next(named) then action.args = named end
    local args = {key = key, name = v.name, enabled = v.enabled ~= false, trigger = trigger, action = action, instruction = v.instruction}
    if F.id then args.id, args.if_rev = F.id, F.rev end
    if F.preset then args.preset = F.preset end
    local ok, result = pcall(A.save, USER, args)
    if ok then return result end
    if F.id and type(result) == 'table' and result.code == 'conflict' then
      fail('conflict', tostring(result.message) .. '. The automation changed since this form opened; reopen it to edit the current version.')
    end
    error(result, 0)
  end

  -- form_route resolves a form route to F and the step. It returns nil for another route.
  local function form_route(base, q)
    if base == '/forms/automation/new' then
      return {title = 'New automation', base = base, keep = {}, profile = q.profile, values = {}}
    end
    local p = base:match('^/forms/automation/preset/([%w%-]+)$')
    if p then
      local preset = A.PRESETS[p]
      if not preset then fail('invalid_input', 'No preset ' .. p) end
      local installed = D.preset(p)
      local warnings = {}
      if installed then warnings[1] = {id = 'installed', type = 'widget', text = 'Preset ' .. p .. ' is installed as automation ' .. tostring(installed) .. '.'} end
      local t = preset.trigger
      return {title = 'Add ' .. preset.name, base = base, keep = {}, profile = q.profile, preset = p, warnings = warnings,
        values = {name = preset.name, kind = t.kind, path = t.path, glob = t.glob, at = t.at, cwd = preset.cwd, instruction = preset.instruction}}
    end
    local id = base:match('^/forms/automation/edit/(%d+)$')
    if id then
      if type(q.rev) ~= 'string' or q.rev == '' then fail('invalid_input', 'The edit route has no rev') end
      local auto, rev = load_auto(id)
      if not auto or auto.deleted then return {gone = id} end
      local profile = q.profile or auto.action.profile
      local warnings = {}
      if rev ~= q.rev then
        warnings[1] = {id = 'stale', type = 'widget', text = 'Automation ' .. id .. ' changed since this form opened (rev ' .. q.rev .. ', now ' .. rev
          .. '). Save is refused; reopen the automation to edit the current version.'}
      end
      local t = auto.trigger
      return {title = 'Edit ' .. auto.name, base = base, keep = {{'rev', q.rev}}, profile = profile, id = id, rev = q.rev, warnings = warnings,
        values = {name = auto.name, enabled = auto.enabled, kind = t.kind, path = t.path, glob = t.glob, at = t.at, cwd = auto.action.cwd,
          title = auto.action.title, instruction = auto.instruction, args = profile == auto.action.profile and auto.action.args or nil}}
    end
    return nil
  end
  -- step 1 is the picker when no profile is chosen, or when an edit asks for it (step=profile).
  local function picking(F, q) return F.profile == nil or q.step == 'profile' end
  local function step2_route(F, profile_id)
    local query = {}
    for _, kv in ipairs(F.keep) do query[#query + 1] = kv end
    query[#query + 1] = {'profile', profile_id}
    return route(F.base, query)
  end
  local function picker_route(F, q, profiles_after)
    local query = {}
    for _, kv in ipairs(F.keep) do query[#query + 1] = kv end
    if F.id then query[#query + 1] = {'step', 'profile'} end
    if F.id and q.profile then query[#query + 1] = {'profile', q.profile} end
    if not F.id and q.profile then query[#query + 1] = {'profile', q.profile} end
    query[#query + 1] = {'profiles_after', profiles_after}
    return route(F.base, query)
  end

  local function render_delete(id)
    local auto = load_auto(id)
    if not auto or auto.deleted then return gone(id) end
    return blocked(measured({title = 'Delete ' .. auto.name, nodes = {
      {id = 'warning', type = 'widget', text = 'Delete ' .. auto.name .. '? This also deletes its run history. Queued runs are cancelled. '
        .. 'A run that is starting or delivered continues until it ends; then the automation and its runs go.'},
      {id = 'delete_automation', type = 'form', fields = {{id = 'id', label = 'Automation', kind = 'select', required = true, value = id,
        options = {{value = id, label = cut(auto.name, LABEL) .. ' and its run history'}}}},
        submit_action = {name = 'submit', label = 'Delete', enabled = true, tool = 'automations.delete'}},
      cancel_node(),
    }}))
  end

  local M = {}

  function M.render(args)
    local base, q = parse(args.route)
    if base == '/panels/automations' then return {tree = (render_panel(q))} end
    local id = base:match('^/forms/automation/(%d+)$')
    if id then return {tree = render_auto(id, q)} end
    id = base:match('^/forms/automation/delete/(%d+)$')
    if id then return {tree = render_delete(id)} end
    local F = form_route(base, q)
    if not F then fail('invalid_input', 'Unknown route') end
    if F.gone then return {tree = gone(F.gone)} end
    if picking(F, q) then return {tree = (picker(F, q))} end
    return {tree = fields_form(F, F.profile)}
  end

  local function key_of(args)
    if type(args.operation_key) ~= 'string' or args.operation_key == '' then fail('invalid_input', 'operation_key is required') end
    return 'view/' .. args.operation_key
  end
  local function run_of(id, input)
    local rk = type(input.item_id) == 'string' and input.item_id or ''
    if rk:sub(1, #A.run_prefix(id)) ~= A.run_prefix(id) then fail('invalid_input', 'The item is not a run of automation ' .. id) end
    return rk
  end

  function M.action(args)
    local base, q = parse(args.route)
    local node, act = args.node_id, args.action
    local input = type(args.input) == 'table' and args.input or {}
    if base == '/panels/automations' then
      if node == 'new' and act == 'new' then return {form = '/forms/automation/new'} end
      if node == 'automations' and act == 'open' and type(input.item_id) == 'string' and input.item_id:match('^%d+$') then
        return {form = '/forms/automation/' .. input.item_id}
      end
      if node == 'presets' and act == 'add' and A.PRESETS[input.item_id or ''] then return {form = '/forms/automation/preset/' .. input.item_id} end
      if node == 'next_page' and act == 'next' then
        local _, next_after = render_panel(q)
        if not next_after then return {} end
        return {panel = {route = route(base, {{'after', next_after}})}}
      end
      if node == 'first_page' and act == 'first' then return {panel = {route = base}} end
      fail('invalid_input', 'Unknown view action')
    end
    local id = base:match('^/forms/automation/(%d+)$')
    if id then
      if node == 'run' and act == 'run' then A.run_now(USER, {id = id, key = key_of(args)}); return {} end
      if node == 'enabled' and (act == 'enable' or act == 'disable') then
        A.set_enabled(USER, {id = id, enabled = act == 'enable', key = key_of(args)})
        return {}
      end
      if node == 'edit' and act == 'edit' then
        local auto, rev = load_auto(id)
        if not auto or auto.deleted then fail('not_found', 'No automation ' .. id) end
        return {form = route('/forms/automation/edit/' .. id, {{'rev', rev}})}
      end
      if node == 'delete' and act == 'delete' then return {form = '/forms/automation/delete/' .. id} end
      if node == 'runs' then
        local rk = run_of(id, input)
        local change = ({cancel = A.cancel_run, dismiss = A.dismiss_start, retry = A.retry})[act]
        if change then change(USER, {run_key = rk, key = key_of(args)}); return {} end
      end
      if node == 'more_runs' and act == 'more' then
        local page = A.runs(USER, {id = id, after = q.after, limit = RUNS_PAGE})
        if not page.next then return {} end
        return {form = route(base, {{'after', page.next}})}
      end
      if node == 'first_runs' and act == 'first' then return {form = base} end
      fail('invalid_input', 'Unknown view action')
    end
    id = base:match('^/forms/automation/delete/(%d+)$')
    if id then
      if node == 'delete_automation' and act == 'submit' then
        local values = type(input.values) == 'table' and input.values or {}
        if values.id ~= id then fail('invalid_input', 'Confirm the automation to delete') end
        A.delete(USER, {id = id, key = key_of(args)})
        return {close_form = true}
      end
      fail('invalid_input', 'Unknown view action')
    end
    local F = form_route(base, q)
    if not F then fail('invalid_input', 'Unknown view action') end
    if F.gone then fail('not_found', 'No automation ' .. F.gone) end
    if picking(F, q) then
      if node == 'profile' and act == 'submit' then
        local values = type(input.values) == 'table' and input.values or {}
        if type(values.profile) ~= 'string' or values.profile == '' then fail('invalid_input', 'Choose a profile') end
        return {form = step2_route(F, values.profile)}
      end
      if node == 'more_profiles' and act == 'more' then
        local _, more = picker(F, q)
        if not more then return {} end
        return {form = picker_route(F, q, more)}
      end
      if node == 'first_profiles' and act == 'first' then return {form = picker_route(F, q, nil)} end
      fail('invalid_input', 'Unknown view action')
    end
    if node == 'automation' and act == 'submit' then
      form_save(F, F.profile, input.values, key_of(args))
      return {close_form = true}
    end
    if node == 'change_profile' and act == 'change' then
      if F.id then return {form = route(F.base, {{'rev', F.rev}, {'step', 'profile'}, {'profile', F.profile}})} end
      return {form = F.base}
    end
    fail('invalid_input', 'Unknown view action')
  end

  return M
end
