-- Automations: a trigger plus an action. A daily trigger (a local time) makes a run. The run goes
-- to the automation's worker if it runs; else the plugin starts a worker from the automation's
-- profile (hub.spawn for the user), then delivers. Delivery is a task box entry plus a hub notice;
-- the worker reads its tasks (automations.read) and completes them (automations.done).
-- The design is "Automations design v2" with amendment 1 (team thread, 2026-10-20).
--
-- Lua rules (LazyRex docs/rex-protocol.md, "Rex Lua runtime"): callback state lives in table
-- fields (a closure write to a captured local can be lost after a caught error); the main chunk
-- catches no error (startup work runs in rex.after(0)); complex values go into a local before a
-- generic for; no swap assignment.
--
-- The LazyRex Plugin SDK (hub sdk/lua) does the registration and the dispatch. The hub starts the
-- plugin through the SDK launcher (manifest "sdk": "0"), which puts the SDK in package.path. The
-- store engine, its replay and the hub calls below stay the plugin's own (SDK port plan, slice 1).
local app = require('lazyrex').plugin('automations')
local hub_id = app.hub_id

local function fail(code, message) error({code = code, message = message}, 0) end

-- A hub error arrives as text that ends with "(status=<n> code=<code>)" (observed on Rex
-- 0.0.1792158932-g88fd41, lab; see Profiles). An error whose outcome is not known becomes
-- unavailable: no code (a lost call), disconnected, timeout, and client_unavailable (Rex fails a
-- waiting request with it when a connection drops; LazyRex docs/rex-protocol.md, "Client RPC").
-- The action may have run, so a caller keeps its intent and replays it (review of 997b1eb, R3).
local unknown_outcome = {unavailable = true, disconnected = true, timeout = true, client_unavailable = true}
local function hub(action, args)
  local response, call_error = rex.call('client.perform', {client_id = hub_id, action = action, args = args or {}, timeout_ms = 10000})
  if type(response) ~= 'table' then
    if type(call_error) == 'table' then
      local table_code = call_error.code or 'unavailable'
      fail(unknown_outcome[table_code] and 'unavailable' or table_code, call_error.message or 'Hub request failed')
    end
    local text = tostring(call_error or 'Hub request failed')
    local code = text:match('code=([%w_]+)%)$')
    if not code or unknown_outcome[code] then fail('unavailable', text) end
    fail(code, text:match('failed: (.-) %(status=%d+ code=[%w_]+%)$') or text)
  end
  if type(response.result) ~= 'table' then fail('internal', 'Invalid hub result for ' .. action) end
  return response.result
end

-- --- Sizes (design v2 section 3; amendment 1, detail 1) ---

-- A rex do script sends at most 64 KiB in one control message (rex-protocol.md). Every request
-- is measured complete, as JSON, before it leaves.
local REQUEST_BUDGET = 48 * 1024
local RUN_BUDGET = 12 * 1024
local PAGE_BUDGET = 40 * 1024
local MAX_NAME, MAX_TEXT, MAX_ERROR, MAX_SUMMARY = 60, 256, 512, 2000
local MAX_INSTRUCTION, MAX_INSTRUCTION_ENCODED, MAX_ARGS_ENCODED = 4000, 8 * 1024, 512
local MAX_TITLE_CHARS = 60

local function size(v) return #rex.json.encode(v) end

-- cut shortens text to at most max bytes, at a UTF-8 boundary, and marks the cut with "…".
local function cut(text, max)
  if #text <= max then return text end
  local n = max - 3
  while n > 0 and text:byte(n + 1) and text:byte(n + 1) >= 0x80 and text:byte(n + 1) < 0xC0 do n = n - 1 end
  return text:sub(1, n) .. '…'
end

local function batch(ops, op)
  local request = {ops = ops, op = op}
  local n = size({type = 'request', id = 'control-0000000000', method = 'client.perform',
    payload = {client_id = hub_id, action = 'hub.store.batch', args = request, timeout_ms = 10000}})
  if n > REQUEST_BUDGET then fail('internal', 'A store batch is ' .. n .. ' bytes encoded; the budget is ' .. REQUEST_BUDGET) end
  return hub('hub.store.batch', request)
end

local function get(keys)
  local records = hub('hub.store.get', {keys = keys}).records or {}
  local out = {}
  for _, key in ipairs(keys) do
    local r = records[key]
    if type(r) ~= 'table' or type(r.rev) ~= 'string' then fail('internal', 'Invalid store record: ' .. key) end
    out[key] = r
  end
  return out
end
local function get1(key) return get({key})[key] end

local function scan(prefix, after, limit)
  local page = hub('hub.store.scan', {prefix = prefix, after = after, limit = limit or 100})
  local keys = {}
  for key in pairs(page.records or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys, page.records or {}, page.next
end

-- canon encodes a value with sorted object keys: the fingerprint of an operation's content.
local function canon(v)
  if type(v) ~= 'table' then return rex.json.encode(v) end
  if next(v) == nil then return '{}' end
  if #v > 0 then
    local out = {}
    for i = 1, #v do out[i] = canon(v[i]) end
    return '[' .. table.concat(out, ',') .. ']'
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = rex.json.encode(k) .. ':' .. canon(v[k]) end
  return '{' .. table.concat(out, ',') .. '}'
end

local function part(value) return tostring(#value) .. ':' .. value end

-- --- Clock and daily slots (design v2 section 7; amendment 1, B4) ---

-- The test manifest can set clock_file (epoch seconds) and tick. Without them: the real clock
-- and a 60 s tick.
local function now()
  local file = rex.args.clock_file
  if type(file) == 'string' and file ~= '' then
    local f = io.open(file, 'r')
    if f then
      local text = f:read('*a')
      f:close()
      local t = tonumber(text)
      if t then return math.floor(t) end
    end
  end
  return os.time()
end
-- wall is the real clock. Retry and recheck times use it, so a step that failed is tried again
-- also while a test holds the test clock still. Schedules, run times and the unknown_start age
-- use now().
local function wall() return os.time() end
local TICK = tonumber(rex.args.tick) or 60
local RECHECK = tonumber(rex.args.recheck) or 300
local UNKNOWN_AFTER = 600

local function day_of(t) return os.date('%Y-%m-%d', t) end

-- instant is the first local minute on date (y, m, d) whose wall time is at or after hh:mm, or
-- nil (the coordinator's rule, 2026-10-20). os.time of a nonexistent local time gives an EARLIER
-- time, and isdst is always false (observed on Rex 0.0.1792158932-g88fd41, lab), so the search
-- steps forward and never reads isdst.
local function instant(y, m, d, hh, mm)
  local want_day = string.format('%04d-%02d-%02d', y, m, d)
  local want_hm = string.format('%02d:%02d', hh, mm)
  local t = os.time({year = y, month = m, day = d, hour = hh, min = mm, sec = 0})
  for _ = 0, 180 do
    local day = os.date('%Y-%m-%d', t)
    if day > want_day then return nil end
    if day == want_day and os.date('%H:%M', t) >= want_hm then return t end
    t = t + 60
  end
  return nil
end

-- slot is the newest date whose instant is at or before t.
local function slot(at, t)
  local hh, mm = tonumber(at:sub(1, 2)), tonumber(at:sub(4, 5))
  local base = os.date('*t', t)
  for back = 0, 2 do
    local noon = os.time({year = base.year, month = base.month, day = base.day - back, hour = 12, min = 0, sec = 0})
    local d = os.date('*t', noon)
    local i = instant(d.year, d.month, d.day, hh, mm)
    if i and i <= t then return day_of(noon) end
  end
  return nil
end

-- --- Validation ---

local function text_arg(v, name, max)
  if type(v) ~= 'string' or v == '' then fail('invalid_input', name .. ' is required') end
  if #v > max then fail('invalid_input', name .. ' is at most ' .. max .. ' bytes') end
  if v:find('%c') then fail('invalid_input', name .. ' has control characters') end
  return v
end

local function only(args, allowed)
  for k in pairs(args) do
    if not allowed[k] then fail('invalid_input', 'Unknown argument: ' .. tostring(k)) end
  end
end

-- watch_path expands a leading ~ with HOME (the hub does not expand it) and requires an
-- absolute, clean path: hub.watch.ensure and hub.spawn {cwd} refuse any other. name is the
-- argument for the error text.
local MAX_PATH = 1024
local function watch_path(p, name)
  name = name or 'trigger.path'
  if p == '~' or p:sub(1, 2) == '~/' then
    local home = os.getenv('HOME')
    if type(home) ~= 'string' or home:sub(1, 1) ~= '/' then fail('invalid_input', 'HOME is not set, so ~ cannot be expanded') end
    if home ~= '/' then home = home:gsub('/+$', '') end
    p = home .. p:sub(2)
  end
  if p:sub(1, 1) ~= '/' then fail('invalid_input', name .. ' is an absolute directory path or starts with ~/') end
  if #p > MAX_PATH then fail('invalid_input', name .. ' is at most ' .. MAX_PATH .. ' bytes') end
  if p ~= '/' and (p:find('//', 1, true) or p:sub(-1) == '/' or (p .. '/'):find('/%.%.?/')) then
    fail('invalid_input', name .. ' must be clean: no //, no /./ or /../ part, no / at the end')
  end
  return p
end

local function check_trigger(t)
  if type(t) ~= 'table' then fail('invalid_input', 'trigger is required') end
  if t.kind == 'file' then
    only(t, {kind = true, path = true, glob = true})
    local path = watch_path(text_arg(t.path, 'trigger.path', MAX_PATH))
    local glob = '*'
    if t.glob ~= nil and t.glob ~= '' then glob = text_arg(t.glob, 'trigger.glob', MAX_TEXT) end
    if glob:find('/', 1, true) then fail('invalid_input', 'trigger.glob matches a file name, so it has no /') end
    return {kind = 'file', path = path, glob = glob}
  end
  if t.kind == 'daily' then
    only(t, {kind = true, at = true})
    local at = t.at
    if type(at) ~= 'string' or not at:match('^%d%d:%d%d$') or tonumber(at:sub(1, 2)) > 23 or tonumber(at:sub(4, 5)) > 59 then
      fail('invalid_input', 'trigger.at is a local time HH:MM, 00:00 to 23:59')
    end
    return {kind = 'daily', at = at}
  end
  fail('invalid_input', 'trigger.kind must be file or daily')
end

-- existing_dir checks the directory with /bin/test -d (argv, no shell). Observed on Rex
-- 0.0.1792158932-g88fd41 (lab, rex do): code 0 for a directory, code 1 for a missing path or a
-- file, and nil plus an error when the program cannot run. Only code 1 is a definite no; any
-- other result is uncertain, so save fails with unavailable and stores nothing. The hub checks
-- the directory again at each start (hub.spawn {cwd}).
local function existing_dir(p)
  local r, err = rex.exec({'/bin/test', '-d', p})
  if type(r) == 'table' and r.code == 0 then return p end
  if type(r) == 'table' and r.code == 1 then fail('invalid_input', 'action.cwd is not an existing directory: ' .. p) end
  fail('unavailable', 'The directory check failed: ' .. tostring(err or (type(r) == 'table' and r.code)))
end

-- check_action validates the profile now: it must exist, be an agent profile, have every
-- required arg, and declare every given arg. The same check runs again at each new start.
local function check_action(a)
  if type(a) ~= 'table' then fail('invalid_input', 'action is required') end
  only(a, {profile = true, args = true, title = true, cwd = true})
  local profile_id = text_arg(a.profile, 'action.profile', 32)
  local profile
  for _, p in ipairs(hub('hub.profiles').profiles or {}) do
    if p.id == profile_id then profile = p end
  end
  if not profile then fail('invalid_input', 'No profile ' .. profile_id) end
  if profile.kind ~= 'agent' then fail('invalid_input', 'Profile ' .. profile_id .. ' is not an agent profile') end
  local given = type(a.args) == 'table' and a.args or {}
  local declared = {}
  for _, arg in ipairs(profile.args or {}) do
    declared[arg.name] = true
    local v = given[arg.name]
    if arg.required and (type(v) ~= 'string' or v == '') and (arg.default or '') == '' then
      fail('invalid_input', 'Profile ' .. profile_id .. ' needs the arg ' .. arg.name)
    end
  end
  local args = {}
  for k, v in pairs(given) do
    if not declared[k] then fail('invalid_input', 'Profile ' .. profile_id .. ' has no arg ' .. tostring(k)) end
    if type(v) ~= 'string' then fail('invalid_input', 'action.args.' .. tostring(k) .. ' is text') end
    if v ~= '' then args[k] = v end
  end
  if next(args) and size(args) > MAX_ARGS_ENCODED then fail('invalid_input', 'action.args is over ' .. MAX_ARGS_ENCODED .. ' bytes encoded') end
  local out = {profile = profile_id}
  if next(args) then out.args = args end
  if a.cwd ~= nil and a.cwd ~= '' then out.cwd = existing_dir(watch_path(text_arg(a.cwd, 'action.cwd', MAX_PATH), 'action.cwd')) end
  if a.title ~= nil and a.title ~= '' then
    out.title = text_arg(a.title, 'action.title', MAX_TEXT)
    -- hub.spawn allows at most 60 characters (Unicode characters; hub workers.go at 06b22ca).
    -- Save checks it, so the first start cannot fail on it (review of 3b2cba7, R2).
    local _, chars = out.title:gsub('[^\128-\191]', '')
    if chars > MAX_TITLE_CHARS then fail('invalid_input', 'action.title is at most ' .. MAX_TITLE_CHARS .. ' characters') end
  end
  return out
end

local function check_instruction(v)
  if type(v) ~= 'string' or v == '' then fail('invalid_input', 'instruction is required') end
  if #v > MAX_INSTRUCTION then fail('invalid_input', 'instruction is at most ' .. MAX_INSTRUCTION .. ' bytes') end
  local n = size(v)
  if n > MAX_INSTRUCTION_ENCODED then fail('invalid_input', 'instruction is ' .. n .. ' bytes encoded; the limit is ' .. MAX_INSTRUCTION_ENCODED) end
  return v
end

-- --- Callers ---

-- Management is open to every caller (decision "Agents may act on anything"). Task access
-- (read, done) belongs to the agent that holds the delivery. caller.ids are every ID of the agent:
-- its identity and the legacy IDs it took over.
local USER = {id = 'user', ids = {'user'}}
-- The SDK identifies an agent caller (hub.identify): ctx.agent and its legacy IDs in ctx.aliases.
local function caller_of(ctx)
  if ctx.user then return USER end
  local ids = {ctx.agent}
  for _, l in ipairs(type(ctx.aliases) == 'table' and ctx.aliases or {}) do
    if type(l) == 'string' and l ~= '' then ids[#ids + 1] = l end
  end
  for _, id in ipairs(ids) do
    if #id > 128 or id:find('[%c/]') then fail('refused', 'An ID of this agent has a slash or control characters, or is over 128 bytes') end
  end
  return {id = ctx.agent, ids = ids}
end
local function holds(caller, agent)
  for _, id in ipairs(caller.ids) do if id == agent then return true end end
  return false
end

-- Operations replay by key. The op key holds the caller ID, so two agents never share one; a
-- replay looks under every ID of the caller.
local function op_key(kind, id, key) return kind .. '/' .. part(id) .. part(key) end
local function replay(kind, caller, key, fingerprint)
  text_arg(key, 'key', 128)
  for _, id in ipairs(caller.ids) do
    local saved = hub('hub.store.op', {key = op_key(kind, id, key)})
    if saved.found then
      if saved.fingerprint ~= nil and saved.fingerprint ~= fingerprint then fail('conflict', 'The key ' .. key .. ' was used for other content') end
      return saved.result
    end
  end
  return nil
end
local function committed(stored, what)
  if stored.op_exists then return stored.op_exists.result end
  if stored.conflict then return nil, stored.conflict end
  if type(stored.revs) ~= 'table' then fail('internal', 'Invalid store result for ' .. what) end
  return stored
end

-- --- Records (design v2 section 2; amendment 1) ---

local function run_prefix(id) return 'run/' .. id .. '/' end
local function queue_key(id, n) return string.format('q/%s/%012d', id, n) end
local function box_key(agent, run_key) return 'box/' .. agent .. '/' .. run_key end
local function delivered_key(id, run_key) return 'dv/' .. id .. '/' .. run_key end

-- The engine's per-automation fence is state/<id>: every batch that creates, starts or delivers
-- a run writes it with if_rev. Every management change (save, set_enabled, delete, retry,
-- cancel_run, dismiss_start) writes it too, so the engine sees gen, enabled, deleted and the
-- schedule baseline of the record that it acts on.
local function state_of(record) return type(record.value) == 'table' and record.value or nil end

-- S.watches: the plugin's watches by key, from the last reconcile (hub.watch.list, then ensure).
-- S.watch_errors: the refused ensure of an automation. S.drain, S.retire and S.sweep: file work
-- that waits for an automation (section 6 below).
local S = {dirty = {}, queue = {}, pumping = false, retry_at = {}, ready = false, reconcile_due = true,
  watches = {}, watch_errors = {}, drain = {}, retire = {}, sweep = {}, prune = {}, dv_after = {}}

-- S.queue holds the automations with work in FIFO order; S.dirty is the set of ids in it. A step
-- with more work goes to the end, so one backlog cannot hold back the others (review of d66cdc5).
local function mark(id)
  if S.dirty[id] then return end
  S.dirty[id] = true
  S.queue[#S.queue + 1] = id
end

-- ui_changed asks the hub to render the plugin's views again, for a change that is not in the
-- store (a watch state, a worker). The hub renders them after each store commit by itself. One
-- request at a time; a failure is only logged.
local function ui_changed()
  if S.ui_pending then return end
  S.ui_pending = true
  rex.after(0, function()
    S.ui_pending = false
    local ok, err = pcall(hub, 'hub.ui.invalidate', {})
    if not ok then print('automations: invalidate: ' .. (type(err) == 'table' and tostring(err.message) or tostring(err))) end
  end)
end
local pump -- forward

local function each_auto(fn)
  local after
  repeat
    local keys, records, next_after = scan('auto/', after, 100)
    for _, key in ipairs(keys) do fn(key:sub(6), records[key]) end
    after = next_after
  until type(after) ~= 'string' or after == ''
end

-- --- Run creation (design v2 section 4) ---

-- create_run commits one run, its queue entry and the state change in one batch. extra(state)
-- changes the state (for example daily_high). It refuses when the state has another gen or is
-- disabled or deleted, so a stale callback makes no run.
local function create_run(id, gen, kind, k, extra, op)
  for _ = 1, 5 do
    local recs = get({'auto/' .. id, 'state/' .. id})
    local auto, st = state_of(recs['auto/' .. id]), state_of(recs['state/' .. id])
    if not auto or not st or st.deleted then return nil, 'not_found' end
    if not st.enabled then return nil, 'disabled' end
    if gen and st.gen ~= gen then return nil, 'stale' end
    local run_key = run_prefix(id) .. kind .. '/' .. k
    local existing = get1(run_key)
    if existing.rev ~= '0' then return run_key, 'exists' end
    local n = (st.next_q or 0) + 1
    local run = {v = 1, auto = id, name = auto.name, kind = kind, by = op and op.by or 'schedule', at = now(),
      task = {instruction = auto.instruction, profile = auto.action.profile, args = auto.action.args, title = auto.action.title, cwd = auto.action.cwd},
      status = 'queued', attempt = 0, starts = 0, q = queue_key(id, n)}
    if kind == 'd' then run.slot = k end
    if size(run) > RUN_BUDGET then fail('internal', 'The run record is over ' .. RUN_BUDGET .. ' bytes encoded') end
    st.next_q = n
    if extra then extra(st) end
    local ops = {{key = run_key, if_rev = '0', value = run}, {key = run.q, if_rev = '0', value = {run = run_key}},
      {key = 'state/' .. id, if_rev = recs['state/' .. id].rev, value = st}}
    local stored = batch(ops, op and op.record)
    local done, conflict = committed(stored, 'a run')
    if done then mark(id); return run_key, 'created', done end
    if conflict.kind ~= 'revision' then fail('conflict', 'The operation key was used for other content') end
  end
  fail('unavailable', 'The automation changed during the run; try again')
end

-- --- Workers ---

-- worker_runs: the spawn row is running (open, with a live process), and its agent is current.
-- A spawned agent that has not joined yet is current too: its box entry waits, and the hub
-- writes the notice when it is ready. So a second run never starts a second worker during a slow
-- join. An identity is current only in state current: after /clear in the pane, the spawn ID's
-- alias stays with the superseded conversation (hub docs, "Agent actions through Rex").
local function worker_runs(worker)
  if type(worker) ~= 'table' then return false end
  local row
  for _, w in ipairs(hub('hub.workers').workers or {}) do
    if w.spawn_id == worker.spawn_id then row = w end
  end
  -- In hub.workers, state is the row's lifecycle (starting, running, exited, failed); status is
  -- the pane's program status, not the spawn row's (hub/cmd/hub/workers.go at 06b22ca).
  if not row or row.state ~= 'running' then return false end
  -- Only a definite answer says that the agent is gone: the hub knows no such agent, or the
  -- identity is not current. Any other failure raises, so the step keeps the worker and tries
  -- again later (review of 3b2cba7, R1). hub.workers and hub.agents raise the same way.
  local ok, resolved = pcall(hub, 'hub.agents.resolve', {to = worker.agent_id})
  if not ok then
    local message = type(resolved) == 'table' and tostring(resolved.message) or tostring(resolved)
    if message:find('no agent matches', 1, true) then return false end
    error(resolved, 0)
  end
  if type(resolved.id) ~= 'string' or resolved.id == '' then fail('internal', 'hub.agents.resolve gave no id') end
  for _, a in ipairs(hub('hub.agents', {all = true}).agents or {}) do
    if a.id == resolved.id then
      if a.legacy then return a.alias_of == nil end
      return a.state == 'current'
    end
  end
  fail('unavailable', 'hub.agents does not list ' .. resolved.id .. ' yet')
end

-- other_box says whether the agent ID has a box entry other than box. A notice row belongs to one
-- agent ID (the hub keeps one per plugin and ID), and each box is keyed by the ID that got the
-- delivery, so the row stays pending exactly while that box is not empty.
local function other_box(agent, box)
  local keys = scan('box/' .. agent .. '/', nil, 2)
  for _, k in ipairs(keys) do
    if k ~= box then return true end
  end
  return false
end

-- deliver_ops: the run becomes delivered to agent, with a new attempt; its box entry and the
-- notice intent commit with it. The queue entry goes; dv/ lists the delivered run.
local function deliver_ops(id, run_key, run_rec, agent, spawn_id)
  local run = run_rec.value
  run.status, run.agent, run.spawn_id = 'delivered', agent, spawn_id
  run.attempt = (run.attempt or 0) + 1
  run.delivered_at = now()
  local q = run.q
  run.q = nil
  return {
    {key = run_key, if_rev = run_rec.rev, value = run},
    {key = q, delete = true},
    {key = delivered_key(id, run_key), value = {agent = agent}},
    {key = box_key(agent, run_key), if_rev = '0', value = {attempt = run.attempt, auto = id}},
    {notify = {agent = agent, pending = true}},
  }
end

local function spawn_request(run_key, starts, task)
  local r = {['for'] = 'user', profile = task.profile, key = 'automations/spawn/' .. run_key .. '/' .. starts}
  if task.args and next(task.args) then r.args = task.args end
  r.title = task.title or nil
  r.cwd = task.cwd or nil
  return r
end

-- spec is what a worker was started with: a run goes to the current worker only when its spec
-- is the same (the coordinator's rule, 2026-10-20: one current worker for each automation).
-- The title is not part of it.
local function spec(task) return canon({profile = task.profile, args = task.args or {}, cwd = task.cwd or ''}) end

-- profile_problem checks a stored task against the current profiles, as save does. It returns
-- the refusal text, or nil. A failed hub.profiles read raises, so the step tries again later.
local function profile_problem(task)
  local ok, err = pcall(check_action, {profile = task.profile, args = task.args, title = task.title})
  if ok then return nil end
  if type(err) == 'table' and err.code == 'invalid_input' then return err.message end
  error(err, 0)
end

-- --- Run retention (design v2 section 10; retention amendment 1) ---

-- Every batch that makes a run terminal takes the next terminal sequence from state.next_t (the
-- batch has the state fence) and writes the index entry t/<id>/<inv> = {run, seq}. inv counts
-- down from MAX_T, so a scan gives the newest first. The order never depends on the clock.
local MAX_T = 999999999999
local function terminal_op(st, id, run_key, run)
  local n = (st.next_t or 0) + 1
  if n > MAX_T then fail('internal', 'Automation ' .. id .. ' has used every terminal sequence') end
  st.next_t = n
  local key = string.format('t/%s/%012d', id, MAX_T - n)
  run.t, run.tseq = key, n
  S.prune[id] = true
  return {key = key, if_rev = '0', value = {run = run_key, seq = n}}
end

-- --- Engine steps (design v2 section 5; amendment 1, B1) ---

-- spawn_step replays the stored spawn request (never a new key) and applies its result.
local function spawn_step(id, st_rec)
  local st = st_rec.value
  local sp = st.spawning
  local run_rec = get1(sp.run)
  if run_rec.rev == '0' then fail('internal', 'The spawning run ' .. sp.run .. ' is missing') end
  local ok, result = pcall(hub, 'hub.spawn', sp.request)
  if not ok then
    local code = type(result) == 'table' and result.code or 'unavailable'
    if code == 'unavailable' then S.retry_at[id] = wall() + RECHECK; return false end
    result = {status = 'failed', error = type(result) == 'table' and result.message or tostring(result)}
  end
  if result.status == 'open' and type(result.agent_id) == 'string' and result.agent_id ~= '' then
    st.worker = {spawn_id = result.spawn_id, agent_id = result.agent_id, spec = spec(run_rec.value.task)}
    st.spawning = nil
    local ops = deliver_ops(id, sp.run, run_rec, result.agent_id, result.spawn_id)
    ops[#ops + 1] = {key = 'state/' .. id, if_rev = st_rec.rev, value = st}
    batch(ops)
    return true
  end
  if result.status == 'pending' then
    local run = run_rec.value
    if run.status == 'starting' and now() - sp.since >= UNKNOWN_AFTER then
      run.status = 'unknown_start'
      batch({{key = sp.run, if_rev = run_rec.rev, value = run}})
    end
    S.retry_at[id] = wall() + RECHECK
    return false
  end
  local run = run_rec.value
  -- A start that the hub never sent (hub Fix A) created nothing, so the plugin starts it again
  -- once with a new key: one retry per start admission, never after a delete. Only a stored
  -- failed result counts, never a call error. The run and the new request commit in one batch
  -- before the new key is sent.
  local err = result.status == 'failed' and result.error
  if ok and type(err) == 'string' and (err == 'not_created' or err:sub(1, 12) == 'not_created:') and not sp.auto and not st.deleted then
    local problem = profile_problem(run.task)
    if not problem then
      run.starts = (run.starts or 0) + 1
      run.restarted = sp.request.key
      -- A new start: also a run that was unknown_start is starting again.
      run.status = 'starting'
      st.spawning = {run = sp.run, since = now(), request = spawn_request(sp.run, run.starts, run.task), auto = true}
      batch({{key = sp.run, if_rev = run_rec.rev, value = run}, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}})
      return true
    end
    result.error = problem
  end
  run.status = 'failed'
  run.error = cut(tostring(result.error or ('The start ended as ' .. tostring(result.status))), MAX_ERROR)
  local q = run.q
  run.q = nil
  st.spawning = nil
  local t_op = terminal_op(st, id, sp.run, run)
  batch({{key = sp.run, if_rev = run_rec.rev, value = run}, {key = q, delete = true}, t_op, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}})
  return true
end

-- requeue_ops: a delivered run whose worker no longer runs goes back to the queue (design v2,
-- 5e). Its box entry goes, and the old agent's notice row follows its remaining box. The run
-- keeps its attempt, so the next delivery has attempt + 1 and a done of the old attempt is
-- refused. It also keeps starts: a later start uses a new key.
local function requeue_ops(id, st, run_key, run_rec)
  local run = run_rec.value
  local box = box_key(run.agent, run_key)
  local n = (st.next_q or 0) + 1
  st.next_q = n
  run.lost = {agent = run.agent, spawn_id = run.spawn_id, attempt = run.attempt, at = now()}
  local agent = run.agent
  run.status, run.agent, run.spawn_id, run.delivered_at = 'queued', nil, nil, nil
  run.q = queue_key(id, n)
  return {
    {key = run_key, if_rev = run_rec.rev, value = run},
    {key = run.q, if_rev = '0', value = {run = run_key}},
    {key = delivered_key(id, run_key), delete = true},
    {key = box, delete = true},
    {notify = {agent = agent, pending = other_box(agent, box)}},
  }
end

-- lost_ops: after a delete, a lost worker's run is cancelled, not requeued (B3): no new worker
-- starts for a deleted automation. Its box entry and the notice change in the same batch.
local function lost_ops(id, st, run_key, run_rec)
  if not st.deleted then return requeue_ops(id, st, run_key, run_rec) end
  local run = run_rec.value
  local agent = run.agent
  local box = box_key(agent, run_key)
  run.lost = {agent = agent, spawn_id = run.spawn_id, attempt = run.attempt, at = now()}
  run.status, run.error = 'cancelled', 'worker lost after delete'
  return {
    terminal_op(st, id, run_key, run),
    {key = run_key, if_rev = run_rec.rev, value = run},
    {key = delivered_key(id, run_key), delete = true},
    {key = box, delete = true},
    {notify = {agent = agent, pending = other_box(agent, box)}},
  }
end

-- lost_step requeues one delivered run whose worker is gone (after a delete it cancels it). A
-- run of an older worker (an action change starts a new current worker) is checked against its
-- own spawn: that worker finishes the tasks that it has. When the current worker definitely does
-- not run, it is forgotten. An uncertain observation raises (worker_runs), so nothing is
-- requeued on a guess.
-- The scan goes one page at a time from S.dv_after[id] and wraps at the end, so a page of live
-- tasks never hides a later lost one (review of the 6a plan, point 2). A page with a requeue or a
-- repair is read again by the next step. It returns nil when the page has no lost run.
local DV_PAGE = 20
local function lost_step(id, st_rec)
  local st = st_rec.value
  local prefix = 'dv/' .. id .. '/'
  local keys, _, more = scan(prefix, S.dv_after[id], DV_PAGE)
  if #keys == 0 then S.dv_after[id] = nil; return nil end
  local current = type(st.worker) == 'table' and st.worker.spawn_id or nil
  local seen = {}
  for _, key in ipairs(keys) do
    local run_key = key:sub(#prefix + 1)
    local run_rec = get1(run_key)
    if run_rec.rev == '0' or run_rec.value.status ~= 'delivered' then
      -- An index entry whose run is not delivered. done and requeue delete the entry in their
      -- own batch, so this is only a repair: remove it under the fence.
      batch({{key = key, delete = true}, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}})
      return true
    end
    local run = run_rec.value
    local sid = tostring(run.spawn_id)
    if seen[sid] == nil then
      if run.spawn_id == current then seen[sid] = worker_runs(st.worker)
      else seen[sid] = worker_runs({spawn_id = run.spawn_id, agent_id = run.agent}) end
    end
    if not seen[sid] then
      if run.spawn_id == current then st.worker = nil end
      local ops = lost_ops(id, st, run_key, run_rec)
      ops[#ops + 1] = {key = 'state/' .. id, if_rev = st_rec.rev, value = st}
      batch(ops)
      return true
    end
  end
  if type(more) == 'string' and more ~= '' then S.dv_after[id] = keys[#keys] else S.dv_after[id] = nil end
  return nil
end

-- --- File watches (design v2 section 6; amendment 1, B1 and B2) ---

-- Each trigger generation has its own watch key, so a changed trigger never meets the old spec
-- (watch_conflict). settle_ms is fixed per plugin run: a test sets it short (manifest).
local SETTLE_MS = tonumber(rex.args.settle_ms) or 1000
local WATCH_PAGE = 50
local function watch_key(id, gen) return 'a-' .. id .. '-' .. tostring(gen) end
local function watch_owner(key) return key:match('^a%-(%d+)%-%d+$') end
-- The marker seen/<id>/<appearance_key> = {run} is the proof that an appearance has its run.
-- rt/<id>/<appearance_key> = {seq} says that a removed or created_removed row of it was read.
local function marker_key(id, ak) return 'seen/' .. id .. '/' .. ak end
local function retire_key(id, ak) return 'rt/' .. id .. '/' .. ak end
-- appearance_key is watch_id:created_seq, and a watch_id is hex (hub watchsvc.go at 06b22ca).
local function appearance_watch(ak) return ak:match('^(%x+):%d+$') end

local function drain_later(id)
  S.drain[id] = (S.drain[id] or 0) + 1
  mark(id)
end

local function desired_watches()
  local out = {}
  each_auto(function(id, rec)
    local auto = rec.value
    if type(auto) == 'table' and auto.enabled and not auto.deleted and auto.trigger.kind == 'file' then
      out[watch_key(id, auto.gen)] = {id = id, path = auto.trigger.path, glob = auto.trigger.glob}
    end
  end)
  return out
end

-- reconcile makes the hub's watches match the enabled file automations. It removes every watch
-- whose key is not desired first, by its exact watch_id, so the 8-watch limit counts only
-- desired watches. Then it ensures each desired watch: the same spec gives the same watch_id, so
-- a lost reply is safe. It keeps no watch_id across runs; a crash repeats it from the list.
local function reconcile()
  local listed = hub('hub.watch.list').watches or {}
  local want = desired_watches()
  local watches = {}
  for _, w in ipairs(listed) do
    if want[w.key] then
      watches[w.key] = w
    else
      hub('hub.watch.remove', {key = w.key, watch_id = w.watch_id})
      -- The rows of the removed watch cannot come again, so its markers retire (B2, rule 2).
      local owner = watch_owner(w.key)
      if owner then S.sweep[owner] = true; mark(owner) end
    end
  end
  local keys = {}
  for key in pairs(want) do keys[#keys + 1] = key end
  table.sort(keys)
  local errors = {}
  for _, key in ipairs(keys) do
    local d = want[key]
    local ok, w = pcall(hub, 'hub.watch.ensure', {key = key, path = d.path, glob = d.glob, settle_ms = SETTLE_MS, emit_existing = false})
    if ok then
      local row = watches[key] or {key = key, path = d.path, glob = d.glob}
      row.watch_id, row.state, row.cursor, row.watermark = w.watch_id, w.state, w.cursor, w.watermark
      watches[key] = row
      drain_later(d.id)
    else
      if type(w) ~= 'table' or w.code == 'unavailable' then error(w, 0) end
      errors[d.id] = {code = w.code, message = cut(tostring(w.message), MAX_ERROR)}
    end
  end
  local sig = {}
  for key, w in pairs(watches) do sig[key] = tostring(w.state) end
  for id, e in pairs(errors) do sig['error/' .. id] = e.code .. ':' .. e.message end
  S.watches = watches
  S.watch_errors = errors
  local text = canon(sig)
  if text ~= S.watch_sig then S.watch_sig = text; ui_changed() end
end

-- file_run builds the run of a created row. A row whose run would pass the run budget gives a
-- failed run without the path (amendment 1, detail 1); it still has its marker.
local function file_run(id, auto, row, n)
  local run = {v = 1, auto = id, name = auto.name, kind = 'f', by = 'watch', at = now(),
    item = {name = row.name, path = row.path, seq = row.seq, watch_id = appearance_watch(row.appearance_key)},
    task = {instruction = auto.instruction, profile = auto.action.profile, args = auto.action.args, title = auto.action.title, cwd = auto.action.cwd},
    status = 'queued', attempt = 0, starts = 0, q = queue_key(id, n)}
  if size(run) <= RUN_BUDGET then return run end
  run.item = {seq = row.seq, watch_id = run.item.watch_id, path_bytes = #tostring(row.path), name = cut(tostring(row.name), MAX_TEXT)}
  run.status, run.error, run.q = 'failed', 'path too long', nil
  return run
end

-- commit_ops sends the collected ops of a page with the state fence. It returns false when the
-- state changed (a save or another step): the page is read again later.
local function commit_ops(id, B)
  if #B.ops == 0 then return true end
  B.st.next_q = B.next_q
  B.ops[#B.ops + 1] = {key = 'state/' .. id, if_rev = B.rev, value = B.st}
  local stored = batch(B.ops)
  B.ops, B.used = {}, 1024
  if stored.conflict then return false end
  if type(stored.revs) ~= 'table' or type(stored.revs['state/' .. id]) ~= 'string' then fail('internal', 'Invalid store result for a watch page') end
  B.rev = stored.revs['state/' .. id]
  return true
end

local function add_ops(id, B, ops)
  local n = 0
  for _, op in ipairs(ops) do n = n + size(op) + 1 end
  if B.used + n > REQUEST_BUDGET - 2048 and not commit_ops(id, B) then return false end
  for _, op in ipairs(ops) do B.ops[#B.ops + 1] = op end
  B.used = B.used + n
  return true
end

-- drain_step reads one page of the automation's desired watch. A created row without a marker
-- gets its run and marker (if_rev '0' on both). A removed or created_removed row of a marked
-- appearance gets its rt entry. The ack (through = next) follows only when every op committed.
local function drain_step(id)
  local asked = S.drain[id]
  local recs = get({'auto/' .. id, 'state/' .. id})
  local auto, st_rec = state_of(recs['auto/' .. id]), recs['state/' .. id]
  local st = state_of(st_rec)
  if not auto or not st or st.deleted or not st.enabled or auto.trigger.kind ~= 'file' then S.drain[id] = nil; return false end
  local key = watch_key(id, st.gen)
  local w = S.watches[key]
  -- No known watch: the reconcile ensures it and asks for the drain again.
  if not w then S.drain[id] = nil; S.reconcile_due = true; return false end
  local ok, page = pcall(hub, 'hub.watch.read', {key = key, watch_id = w.watch_id, limit = WATCH_PAGE})
  if not ok then
    if type(page) == 'table' and page.code == 'stale_watch' then
      S.watches[key] = nil
      S.drain[id] = nil
      S.reconcile_due = true
      return false
    end
    error(page, 0)
  end
  if w.state ~= page.state then ui_changed() end
  w.state = page.state
  local rows = page.rows or {}
  local mkeys = {}
  for _, row in ipairs(rows) do
    if type(row.appearance_key) ~= 'string' or appearance_watch(row.appearance_key) ~= w.watch_id then
      fail('internal', 'A watch row has no valid appearance_key')
    end
    mkeys[#mkeys + 1] = marker_key(id, row.appearance_key)
  end
  local markers = #mkeys > 0 and get(mkeys) or {}
  local B = {ops = {}, used = 1024, rev = st_rec.rev, st = st, next_q = st.next_q or 0}
  for _, row in ipairs(rows) do
    local mk = marker_key(id, row.appearance_key)
    if row.kind == 'created' and markers[mk].rev == '0' then
      local run_key = run_prefix(id) .. 'f/' .. row.appearance_key
      local n = B.next_q + 1
      local run = file_run(id, auto, row, n)
      local ops = {{key = run_key, if_rev = '0', value = run}, {key = mk, if_rev = '0', value = {run = run_key}}}
      if run.q then ops[#ops + 1] = {key = run.q, if_rev = '0', value = {run = run_key}} end
      if run.status == 'failed' then ops[#ops + 1] = terminal_op(B.st, id, run_key, run) end
      -- add_ops may first commit the earlier ops, with the earlier next_q.
      if not add_ops(id, B, ops) then return true end
      if run.q then B.next_q = n end
      markers[mk] = {rev = 'new'}
    elseif (row.kind == 'removed' or row.kind == 'created_removed') and markers[mk].rev ~= '0' then
      if not add_ops(id, B, {{key = retire_key(id, row.appearance_key), value = {seq = row.seq}}}) then return true end
    end
  end
  if not commit_ops(id, B) then return true end
  if type(page.next) == 'string' and page.next ~= '' then
    -- The page's runs and markers committed, so a failed ack loses nothing: the rows come again,
    -- and the markers stop a second run. The drain stops here, so the engine can deliver; the
    -- recheck tick drains again.
    local ok_ack, acked = pcall(hub, 'hub.watch.ack', {key = key, watch_id = w.watch_id, through = page.next})
    if not ok_ack then
      print('automations: ack ' .. key .. ': ' .. (type(acked) == 'table' and tostring(acked.message) or tostring(acked)))
      if type(acked) == 'table' and acked.code == 'stale_watch' then S.watches[key] = nil; S.reconcile_due = true end
      S.drain[id] = nil
      return true
    end
    w.cursor = acked.cursor
    S.retire[id] = S.retire[id] or true
  end
  if page.more then return true end
  if S.drain[id] == asked then S.drain[id] = nil end
  return true
end

-- retire_step deletes each marker whose removal row is acknowledged: its rt seq is at or below
-- the watch's cursor. Then the hub has deleted that tombstone, and a new file of that name gets a
-- new created_seq (docs/hub.md, "Rows and kinds"). After a crash between the ack and the
-- delete, the cursor still proves it.
local function retire_step(id)
  local prefix = 'rt/' .. id .. '/'
  local after = type(S.retire[id]) == 'string' and S.retire[id] or nil
  local keys, records, more = scan(prefix, after, WATCH_PAGE)
  local cursors = {}
  for _, w in pairs(S.watches) do cursors[w.watch_id] = tonumber(w.cursor) end
  local ops = {}
  for _, k in ipairs(keys) do
    local ak = k:sub(#prefix + 1)
    local cursor = cursors[appearance_watch(ak) or '']
    local seq = type(records[k].value) == 'table' and tonumber(records[k].value.seq) or nil
    if cursor and seq and seq <= cursor then
      ops[#ops + 1] = {key = marker_key(id, ak), delete = true}
      ops[#ops + 1] = {key = k, delete = true}
    end
  end
  if #ops > 0 then batch(ops) end
  if #keys > 0 and type(more) == 'string' and more ~= '' then S.retire[id] = keys[#keys]; return true end
  S.retire[id] = nil
  return #ops > 0
end

-- sweep_step deletes the markers (and rt entries) of watches that the hub no longer lists
-- (B2, rule 2). Steps run one at a time, so no drain makes a marker between the list and the
-- delete.
local function sweep_step(id)
  local live = {}
  for _, w in ipairs(hub('hub.watch.list').watches or {}) do live[w.watch_id] = true end
  local prefix = 'seen/' .. id .. '/'
  local after = type(S.sweep[id]) == 'string' and S.sweep[id] or nil
  local keys, _, more = scan(prefix, after, WATCH_PAGE)
  local ops = {}
  for _, k in ipairs(keys) do
    local ak = k:sub(#prefix + 1)
    if not live[appearance_watch(ak) or ''] then
      ops[#ops + 1] = {key = k, delete = true}
      ops[#ops + 1] = {key = retire_key(id, ak), delete = true}
    end
  end
  if #ops > 0 then batch(ops) end
  if #keys > 0 and type(more) == 'string' and more ~= '' then S.sweep[id] = keys[#keys]; return true end
  S.sweep[id] = nil
  return #ops > 0
end

-- --- Delete cleanup (amendment 1, B3; the coordinator's decision, 2026-10-20: a delete also
-- deletes the run history) ---

local CLEANUP_RUNS, CLEANUP_KEYS = 20, 50

-- fenced is a batch of independent ops that ends with the state fence. fits adds ops while the
-- complete encoded batch stays in the budget; the counts are only upper bounds.
local function fenced(id, st_rec)
  local fence = {key = 'state/' .. id, if_rev = st_rec.rev, value = st_rec.value}
  return {ops = {}, used = 1024 + size(fence) + 1, fence = fence, n = 0}
end
local function fits(B, ops)
  local n = 0
  for _, op in ipairs(ops) do n = n + size(op) + 1 end
  if B.used + n > REQUEST_BUDGET - 2048 then return false end
  for _, op in ipairs(ops) do B.ops[#B.ops + 1] = op end
  B.used = B.used + n
  B.n = B.n + 1
  return true
end
local function send_fenced(B)
  B.ops[#B.ops + 1] = B.fence
  batch(B.ops)
end

-- cancel_step cancels the queued runs of a deleted automation, one batch for each step. A queue
-- entry of a starting or unknown_start run stays: that run continues (design v2, 5f). It returns
-- nil when no queued run is left.
local function cancel_step(id, st_rec)
  local keys, records = scan('q/' .. id .. '/', nil, CLEANUP_RUNS + 1)
  if #keys == 0 then return nil end
  local run_keys = {}
  for _, key in ipairs(keys) do run_keys[#run_keys + 1] = records[key].value.run end
  local runs = get(run_keys)
  local B = fenced(id, st_rec)
  for i, key in ipairs(keys) do
    local run_rec = runs[run_keys[i]]
    if run_rec.rev ~= '0' and run_rec.value.status == 'queued' then
      local run = run_rec.value
      run.status, run.error, run.q = 'cancelled', 'automation deleted', nil
      if B.n >= CLEANUP_RUNS then break end
      -- A run that does not fit keeps its sequence unused: a gap, never a reuse.
      local t_op = terminal_op(st_rec.value, id, run_keys[i], run)
      if not fits(B, {{key = run_keys[i], if_rev = run_rec.rev, value = run}, {key = key, delete = true}, t_op}) then break end
    end
  end
  if B.n == 0 then return nil end
  send_fenced(B)
  return true
end

-- purge_step deletes the records of a deleted automation when no run is active: markers, rt
-- entries, queue entries left over, and the terminal runs. The last batch deletes the state and
-- the auto tombstone.
local PURGE = {'seen/', 'rt/', 'q/', 't/', 'run/'}
local ACTIVE = {queued = true, starting = true, unknown_start = true, delivered = true}
local function purge_step(id, st_rec)
  for _, p in ipairs(PURGE) do
    local prefix = p .. id .. '/'
    local keys, records = scan(prefix, nil, CLEANUP_KEYS)
    if #keys > 0 then
      local B = fenced(id, st_rec)
      for _, key in ipairs(keys) do
        local v = records[key].value
        if p == 'run/' and type(v) == 'table' and ACTIVE[v.status] then fail('internal', 'Run ' .. key .. ' is ' .. v.status .. ' after the cleanup') end
        if not fits(B, {{key = key, delete = true}}) then break end
      end
      send_fenced(B)
      return true
    end
  end
  batch({{key = 'state/' .. id, if_rev = st_rec.rev, delete = true}, {key = 'auto/' .. id, delete = true}})
  return false
end

-- prune_step keeps the newest KEEP_RUNS terminal runs. It reads state/<id> first: every change of
-- the terminal set (a terminal change, a retry) writes it, and the prune batch writes it back
-- unchanged with the observed rev. So a change after the read makes the batch fail, and the next
-- step computes the cutoff again (review of 451691c, R1). Then it reads the entries after the newest
-- KEEP_RUNS (the scan gives each entry's rev) and gets their runs. A run whose run.t is that
-- entry and that is terminal goes with its entry; any other entry is stale and goes alone. Each
-- delete has the observed rev, so a run that a retry made active, or a changed entry, stays: the
-- batch commits nothing, and a later step reads again. Markers are never touched (B2).
local KEEP_RUNS, PRUNE_PAGE = 100, 50
local TERMINAL = {done = true, failed = true, cancelled = true, dismissed = true}
local function prune_step(id)
  local prefix = 't/' .. id .. '/'
  local st_rec = get1('state/' .. id)
  if not state_of(st_rec) then S.prune[id] = nil; return false end
  local keep, _, more = scan(prefix, nil, KEEP_RUNS)
  if #keep < KEEP_RUNS or type(more) ~= 'string' or more == '' then S.prune[id] = nil; return false end
  local old, records = scan(prefix, keep[#keep], PRUNE_PAGE)
  if #old == 0 then S.prune[id] = nil; return false end
  local run_keys, seen = {}, {}
  for _, k in ipairs(old) do
    local v = records[k].value
    local rk = type(v) == 'table' and v.run or nil
    if type(rk) == 'string' and rk:sub(1, #run_prefix(id)) == run_prefix(id) and not seen[rk] then
      seen[rk] = true
      run_keys[#run_keys + 1] = rk
    end
  end
  local runs = #run_keys > 0 and get(run_keys) or {}
  local B = fenced(id, st_rec)
  for _, k in ipairs(old) do
    local v = records[k].value
    local rr = type(v) == 'table' and runs[v.run] or nil
    local ops = {{key = k, if_rev = records[k].rev, delete = true}}
    if rr and rr.rev ~= '0' and type(rr.value) == 'table' and rr.value.t == k and TERMINAL[rr.value.status] then
      ops[2] = {key = v.run, if_rev = rr.rev, delete = true}
    end
    if not fits(B, ops) then break end
  end
  send_fenced(B)
  return true
end

-- step does one unit of work for one automation and says whether more work may follow now.
-- File work comes first: it only creates runs and deletes markers, so it never waits on a start.
-- Each file stage clears its flag when it ends, and a later step does the engine work.
local function step(id)
  if S.drain[id] then drain_step(id); return true end
  if S.retire[id] then retire_step(id); return true end
  if S.sweep[id] then sweep_step(id); return true end
  if S.prune[id] then prune_step(id); return true end
  local st_rec = get1('state/' .. id)
  local st = state_of(st_rec)
  if not st then return false end
  -- After a delete: queued runs are cancelled first. A pending start still replays and delivers
  -- its run, and a delivered run stays until done or a worker loss. Then the records go.
  if st.deleted then
    local cancelled = cancel_step(id, st_rec)
    if cancelled ~= nil then return cancelled end
  end
  if st.spawning then return spawn_step(id, st_rec) end
  local lost = lost_step(id, st_rec)
  if lost ~= nil then return lost end
  if st.deleted then
    if #scan('dv/' .. id .. '/', nil, 1) > 0 then return S.dv_after[id] ~= nil end
    return purge_step(id, st_rec)
  end
  local keys, records = scan('q/' .. id .. '/', nil, 1)
  -- A delivered-run pass that is not at its end continues in the next step.
  if #keys == 0 then return S.dv_after[id] ~= nil end
  local run_key = records[keys[1]].value.run
  local run_rec = get1(run_key)
  if run_rec.rev == '0' or run_rec.value.status ~= 'queued' then fail('internal', 'Queue entry ' .. keys[1] .. ' names no queued run') end
  if type(st.worker) == 'table' and st.worker.spec == spec(run_rec.value.task) and worker_runs(st.worker) then
    local ops = deliver_ops(id, run_key, run_rec, st.worker.agent_id, st.worker.spawn_id)
    ops[#ops + 1] = {key = 'state/' .. id, if_rev = st_rec.rev, value = st}
    batch(ops)
    return true
  end
  -- Start admission: a new start counter gives a new key; the request is stored before the call.
  -- The profile can change after save, so a new start checks it again (design v2, 5d). A replay
  -- in spawn_step does not: its earlier effect may already exist.
  local run = run_rec.value
  local problem = profile_problem(run.task)
  if problem then
    run.status = 'failed'
    run.error = cut(problem, MAX_ERROR)
    local q = run.q
    run.q = nil
    local t_op = terminal_op(st, id, run_key, run)
    batch({{key = run_key, if_rev = run_rec.rev, value = run}, {key = q, delete = true}, t_op, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}})
    return true
  end
  run.starts = (run.starts or 0) + 1
  run.status = 'starting'
  st.spawning = {run = run_key, since = now(), request = spawn_request(run_key, run.starts, run.task)}
  batch({{key = run_key, if_rev = run_rec.rev, value = run}, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}})
  return true
end

-- pump runs one step per callback, so hub requests and other callbacks do not wait long.
-- The reconcile runs as a pump job too, so it never runs between the list and the delete of a
-- sweep step.
pump = function()
  if S.pumping or not S.ready then return end
  local t = wall()
  if S.reconcile_due and (not S.reconcile_at or S.reconcile_at <= t) then
    S.pumping = true
    S.reconcile_due = false
    rex.after(0, function()
      local ok, err = pcall(reconcile)
      if not ok then
        print('automations: reconcile: ' .. (type(err) == 'table' and tostring(err.message) or tostring(err)))
        S.reconcile_due = true
        S.reconcile_at = wall() + RECHECK
      end
      S.pumping = false
      pump()
    end)
    return
  end
  -- One pass over the queue: an id that waits for its retry time goes to the end, and the first
  -- ready id is taken.
  local id
  for _ = 1, #S.queue do
    local candidate = table.remove(S.queue, 1)
    if not S.retry_at[candidate] or S.retry_at[candidate] <= t then id = candidate break end
    S.queue[#S.queue + 1] = candidate
  end
  if not id then return end
  S.pumping = true
  S.dirty[id] = nil
  S.retry_at[id] = nil
  rex.after(0, function()
    local ok, more = pcall(step, id)
    if not ok then
      print('automations: step ' .. id .. ': ' .. (type(more) == 'table' and tostring(more.message) or tostring(more)))
      S.retry_at[id] = wall() + RECHECK
      mark(id)
    elseif more or S.retry_at[id] then
      mark(id)
    end
    S.pumping = false
    pump()
  end)
end

-- --- Schedule tick ---

local function tick()
  local t = now()
  each_auto(function(id, rec)
    local auto = rec.value
    if type(auto) == 'table' and auto.enabled and not auto.deleted and auto.trigger.kind == 'daily' then
      local s = slot(auto.trigger.at, t)
      local st = state_of(get1('state/' .. id))
      if s and st and s > (st.daily_high or '') and s > (st.daily_base or '') then
        create_run(id, st.gen, 'd', s, function(state) state.daily_high = s end)
      end
    end
  end)
  -- Due rechecks (a pending spawn), every automation with work, the watch reconcile and a drain
  -- of every desired watch (the reconcile asks for them): the recheck interval.
  if not S.last_sweep or wall() - S.last_sweep >= RECHECK then
    S.last_sweep = wall()
    S.reconcile_due = true
    each_auto(function(id) mark(id); S.prune[id] = true end)
  end
  pump()
end

-- --- Exports (design v2 section 9) ---

local function next_id()
  local rec = get1('meta/next_id')
  local n = (rec.rev ~= '0' and tonumber(rec.value.n) or 0) + 1
  return tostring(n), {key = 'meta/next_id', if_rev = rec.rev, value = {n = n}}
end

-- The hub allows 8 watches per plugin, one for each enabled file automation.
local function check_file_limit(except_id)
  local others = {n = 0}
  each_auto(function(id, rec)
    local a = rec.value
    if id ~= except_id and type(a) == 'table' and a.enabled and not a.deleted and a.trigger.kind == 'file' then others.n = others.n + 1 end
  end)
  if others.n >= 8 then fail('limit', 'At most 8 enabled file automations are possible (the hub allows 8 watches per plugin)') end
end

-- Presets (the coordinator's accepted texts, 2026-10-20). A preset is a set of default fields; the
-- user chooses the profile. preset/<name> = {id} says which automation installed it: a create
-- with a preset writes it with if_rev '0' in the save batch, so a preset installs once. An edit
-- keeps the preset. The delete fence deletes the record only when it names that automation.
local PRESET_NAMES = {'vault-inbox', 'vault-health'}
local PRESETS = {
  ['vault-inbox'] = {name = 'Vault inbox', trigger = {kind = 'file', path = '~/knowledge/inbox', glob = '*.md'}, cwd = '~/knowledge',
    about = 'A run for each new note in ~/knowledge/inbox.',
    instruction = 'A new note arrived in the vault inbox. The task item has its name and path. Process it as this repository\'s instructions say. The same note can come again in a later run: if it is already processed, skip it. Call automations_done when you finish.'},
  ['vault-health'] = {name = 'Vault health', trigger = {kind = 'daily', at = '22:00'}, cwd = '~/knowledge',
    about = 'A run every day at 22:00 in ~/knowledge.',
    instruction = 'The nightly vault health check is due. Run it as this repository\'s instructions say, and report the results. This run can come again: if tonight\'s check is already done, say so. Call automations_done when you finish.'},
}
local function preset_key(name) return 'preset/' .. name end

local function save(caller, args)
  only(args, {id = true, if_rev = true, key = true, name = true, enabled = true, trigger = true, action = true, instruction = true, preset = true})
  local content = {}
  for k, v in pairs(args) do if k ~= 'key' then content[k] = v end end
  local fingerprint = 'save-v1/' .. canon(content)
  local prior = replay('save', caller, args.key, fingerprint)
  if prior then return prior end
  if args.preset ~= nil and (type(args.preset) ~= 'string' or not PRESETS[args.preset]) then
    fail('invalid_input', 'preset is ' .. table.concat(PRESET_NAMES, ' or '))
  end
  local name = text_arg(args.name, 'name', MAX_NAME)
  local trigger = check_trigger(args.trigger)
  local action = check_action(args.action)
  local instruction = check_instruction(args.instruction)
  local enabled = args.enabled ~= false
  if enabled and trigger.kind == 'file' then check_file_limit(args.id) end
  local t = now()
  for _ = 1, 5 do
    local id, meta_op, auto_rev, old, st_rec = args.id, nil, '0', nil, nil
    if id == nil then
      local new_id, new_meta = next_id()
      id = new_id
      meta_op = new_meta
      st_rec = {rev = '0'}
    else
      text_arg(id, 'id', 32)
      if type(args.if_rev) ~= 'string' then fail('invalid_input', 'if_rev is required to change an automation') end
      local recs = get({'auto/' .. id, 'state/' .. id})
      old = state_of(recs['auto/' .. id])
      st_rec = recs['state/' .. id]
      if not old or (state_of(st_rec) or {}).deleted then fail('not_found', 'No automation ' .. id) end
      if recs['auto/' .. id].rev ~= args.if_rev then fail('conflict', 'Automation ' .. id .. ' is at rev ' .. recs['auto/' .. id].rev) end
      if args.preset ~= nil and args.preset ~= old.preset then fail('invalid_input', 'Automation ' .. id .. ' is not from preset ' .. args.preset) end
      auto_rev = args.if_rev
    end
    local preset = old and old.preset or args.preset
    local st = state_of(st_rec) or {v = 1, gen = 0, next_q = 0, next_manual = 0}
    local trigger_changed = not old or canon(old.trigger) ~= canon(trigger)
    local enabling = enabled and (not old or not old.enabled)
    if trigger_changed or (old and old.enabled ~= enabled) then st.gen = (st.gen or 0) + 1 end
    st.enabled = enabled
    -- The baseline moves only on create, enable, a change to daily and a time change (B4). An
    -- unrelated save keeps a due catch-up. daily_high is never cleared.
    if trigger.kind == 'daily' and enabled and (trigger_changed or enabling) then st.daily_base = slot(trigger.at, t) or '' end
    local auto = {v = 1, id = id, name = name, enabled = enabled, gen = st.gen, trigger = trigger, action = action,
      instruction = instruction, preset = preset, by = old and old.by or caller.id, created_at = old and old.created_at or t, updated_at = t}
    local ops = {{key = 'auto/' .. id, if_rev = auto_rev, value = auto}, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}}
    if meta_op then ops[#ops + 1] = meta_op end
    if preset and not old then ops[#ops + 1] = {key = preset_key(preset), if_rev = '0', value = {id = id}} end
    local stored = batch(ops, {key = op_key('save', caller.id, args.key), fingerprint = fingerprint, result = {id = id},
      result_revs = {rev = 'auto/' .. id}})
    local result, conflict = committed(stored, 'a save')
    if result then
      if result.op_exists == nil and result.revs then result = {id = id, rev = result.revs['auto/' .. id]} end
      mark(id)
      S.reconcile_due = true
      S.reconcile_at = nil
      pump()
      return result
    end
    if conflict.kind == 'operation' then fail('conflict', 'The key ' .. args.key .. ' was used for other content') end
    if conflict.key == 'auto/' .. id and args.id then fail('conflict', 'Automation ' .. id .. ' is at rev ' .. tostring(conflict.rev)) end
    if preset and conflict.key == preset_key(preset) then
      local installed = state_of(get1(preset_key(preset)))
      fail('conflict', 'Preset ' .. preset .. ' is installed as automation ' .. tostring(installed and installed.id or '(unknown)'))
    end
  end
  fail('unavailable', 'The automations changed during the save; try again')
end

-- watch_view is the watch state of an enabled file automation: the hub's state of its watch, or
-- the error of its refused ensure, or pending (the reconcile has not run yet).
local GRANT_HINT = 'Add the directory, or a parent, to plugins[automations].watch_roots in the hub config, then restart the hub.'
local function watch_view(id, w)
  local view
  if w then
    view = {state = w.state}
    if type(w.last_error) == 'string' and w.last_error ~= '' then view.error = cut(w.last_error, MAX_ERROR) end
  elseif S.watch_errors[id] then
    view = {state = 'refused', code = S.watch_errors[id].code, error = S.watch_errors[id].message}
  else
    view = {state = 'pending'}
  end
  if view.state == 'not_granted' or view.code == 'watch_not_granted' then view.hint = GRANT_HINT end
  return view
end

local function list(_, args)
  only(args, {after = true, limit = true, deleted = true})
  if args.after ~= nil then text_arg(args.after, 'after', 64) end
  if args.deleted ~= nil and type(args.deleted) ~= 'boolean' then fail('invalid_input', 'deleted is true or false') end
  local limit = args.limit or 50
  if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > 50 then fail('invalid_input', 'limit is an integer from 1 to 50') end
  -- next is the last key that the page consumed, also a deleted one: scan's after is exclusive.
  -- A visible record that does not fit is not consumed, so the next page starts with it.
  local out, used, next_after, last = {}, 64, nil, args.after
  local keys, records, more = scan('auto/', args.after, limit)
  local listed = {}
  for _, w in ipairs(hub('hub.watch.list').watches or {}) do listed[w.key] = w end
  for _, key in ipairs(keys) do
    local auto = records[key].value
    -- A deleted automation (a tombstone until its cleanup ends) is listed only with deleted = true.
    if type(auto) == 'table' and (args.deleted or not auto.deleted) then
      local st = state_of(get1('state/' .. auto.id)) or {}
      local view = {id = auto.id, rev = records[key].rev, name = auto.name, enabled = auto.enabled, trigger = auto.trigger,
        action = auto.action, instruction = auto.instruction, preset = auto.preset, worker = st.worker,
        spawning = st.spawning and st.spawning.run or nil, daily_high = st.daily_high}
      if auto.deleted then view.status = 'deleting'
      elseif auto.trigger.kind == 'file' and auto.enabled then view.watch = watch_view(auto.id, listed[watch_key(auto.id, st.gen)]) end
      local n = size(view) + 1
      if used + n > PAGE_BUDGET then
        if last == args.after then fail('too_large', 'Automation ' .. auto.id .. ' is too large to list; use after = "' .. key .. '"') end
        next_after = last
        break
      end
      out[#out + 1] = view
      used = used + n
    end
    last = key
  end
  if not next_after and type(more) == 'string' and more ~= '' then next_after = last end
  return {automations = out, next = next_after}
end

-- presets lists each preset with its fields and the automation that installed it (one get).
local function presets(_, args)
  only(args, {})
  local keys = {}
  for _, n in ipairs(PRESET_NAMES) do keys[#keys + 1] = preset_key(n) end
  local recs = get(keys)
  local out = {}
  for _, n in ipairs(PRESET_NAMES) do
    local p, installed = PRESETS[n], state_of(recs[preset_key(n)])
    out[#out + 1] = {preset = n, name = p.name, about = p.about, trigger = p.trigger, action = {cwd = p.cwd}, instruction = p.instruction,
      fill = {'action.profile'}, installed = installed and installed.id or nil}
  end
  return {presets = out}
end

-- runs lists the runs of one automation by phase (6b plan, amendments 1 and 2). Each run is in
-- one phase by its status: S, the run of state.spawning (starting or unknown_start); D, the dv/
-- index (delivered); Q, the q/ index in queue order (queued, without the S run); T, the t/ index
-- (terminal, the newest end first). An index entry whose run has another status is skipped; the
-- engine repairs it. The cursor is the last consumed position: '<P>' (phase P, nothing consumed
-- yet) or '<P>:<key>' ('S:1' for the spawning item). One request consumes at most READ_LIMIT
-- entries. A visible run that does not fit the byte budget is not consumed, so it comes first on
-- the next page. It changes nothing.
local READ_LIMIT = 50
local PHASE_PREFIX = {D = 'dv/', Q = 'q/', T = 't/'}
local PHASE_NEXT = {S = 'D', D = 'Q', Q = 'T'}
local function run_view(run_key, run)
  return {run_key = run_key, kind = run.kind, status = run.status, at = run.at, slot = run.slot, item = run.item, by = run.by,
    attempt = run.attempt, starts = run.starts, agent = run.agent, error = run.error, outcome = run.outcome, summary = run.summary,
    retries = run.retries, dismissed = run.dismissed, restarted = run.restarted}
end
local function runs_cursor(id, after)
  if after == nil then return 'S', nil end
  after = text_arg(after, 'after', MAX_PATH + 64)
  local p, rest = after:match('^([SDQT])(.*)$')
  if not p then fail('invalid_input', 'after is a cursor from automations.runs') end
  if rest == '' then return p, nil end
  if p == 'S' then
    if rest ~= ':1' then fail('invalid_input', 'after is a cursor from automations.runs') end
    return 'D', nil
  end
  local key, prefix = rest:match('^:(.+)$'), PHASE_PREFIX[p] .. id .. '/'
  if not key or #key <= #prefix or key:sub(1, #prefix) ~= prefix then fail('invalid_input', 'after is a cursor of this automation from automations.runs') end
  return p, key
end
local function runs(_, args)
  only(args, {id = true, after = true, limit = true})
  local id = text_arg(args.id, 'id', 32)
  local limit = args.limit or 20
  if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > 50 then fail('invalid_input', 'limit is an integer from 1 to 50') end
  local phase, pos = runs_cursor(id, args.after)
  local st = state_of(get1('state/' .. id)) or {}
  local spawning = type(st.spawning) == 'table' and st.spawning.run or nil
  local C = {out = {}, used = 64, reads = 0}
  local function at(p, key) return key and (p .. ':' .. key) or p end
  local function full() return #C.out >= limit or C.reads >= READ_LIMIT end
  -- add returns false when the run does not fit the page.
  local function add(run_key, run, own)
    local view = run_view(run_key, run)
    local n = size(view) + 1
    if C.used + n > PAGE_BUDGET then
      if #C.out == 0 then fail('too_large', 'Run ' .. run_key .. ' is too large to list; use after = "' .. own .. '"') end
      return false
    end
    C.out[#C.out + 1] = view
    C.used = C.used + n
    return true
  end
  while phase do
    if phase == 'S' then
      if full() then return {runs = C.out, next = 'S'} end
      if spawning then
        local run = state_of(get1(spawning))
        if run and (run.status == 'starting' or run.status == 'unknown_start') and not add(spawning, run, 'S:1') then
          return {runs = C.out, next = 'S'}
        end
      end
      C.reads = C.reads + 1
      phase, pos = 'D', nil
    else
      local prefix, rp = PHASE_PREFIX[phase] .. id .. '/', run_prefix(id)
      local ended = false
      while not ended do
        if full() then return {runs = C.out, next = at(phase, pos)} end
        local keys, records, more = scan(prefix, pos, READ_LIMIT - C.reads)
        local named, want, seen = {}, {}, {}
        for _, k in ipairs(keys) do
          local v = records[k].value
          local rk = phase == 'D' and k:sub(#prefix + 1) or (type(v) == 'table' and v.run or nil)
          if type(rk) == 'string' and rk:sub(1, #rp) == rp then
            named[k] = rk
            if not seen[rk] then seen[rk] = true; want[#want + 1] = rk end
          end
        end
        local recs = #want > 0 and get(want) or {}
        for _, k in ipairs(keys) do
          if #C.out >= limit then return {runs = C.out, next = at(phase, pos)} end
          local rk = named[k]
          local run = rk and state_of(recs[rk]) or nil
          local visible = run ~= nil and ((phase == 'D' and run.status == 'delivered')
            or (phase == 'Q' and run.status == 'queued' and rk ~= spawning)
            or (phase == 'T' and TERMINAL[run.status] and run.t == k))
          if visible and not add(rk, run, phase .. ':' .. k) then return {runs = C.out, next = at(phase, pos)} end
          C.reads = C.reads + 1
          pos = k
        end
        if #keys == 0 or type(more) ~= 'string' or more == '' then ended = true end
      end
      phase, pos = PHASE_NEXT[phase], nil
    end
  end
  return {runs = C.out}
end

local function run_now(caller, args)
  only(args, {id = true, key = true})
  local fingerprint = 'run-v1/' .. canon({id = args.id})
  local prior = replay('run', caller, args.key, fingerprint)
  if prior then return prior end
  local id = text_arg(args.id, 'id', 32)
  local st = state_of(get1('state/' .. id))
  if not st or st.deleted then fail('not_found', 'No automation ' .. id) end
  local n = (st.next_manual or 0) + 1
  local run_key, how, stored = create_run(id, nil, 'm', string.format('%06d', n), function(state) state.next_manual = n end,
    {by = caller.id, record = {key = op_key('run', caller.id, args.key), fingerprint = fingerprint, result = {run_key = run_prefix(id) .. 'm/' .. string.format('%06d', n)}}})
  if how == 'disabled' then fail('disabled', 'Automation ' .. id .. ' is disabled') end
  if how == 'not_found' then fail('not_found', 'No automation ' .. id) end
  if stored and stored.op_exists == nil and stored.revs == nil then return stored end -- a replay result
  pump()
  return {run_key = run_key}
end

-- managed reads auto/<id> and state/<id> for a management change, and refuses a deleted
-- automation. commit_managed sends the change with if_rev on both records and the op record.
local function managed(id)
  local recs = get({'auto/' .. id, 'state/' .. id})
  local auto, st = state_of(recs['auto/' .. id]), state_of(recs['state/' .. id])
  if not auto or not st or auto.deleted or st.deleted then fail('not_found', 'No automation ' .. id) end
  return auto, st, recs['auto/' .. id].rev, recs['state/' .. id].rev
end
local function commit_managed(id, auto, auto_rev, st, st_rev, op, extra)
  local ops = {{key = 'auto/' .. id, if_rev = auto_rev, value = auto}, {key = 'state/' .. id, if_rev = st_rev, value = st}}
  for _, o in ipairs(extra or {}) do ops[#ops + 1] = o end
  local stored = batch(ops, op)
  local result, conflict = committed(stored, op.key)
  if result then
    mark(id)
    S.reconcile_due = true
    S.reconcile_at = nil
    pump()
    if result.revs then return {id = id, rev = result.revs['auto/' .. id]} end
    return result
  end
  if conflict.kind == 'operation' then fail('conflict', 'The operation key was used for other content') end
  return nil
end

-- set_enabled changes only the flag. A change makes a new gen: disable stops new run admission,
-- and the runs already admitted continue (a queued run can still start a worker). Enable moves the daily baseline (B4)
-- and makes a new watch, so files from the disabled time make no run.
local function set_enabled(caller, args)
  only(args, {id = true, enabled = true, key = true})
  if type(args.enabled) ~= 'boolean' then fail('invalid_input', 'enabled is true or false') end
  local fingerprint = 'enable-v1/' .. canon({id = args.id, enabled = args.enabled})
  local prior = replay('enable', caller, args.key, fingerprint)
  if prior then return prior end
  local id = text_arg(args.id, 'id', 32)
  for _ = 1, 5 do
    local auto, st, auto_rev, st_rev = managed(id)
    if args.enabled and not auto.enabled and auto.trigger.kind == 'file' then check_file_limit(id) end
    if auto.enabled ~= args.enabled then
      local t = now()
      st.gen = (st.gen or 0) + 1
      st.enabled = args.enabled
      if args.enabled and auto.trigger.kind == 'daily' then st.daily_base = slot(auto.trigger.at, t) or '' end
      auto.gen, auto.enabled, auto.updated_at = st.gen, args.enabled, t
    end
    local result = commit_managed(id, auto, auto_rev, st, st_rev, {key = op_key('enable', caller.id, args.key), fingerprint = fingerprint,
      result = {id = id}, result_revs = {rev = 'auto/' .. id}})
    if result then return result end
  end
  fail('unavailable', 'The automation changed during the change; try again')
end

-- delete is the fence of B3: one batch marks auto/<id> (the tombstone) and state/<id> deleted,
-- with a new gen. Every admission batch has if_rev on state/<id>, so no new run, start or delivery
-- of a queued run commits after it. The cleanup runs in later steps (cancel_step, purge_step).
-- The fence also deletes preset/<name> when it names this automation (with the observed rev), so
-- the preset can install again at once; purge_step never touches preset/ records.
local function delete(caller, args)
  only(args, {id = true, key = true})
  local fingerprint = 'delete-v1/' .. canon({id = args.id})
  local prior = replay('delete', caller, args.key, fingerprint)
  if prior then return prior end
  local id = text_arg(args.id, 'id', 32)
  for _ = 1, 5 do
    local auto, st, auto_rev, st_rev = managed(id)
    local extra = {}
    if auto.preset then
      local p = get1(preset_key(auto.preset))
      if state_of(p) and p.value.id == id then extra[1] = {key = preset_key(auto.preset), if_rev = p.rev, delete = true} end
    end
    st.deleted = true
    st.gen = (st.gen or 0) + 1
    auto.deleted, auto.gen, auto.deleted_at, auto.deleted_by = true, st.gen, now(), caller.id
    local result = commit_managed(id, auto, auto_rev, st, st_rev, {key = op_key('delete', caller.id, args.key), fingerprint = fingerprint,
      result = {id = id, status = 'deleting'}}, extra)
    if result then return {id = id, status = 'deleting'} end
  end
  fail('unavailable', 'The automation changed during the delete; try again')
end

-- run_change applies a keyed change to one run. change(run, st, auto) changes the run and the
-- state, or refuses; it returns the extra ops. The batch has if_rev on the run and on
-- state/<id> (the fence), so a step that moved the run or the state makes it read again.
local MAX_DISMISSED = 10
local function run_change(kind, caller, args, change)
  only(args, {run_key = true, key = true})
  local fingerprint = kind .. '-v1/' .. canon({run_key = args.run_key})
  local prior = replay(kind, caller, args.key, fingerprint)
  if prior then return prior end
  local run_key = text_arg(args.run_key, 'run_key', 1024)
  local id = run_key:match('^run/(%d+)/[dfm]/')
  if not id then fail('invalid_input', 'run_key is a run key from automations.runs') end
  for _ = 1, 5 do
    local recs = get({run_key, 'auto/' .. id, 'state/' .. id})
    local run_rec, st_rec = recs[run_key], recs['state/' .. id]
    if run_rec.rev == '0' or type(run_rec.value) ~= 'table' then fail('not_found', 'No run ' .. run_key) end
    local st = state_of(st_rec)
    if not st then fail('not_found', 'No automation ' .. id) end
    local run = run_rec.value
    local ops = change(run, st, state_of(recs['auto/' .. id]), run_key, id)
    ops[#ops + 1] = {key = run_key, if_rev = run_rec.rev, value = run}
    ops[#ops + 1] = {key = 'state/' .. id, if_rev = st_rec.rev, value = st}
    local stored = batch(ops, {key = op_key(kind, caller.id, args.key), fingerprint = fingerprint, result = {run_key = run_key, status = run.status}})
    local result, conflict = committed(stored, kind)
    if result then
      mark(id)
      pump()
      if result.revs then return {run_key = run_key, status = run.status} end
      return result
    end
    if conflict.kind == 'operation' then fail('conflict', 'The key ' .. args.key .. ' was used for other content') end
  end
  fail('unavailable', 'The run changed during the change; try again')
end

-- retry is a new admission (design v2, B7): a failed, dismissed or cancelled run goes back to the
-- queue with a new queue entry. It keeps attempt and starts, so its next delivery has attempt + 1
-- and its next start has a new spawn key. A disabled or deleted automation refuses it.
local function retry(caller, args)
  return run_change('retry', caller, args, function(run, st, auto, run_key, id)
    if st.deleted or not auto or auto.deleted then fail('not_found', 'No automation ' .. id) end
    if not st.enabled then fail('disabled', 'Automation ' .. id .. ' is disabled') end
    if run.status ~= 'failed' and run.status ~= 'dismissed' and run.status ~= 'cancelled' then
      fail('not_retryable', 'Run ' .. run_key .. ' is ' .. tostring(run.status) .. '; retry takes a failed, dismissed or cancelled run')
    end
    if run.kind == 'f' and type(run.item) == 'table' and run.item.path == nil then
      fail('not_retryable', 'Run ' .. run_key .. ' has no file path (path too long), so a retry fails again')
    end
    local n = (st.next_q or 0) + 1
    st.next_q = n
    run.status, run.error, run.outcome, run.summary, run.done_at = 'queued', nil, nil, nil, nil
    run.q = queue_key(id, n)
    run.retries = (run.retries or 0) + 1
    run.retried = {by = caller.id, at = now()}
    local ops = {{key = run.q, if_rev = '0', value = {run = run_key}}}
    -- The run is active again: its terminal entry goes, and its next end gets a new sequence.
    if run.t then ops[2] = {key = run.t, delete = true} end
    run.t, run.tseq = nil, nil
    return ops
  end)
end

-- cancel_run takes only a queued run: no side effect has started (design v2, section 9).
local function cancel_run(caller, args)
  return run_change('cancel', caller, args, function(run, st, _, run_key, id)
    if run.status ~= 'queued' then fail('not_cancellable', 'Run ' .. run_key .. ' is ' .. tostring(run.status) .. '; only a queued run can be cancelled') end
    local q = run.q
    run.status, run.q, run.error = 'cancelled', nil, nil
    run.cancelled = {by = caller.id, at = now()}
    return {{key = q, delete = true}, terminal_op(st, id, run_key, run)}
  end)
end

-- dismiss_start ends an unknown_start run (design v2, 5g). The plugin never replays that spawn
-- key again, so it never adopts that pane; the next queued run starts a new worker. The run
-- keeps every dismissed key (the recovery reference), and the state keeps the newest.
local function dismiss_start(caller, args)
  return run_change('dismiss', caller, args, function(run, st, _, run_key, id)
    if run.status ~= 'unknown_start' or type(st.spawning) ~= 'table' or st.spawning.run ~= run_key then
      fail('not_dismissable', 'Run ' .. run_key .. ' is ' .. tostring(run.status) .. '; only an unknown_start run can be dismissed')
    end
    local ref = {key = st.spawning.request.key, at = now(), by = caller.id}
    local list = run.dismissed or {}
    list[#list + 1] = ref
    while #list > MAX_DISMISSED do table.remove(list, 1) end
    run.dismissed = list
    st.dismissed_spawn = {run = run_key, key = ref.key, at = ref.at}
    st.spawning = nil
    local q = run.q
    run.status, run.q = 'dismissed', nil
    local ops = {terminal_op(st, id, run_key, run)}
    if q then ops[2] = {key = q, delete = true} end
    return ops
  end)
end

local function task_view(run_key, run)
  return {run_key = run_key, attempt = run.attempt, token = run_key .. '#' .. tostring(run.attempt), automation = run.name,
    kind = run.kind, slot = run.slot, item = run.item, task = run.task, delivered_at = run.delivered_at}
end

-- read lists the caller's delivered tasks, one page at a time, in box key order. It changes
-- nothing, so a lost reply reads the same page again.
local function read(caller, args)
  only(args, {after = true, limit = true})
  local limit = args.limit or 20
  if type(limit) ~= 'number' or limit % 1 ~= 0 or limit < 1 or limit > 50 then fail('invalid_input', 'limit is an integer from 1 to 50') end
  if args.after ~= nil then text_arg(args.after, 'after', 1024) end
  local prefixes = {}
  for _, id in ipairs(caller.ids) do prefixes[#prefixes + 1] = 'box/' .. id .. '/' end
  table.sort(prefixes)
  local tasks, used, cursor = {}, 64, nil
  -- Prefixes end with "/", so the keys of one prefix are contiguous. A cursor in a later prefix
  -- skips this one; a cursor in this prefix starts after it.
  for _, prefix in ipairs(prefixes) do
    local after, skip = nil, false
    if args.after then
      if args.after:sub(1, #prefix) == prefix then after = args.after
      elseif args.after > prefix then skip = true end
    end
    local keys, records, more = {}, {}, nil
    if not skip then
      local k, r, m = scan(prefix, after, limit + 1)
      keys = k
      records = r
      more = m
    end
    for _, key in ipairs(keys) do
      if #tasks >= limit then cursor = tasks[#tasks].box break end
      local run_key = key:sub(#prefix + 1)
      local run_rec = get1(run_key)
      local run = run_rec.value
      if run_rec.rev ~= '0' and run.status == 'delivered' and 'box/' .. run.agent .. '/' == prefix and run.attempt == records[key].value.attempt then
        local view = task_view(run_key, run)
        local n = size(view) + 1
        if used + n > PAGE_BUDGET then
          if #tasks == 0 then fail('too_large', 'Task ' .. run_key .. ' is too large to list; use after = "' .. key .. '"') end
          cursor = tasks[#tasks].box
          break
        end
        view.box = key
        tasks[#tasks + 1] = view
        used = used + n
      end
    end
    if cursor then break end
    if #tasks >= limit and type(more) == 'string' and more ~= '' then cursor = tasks[#tasks].box break end
  end
  for _, task in ipairs(tasks) do task.box = nil end
  return {tasks = tasks, next = cursor}
end

-- done completes the caller's delivered task. Only the current attempt counts: a delayed done of
-- an earlier delivery is refused (stale_delivery) and changes nothing.
local function done(caller, args)
  only(args, {run_key = true, attempt = true, key = true, outcome = true, summary = true})
  local fingerprint = 'done-v1/' .. canon({run_key = args.run_key, attempt = args.attempt, outcome = args.outcome, summary = args.summary})
  local prior = replay('done', caller, args.key, fingerprint)
  if prior then return prior end
  local run_key = text_arg(args.run_key, 'run_key', 1024)
  if type(args.attempt) ~= 'number' then fail('invalid_input', 'attempt is the attempt of the task (automations.read)') end
  local outcome = args.outcome or 'done'
  if outcome ~= 'done' and outcome ~= 'failed' then fail('invalid_input', 'outcome is done or failed') end
  if args.summary ~= nil and type(args.summary) ~= 'string' then fail('invalid_input', 'summary is text') end
  local id = run_key:match('^run/(%d+)/[dfm]/')
  if not id then fail('not_found', 'No run ' .. run_key) end
  for _ = 1, 5 do
    -- done ends the run, so it takes a terminal sequence under the state fence.
    local recs = get({run_key, 'state/' .. id})
    local run_rec, st_rec = recs[run_key], recs['state/' .. id]
    local run, st = run_rec.value, state_of(st_rec)
    if run_rec.rev == '0' or not st then fail('not_found', 'No run ' .. run_key) end
    if run.status ~= 'delivered' or run.attempt ~= args.attempt or not holds(caller, run.agent) then
      fail('stale_delivery', 'Run ' .. run_key .. ' attempt ' .. tostring(args.attempt) .. ' is not your current task')
    end
    run.status, run.outcome, run.done_at = outcome, outcome, now()
    if outcome == 'failed' then run.status = 'failed' end
    if args.summary and args.summary ~= '' then
      run.summary = cut(args.summary, MAX_SUMMARY)
      local over = size(run) - RUN_BUDGET
      if over > 0 then run.summary = cut(run.summary, math.max(16, #run.summary - over - 8)) end
    end
    local box = box_key(run.agent, run_key)
    local others = other_box(run.agent, box)
    local t_op = terminal_op(st, id, run_key, run)
    local stored = batch({
      {key = run_key, if_rev = run_rec.rev, value = run},
      {key = box, delete = true},
      {key = delivered_key(id, run_key), delete = true},
      {notify = {agent = run.agent, pending = others}},
      t_op,
      {key = 'state/' .. id, if_rev = st_rec.rev, value = st},
    }, {key = op_key('done', caller.id, args.key), fingerprint = fingerprint, result = {run_key = run_key, status = run.status}})
    local result, conflict = committed(stored, 'done')
    if result then
      -- A delete cleanup can wait for this run.
      mark(id)
      pump()
      if result.revs then return {run_key = run_key, status = run.status} end
      return result
    end
    if conflict.kind == 'operation' then fail('conflict', 'The key ' .. args.key .. ' was used for other content') end
  end
  fail('unavailable', 'The run changed during done; try again')
end

local agent_handlers = {
  ['automations.save'] = save,
  ['automations.list'] = list,
  ['automations.run'] = run_now,
  ['automations.set_enabled'] = set_enabled,
  ['automations.delete'] = delete,
  ['automations.retry'] = retry,
  ['automations.cancel_run'] = cancel_run,
  ['automations.dismiss_start'] = dismiss_start,
  ['automations.runs'] = runs,
  ['automations.presets'] = presets,
  ['automations.read'] = read,
  ['automations.done'] = done,
}
-- The panel and forms are a sibling file (the Templates pattern): debug.getinfo gives the
-- script's absolute path.
local here = debug.getinfo(1, 'S').source:gsub('^@', '')
local plugin_dir = assert(here:match('^(/.*)/[^/]*$'), 'the plugin path must be absolute')
-- The SQL storage (slice 2): the schema and the import from hub.store. No path reads it yet.
local sql = dofile(plugin_dir .. '/automations_sql.lua')({app = app, scan = scan, hub = hub})
app.db.migrate(sql.migrations)
local views = dofile(plugin_dir .. '/automations_view.lua')({
  fail = fail, hub = hub, get = get, get1 = get1, scan = scan, size = size, cut = cut, state_of = state_of, USER = USER,
  PAGE_BUDGET = PAGE_BUDGET, PRESETS = PRESETS, PRESET_NAMES = PRESET_NAMES, preset_key = preset_key, run_prefix = run_prefix,
  watch_view = watch_view, watch_key = watch_key, save = save, runs = runs, run_now = run_now, set_enabled = set_enabled,
  delete = delete, retry = retry, cancel_run = cancel_run, dismiss_start = dismiss_start,
})

local key_arg = {type = 'string', minLength = 1, maxLength = 128, description = 'Your operation key. Retry with the same key and content after an unknown outcome.'}
local exports = {
  {name = 'automations.save', title = 'Create or change an automation',
    description = 'Create an automation (no id) or change one (id and if_rev from automations.list). trigger: {kind = "file", path, glob?} (a new file in one directory, not recursive; path is absolute or starts with ~/; glob matches the file name, default *; at most 8 enabled file automations) or {kind = "daily", at = "HH:MM"} (local time). A file automation makes one run for each appearance of a matching file; files that exist when the watch starts make none. action: {profile (an agent profile from hub.profiles), args?, title? (the tab title, at most 60 characters), cwd? (the worker\'s directory: absolute or ~/, and it must exist)}. instruction: the task text for the agent. A run goes to the automation\'s current worker if it runs and was started with the same profile, args and cwd; else the hub starts a new worker. After a change of those, the old worker finishes the tasks that it has and gets no new ones. preset: "vault-inbox" or "vault-health" (automations.presets) on a create installs that preset; a preset installs once (a second install is a conflict that names the automation), and its delete makes it available again. An edit keeps the preset.',
    args = {type = 'object', properties = {id = {type = 'string', minLength = 1}, if_rev = {type = 'string', minLength = 1},
      key = key_arg, name = {type = 'string', minLength = 1, maxLength = MAX_NAME}, enabled = {type = 'boolean'},
      trigger = {type = 'object'}, action = {type = 'object'}, instruction = {type = 'string', minLength = 1, maxLength = MAX_INSTRUCTION},
      preset = {type = 'string', enum = PRESET_NAMES}},
      required = {'key', 'name', 'trigger', 'action', 'instruction'}, additionalProperties = false}},
  {name = 'automations.list', title = 'List automations',
    description = 'List the automations, at most about 40 KB a page: id, rev, name, enabled, trigger, action, instruction, preset, worker, spawning and daily_high; for an enabled file automation, watch {state, error?, hint?} (state from the hub, refused with code, or pending). A deleted automation is listed only with deleted = true, with status deleting, until its cleanup ends. Pages: limit (default 50, at most 50) and about 40 KB. When more exist, next is set: pass it as after. A page can be empty and still have next.',
    args = {type = 'object', properties = {after = {type = 'string', minLength = 1}, limit = {type = 'integer', minimum = 1, maximum = 50},
      deleted = {type = 'boolean'}}, additionalProperties = false}},
  {name = 'automations.presets', title = 'List the automation presets',
    description = 'List the presets: preset (the name for automations.save preset), name, about, trigger, action.cwd and instruction (the defaults), fill (the fields that you choose: action.profile, an agent profile from hub.profiles), and installed (the id of the automation that installed it, if one did). To install, call automations.save with these fields, your profile and preset.',
    args = {type = 'object', properties = {}, additionalProperties = false}},
  {name = 'automations.run', title = 'Run an automation now',
    description = 'Make a manual run of an enabled automation. It does not change the daily schedule. A disabled automation is refused.',
    args = {type = 'object', properties = {id = {type = 'string', minLength = 1}, key = key_arg}, required = {'id', 'key'}, additionalProperties = false}},
  {name = 'automations.set_enabled', title = 'Enable or disable an automation',
    description = 'Enable or disable an automation (id, enabled). Disable stops new run admission (no new run); runs already admitted continue: a queued run can still start a worker and be delivered. Enable starts the schedule from now (no catch-up for the disabled time) and a new file watch (files from the disabled time make no run). At most 8 enabled file automations.',
    args = {type = 'object', properties = {id = {type = 'string', minLength = 1}, enabled = {type = 'boolean'}, key = key_arg},
      required = {'id', 'enabled', 'key'}, additionalProperties = false}},
  {name = 'automations.delete', title = 'Delete an automation and its run history',
    description = 'Delete an automation. This also deletes its run history. At once: no new run, start or delivery, and its queued runs are cancelled. A run that is starting or delivered continues until it ends; then the plugin deletes the runs and the automation. The result status is deleting.',
    args = {type = 'object', properties = {id = {type = 'string', minLength = 1}, key = key_arg}, required = {'id', 'key'}, additionalProperties = false}},
  {name = 'automations.retry', title = 'Retry a run',
    description = 'Queue a failed, dismissed or cancelled run again (run_key from automations.runs). Its next start uses a new spawn key, and its next delivery has attempt + 1. A disabled automation is refused (disabled). A file run without a path (path too long) is refused (not_retryable).',
    args = {type = 'object', properties = {run_key = {type = 'string', minLength = 1}, key = key_arg}, required = {'run_key', 'key'}, additionalProperties = false}},
  {name = 'automations.cancel_run', title = 'Cancel a queued run',
    description = 'Cancel a queued run (run_key from automations.runs). Only a queued run: a run that is starting or delivered is refused (not_cancellable).',
    args = {type = 'object', properties = {run_key = {type = 'string', minLength = 1}, key = key_arg}, required = {'run_key', 'key'}, additionalProperties = false}},
  {name = 'automations.dismiss_start', title = 'Dismiss a pending start',
    description = 'End a run whose worker start has no outcome after 10 minutes (status unknown_start). The plugin never uses that start again, and the next run starts a new worker. Warning: the pane of the dismissed start can still appear, and it can be a duplicate worker. It stays in hub.workers; stop it with hub.stop. The run keeps the dismissed spawn key in dismissed.',
    args = {type = 'object', properties = {run_key = {type = 'string', minLength = 1}, key = key_arg}, required = {'run_key', 'key'}, additionalProperties = false}},
  {name = 'automations.runs', title = 'List the runs of an automation',
    description = 'List the runs of one automation: run_key, kind (f file, d daily, m manual), status, at, slot, item (the file: name, path, seq, watch_id), attempt, starts, agent, error, outcome, summary, retries, dismissed (the spawn keys of dismissed starts) and restarted (the most recent spawn key that an automatic restart replaced: a start that the hub never sent, error not_created, starts again once with a new key in each start admission). Order: the starting run first, then delivered, queued (queue order) and ended runs (the newest end first). Reading changes nothing. Pages: limit (default 20, at most 50), about 40 KB, and at most 50 index entries read; pass next as after. A page can be empty and still have next: follow next until it is absent. A run that changes status between pages can come twice or not at all; for one consistent view, read again from the first page.',
    args = {type = 'object', properties = {id = {type = 'string', minLength = 1}, after = {type = 'string', minLength = 1},
      limit = {type = 'integer', minimum = 1, maximum = 50}}, required = {'id'}, additionalProperties = false}},
  {name = 'automations.read', title = 'Read your automation tasks',
    description = 'List the tasks delivered to you: run_key, attempt, token, automation, kind, slot, item and task (instruction, profile, args, title). Reading changes nothing. A task can come again after a worker loss: skip work that is already done. Pages: limit (default 20, at most 50) and about 40 KB; pass next as after.',
    args = {type = 'object', properties = {after = {type = 'string', minLength = 1}, limit = {type = 'integer', minimum = 1, maximum = 50}}, additionalProperties = false}},
  {name = 'automations.done', title = 'Complete an automation task',
    description = 'Complete one of your tasks: run_key and attempt from automations.read. outcome: done (default) or failed. summary: optional, at most 2000 bytes. A task of an earlier attempt is refused (stale_delivery).',
    args = {type = 'object', properties = {run_key = {type = 'string', minLength = 1}, attempt = {type = 'integer', minimum = 1}, key = key_arg,
      outcome = {type = 'string', enum = {'done', 'failed'}}, summary = {type = 'string', maxLength = MAX_SUMMARY}},
      required = {'run_key', 'attempt', 'key'}, additionalProperties = false}},
}

-- Each export is an SDK action without SQL and without SDK saved replies: the store engine and
-- its replay by key stay authoritative. A raised error keeps its code; any other error is internal.
for _, e in ipairs(exports) do
  local handler = agent_handlers[e.name]
  app.action(e.name, e.args, function(ctx, args)
    args.key = ctx.key
    local ok, result = pcall(handler, caller_of(ctx), args)
    if ok then return result end
    if type(result) == 'table' and type(result.code) == 'string' then error(result, 0) end
    fail('internal', tostring(result))
  end, {tx = false, store = false, title = e.title, description = e.description})
end

-- The panel and the forms: raw views. The view module parses the routes and calls the handlers
-- above with the user as caller.
local view_handlers = {
  render = function(_, args) return views.render(args).tree end,
  ['view.action'] = function(_, args) return views.action(args) end,
}
app.view('/panels/automations*', view_handlers, {store = false})
app.view('/forms/automation/*', view_handlers, {store = false})
app.command({id = 'automations', title = 'Automations…', description = 'List the automations and their runs, and add a preset', keywords = {'schedule', 'watch'},
  surface = 'panel', landing = true, route = '/panels/automations', user_only = 'navigation'})
app.command({id = 'new_automation', title = 'New Automation…', description = 'Create an automation: a new file or a daily time starts an agent task',
  keywords = {'schedule', 'watch'}, route = '/forms/automation/new', action = 'automations.save'})

app.on('hub.changed', function(args)
  -- A worker change can finish a pending start or show a lost worker. The SDK replies after this
  -- function; the steps run in later callbacks.
  if args.what == 'workers' then
    each_auto(function(id) mark(id); S.retry_at[id] = nil end)
    pump()
    ui_changed()
  end
  -- A watch nudge: drain that automation's watch. The drain reads the watch_id from the
  -- reconcile, so a nudge for an old watch_id changes nothing.
  if args.what == 'watch' and type(args.key) == 'string' then
    local owner = watch_owner(args.key)
    if owner then drain_later(owner); pump() end
  end
end, {tx = false})

-- The import copies hub.store into the SQL tables one page at a time, at start. A failed step
-- tries again after RECHECK; a done import does nothing.
local function import_step()
  local ok, done = pcall(sql.import_step)
  if not ok then
    print('automations: import: ' .. (type(done) == 'table' and tostring(done.message) or tostring(done)))
    rex.after(RECHECK, import_step)
  elseif not done then
    rex.after(0, import_step)
  end
end

-- Startup work is not in the main chunk: a catch there can split module-level locals.
rex.after(0, function()
  local ok, err = pcall(function()
    -- Automations has no tab: a palette command and a side panel. The SDK registered first (its
    -- start callback comes before this one).
    hub('hub.ui.tabs', {tabs = {}})
    S.ready = true
    -- A crash can come after a watch remove and before its markers retire: sweep them all once.
    each_auto(function(id) mark(id); S.sweep[id] = true; S.prune[id] = true end)
    S.last_sweep = wall()
    tick()
  end)
  import_step()
  if not ok then print('automations: startup: ' .. (type(err) == 'table' and tostring(err.message) or tostring(err))) end
  rex.every(TICK, function()
    local tick_ok, tick_err = pcall(tick)
    if not tick_ok then print('automations: tick: ' .. (type(tick_err) == 'table' and tostring(tick_err.message) or tostring(tick_err))) end
  end)
end)
