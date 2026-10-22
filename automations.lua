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

-- A rex do script sends at most 64 KiB in one control message (rex-protocol.md). A run document
-- (one SQL statement), a reply page and a view are measured complete, as JSON, against these
-- budgets.
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

-- The sibling files (the Templates pattern): debug.getinfo gives the script's absolute path.
local here = debug.getinfo(1, 'S').source:gsub('^@', '')
local plugin_dir = assert(here:match('^(/.*)/[^/]*$'), 'the plugin path must be absolute')
-- The engine's storage is SQL (automations_db.lua). hub.store is read only by the copy
-- (store_scan below).
local D = dofile(plugin_dir .. '/automations_db.lua')({app = app, fail = fail})
local commit = D.commit

-- store_scan reads hub.store, for the copy only.
local function store_scan(prefix, after, limit)
  local page = hub('hub.store.scan', {prefix = prefix, after = after, limit = limit or 100})
  local keys = {}
  for key in pairs(page.records or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  return keys, page.records or {}, page.next
end

-- join is table.concat(list, sep) in blocks of 1000: in Rex Lua, table.concat of more than 2559
-- items fails with "registry overflow" (observed on Rex 0.0.1792158932-g88fd41, lab; hub
-- docs/rex-protocol.md).
local function join(list, sep)
  local blocks = {}
  for i = 1, #list, 1000 do blocks[#blocks + 1] = table.concat(list, sep, i, math.min(i + 999, #list)) end
  return table.concat(blocks, sep)
end

-- canon encodes a value with sorted object keys: the fingerprint of an operation's content.
local function canon(v)
  if type(v) ~= 'table' then return rex.json.encode(v) end
  if next(v) == nil then return '{}' end
  if #v > 0 then
    local out = {}
    for i = 1, #v do out[i] = canon(v[i]) end
    return '[' .. join(out, ',') .. ']'
  end
  local keys = {}
  for k in pairs(v) do keys[#keys + 1] = tostring(k) end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do out[#out + 1] = rex.json.encode(k) .. ':' .. canon(v[k]) end
  return '{' .. join(out, ',') .. '}'
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
-- replay looks under every ID of the caller (also a reply that the copy imported under a legacy
-- ID).
local function op_key(kind, id, key) return kind .. '/' .. part(id) .. part(key) end
local function replay(kind, caller, key, fingerprint)
  text_arg(key, 'key', 128)
  for _, id in ipairs(caller.ids) do
    local saved = D.op(op_key(kind, id, key))
    if saved then
      if saved.fingerprint ~= nil and saved.fingerprint ~= fingerprint then fail('conflict', 'The key ' .. key .. ' was used for other content') end
      return saved.reply
    end
  end
  return nil
end

-- --- Records (design v2 section 2; amendment 1) ---

local function run_prefix(id) return 'run/' .. id .. '/' end
local function queue_key(id, n) return string.format('q/%s/%012d', id, n) end

-- The runs table answers what the index records q/, t/, dv/ and box/ answered (slice 3a): a run
-- in the queue has q, a terminal run has t, and a delivered run has status delivered and its
-- agent. A run write sets these columns from the document. A page is at most limit runs
-- {key, rev, value}, and whether more follow.
local db = app.db
local function queued_runs(id, after, limit)
  return D.run_page('automation_id = ? AND q > ? ORDER BY q', {id, after or ''}, limit)
end
local function delivered_runs(id, after, limit)
  return D.run_page("automation_id = ? AND status = 'delivered' AND run_key > ? ORDER BY run_key", {id, after or ''}, limit)
end
local function terminal_runs(id, after, limit)
  return D.run_page('automation_id = ? AND t > ? ORDER BY t', {id, after or ''}, limit)
end
-- For the panel: the number of runs in the queue, up to max, and the run that ended last.
local function queue_size(id, max)
  return db.first('SELECT count(*) AS n FROM (SELECT 1 FROM runs WHERE automation_id = ? AND q IS NOT NULL LIMIT ?)', id, max).n
end
local function last_run(id) local r = terminal_runs(id, nil, 1)[1] return r and r.value end

-- The engine's per-automation fence is the state row: every commit that creates, starts or
-- delivers a run writes it with if_rev. Every management change (save, set_enabled, delete,
-- retry, cancel_run, dismiss_start) writes it too, so the engine sees gen, enabled, deleted and
-- the schedule baseline of the row that it acts on.

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
    local page, more = D.autos(after, 100)
    for _, a in ipairs(page) do fn(a.key, a.value, a.rev) end
    after = more and page[#page] and page[#page].key or nil
  until not after
end

-- --- Run creation (design v2 section 4) ---

-- create_run commits one run (in the queue) and the state change. extra(state) changes the state
-- (for example daily_high). It refuses when the state has another gen or is disabled or deleted,
-- so a stale callback makes no run. op: {by, record = the saved operation, reply = its reply}.
-- It answers the run key, how, and the commit (with replayed: the saved reply of op).
local function create_run(id, gen, kind, k, extra, op)
  for _ = 1, 5 do
    local auto = D.auto(id)
    local st, st_rev = D.state(id)
    if not auto or not st or st.deleted then return nil, 'not_found' end
    if not st.enabled then return nil, 'disabled' end
    if gen and st.gen ~= gen then return nil, 'stale' end
    local run_key = run_prefix(id) .. kind .. '/' .. k
    if D.run(run_key) then return run_key, 'exists' end
    local n = (st.next_q or 0) + 1
    local run = {v = 1, auto = id, name = auto.name, kind = kind, by = op and op.by or 'schedule', at = now(),
      task = {instruction = auto.instruction, profile = auto.action.profile, args = auto.action.args, title = auto.action.title, cwd = auto.action.cwd},
      status = 'queued', attempt = 0, starts = 0, q = queue_key(id, n)}
    if kind == 'd' then run.slot = k end
    if size(run) > RUN_BUDGET then fail('internal', 'The run record is over ' .. RUN_BUDGET .. ' bytes encoded') end
    st.next_q = n
    if extra then extra(st) end
    local done = commit(function()
      D.put_run(run_key, '0', run)
      D.put_state(id, st_rev, st)
      return op and op.reply
    end, op and op.record)
    if done then mark(id); return run_key, 'created', done end
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

-- other_task says whether the agent ID has a delivered run other than run_key. A notice row
-- belongs to one agent ID (the hub keeps one per plugin and ID), and each delivery is to the ID
-- that got it, so the row stays pending exactly while that ID has a task.
local function other_task(agent, run_key)
  return db.first("SELECT run_key FROM runs WHERE status = 'delivered' AND agent = ? AND run_key <> ? LIMIT 1", agent, run_key) ~= nil
end

-- deliver (in a commit): the run leaves the queue and becomes delivered to agent, with a new
-- attempt; the notice commits with it.
local function deliver(run_key, run, run_rev, agent, spawn_id)
  run.status, run.agent, run.spawn_id = 'delivered', agent, spawn_id
  run.attempt = (run.attempt or 0) + 1
  run.delivered_at = now()
  run.q = nil
  D.put_run(run_key, run_rev, run)
  app.notice(agent, true)
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
-- batch has the state fence) and sets run.t = t/<id>/<inv>. inv counts down from MAX_T, so the
-- order of t gives the newest first. The order never depends on the clock.
local MAX_T = 999999999999
local function terminal(st, id, run)
  local n = (st.next_t or 0) + 1
  if n > MAX_T then fail('internal', 'Automation ' .. id .. ' has used every terminal sequence') end
  st.next_t = n
  run.t, run.tseq = string.format('t/%s/%012d', id, MAX_T - n), n
  S.prune[id] = true
end

-- --- Engine steps (design v2 section 5; amendment 1, B1) ---

-- spawn_step replays the stored spawn request (never a new key) and applies its result.
local function spawn_step(id, st, st_rev)
  local sp = st.spawning
  local run, run_rev = D.run(sp.run)
  if not run then fail('internal', 'The spawning run ' .. sp.run .. ' is missing') end
  local ok, result = pcall(hub, 'hub.spawn', sp.request)
  if not ok then
    local code = type(result) == 'table' and result.code or 'unavailable'
    if code == 'unavailable' then S.retry_at[id] = wall() + RECHECK; return false end
    result = {status = 'failed', error = type(result) == 'table' and result.message or tostring(result)}
  end
  if result.status == 'open' and type(result.agent_id) == 'string' and result.agent_id ~= '' then
    st.worker = {spawn_id = result.spawn_id, agent_id = result.agent_id, spec = spec(run.task)}
    st.spawning = nil
    commit(function()
      deliver(sp.run, run, run_rev, result.agent_id, result.spawn_id)
      D.put_state(id, st_rev, st)
    end)
    return true
  end
  if result.status == 'pending' then
    if run.status == 'starting' and now() - sp.since >= UNKNOWN_AFTER then
      run.status = 'unknown_start'
      commit(function() D.put_run(sp.run, run_rev, run) end)
    end
    S.retry_at[id] = wall() + RECHECK
    return false
  end
  -- A start that the hub never sent (hub Fix A) created nothing, so the plugin starts it again
  -- once with a new key: one retry per start admission, never after a delete. Only a stored
  -- failed result counts, never a call error. The run and the new request commit together
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
      commit(function() D.put_run(sp.run, run_rev, run); D.put_state(id, st_rev, st) end)
      return true
    end
    result.error = problem
  end
  run.status = 'failed'
  run.error = cut(tostring(result.error or ('The start ended as ' .. tostring(result.status))), MAX_ERROR)
  run.q = nil
  st.spawning = nil
  terminal(st, id, run)
  commit(function() D.put_run(sp.run, run_rev, run); D.put_state(id, st_rev, st) end)
  return true
end

-- lose (in a commit): a delivered run whose worker no longer runs goes back to the queue (design
-- v2, 5e); after a delete it is cancelled, not requeued (B3): no new worker starts for a deleted
-- automation. The old agent's notice row follows its remaining tasks. The run keeps its attempt,
-- so the next delivery has attempt + 1 and a done of the old attempt is refused. It also keeps
-- starts: a later start uses a new key.
local function lose(id, st, run_key, run, run_rev)
  local agent = run.agent
  run.lost = {agent = agent, spawn_id = run.spawn_id, attempt = run.attempt, at = now()}
  if st.deleted then
    run.status, run.error = 'cancelled', 'worker lost after delete'
    terminal(st, id, run)
  else
    local n = (st.next_q or 0) + 1
    st.next_q = n
    run.status, run.agent, run.spawn_id, run.delivered_at = 'queued', nil, nil, nil
    run.q = queue_key(id, n)
  end
  D.put_run(run_key, run_rev, run)
  app.notice(agent, other_task(agent, run_key))
end

-- lost_step requeues one delivered run whose worker is gone (after a delete it cancels it). A
-- run of an older worker (an action change starts a new current worker) is checked against its
-- own spawn: that worker finishes the tasks that it has. When the current worker definitely does
-- not run, it is forgotten. An uncertain observation raises (worker_runs), so nothing is
-- requeued on a guess.
-- The scan goes one page at a time from S.dv_after[id] and wraps at the end, so a page of live
-- tasks never hides a later lost one (review of the 6a plan, point 2). A page with a requeue is
-- read again by the next step. It returns nil when the page has no lost run.
local DV_PAGE = 20
local function lost_step(id, st, st_rev)
  local page, more = delivered_runs(id, S.dv_after[id], DV_PAGE)
  if #page == 0 then S.dv_after[id] = nil; return nil end
  local current = type(st.worker) == 'table' and st.worker.spawn_id or nil
  local seen = {}
  for _, r in ipairs(page) do
    local run = r.value
    local sid = tostring(run.spawn_id)
    if seen[sid] == nil then
      if run.spawn_id == current then seen[sid] = worker_runs(st.worker)
      else seen[sid] = worker_runs({spawn_id = run.spawn_id, agent_id = run.agent}) end
    end
    if not seen[sid] then
      if run.spawn_id == current then st.worker = nil end
      commit(function() lose(id, st, r.key, run, r.rev); D.put_state(id, st_rev, st) end)
      return true
    end
  end
  S.dv_after[id] = more and page[#page].key or nil
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
  each_auto(function(id, auto)
    if auto.enabled and not auto.deleted and auto.trigger.kind == 'file' then
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

-- commit_page commits a page of writes (functions that write in the commit) with the state
-- fence. It answers the new state revision, or nil when the state changed (a save or another
-- step). A page is bounded by rows, not bytes: each write is its own hub.sql call (at most 64 KiB;
-- a run is at most RUN_BUDGET), and the transaction must end within the hub's 10 s (hub
-- docs/sql.md, section 4). The backlog and large-record tests prove the bounds.
local function commit_page(id, st, st_rev, writes)
  local done = commit(function()
    for _, write in ipairs(writes) do write() end
    return D.put_state(id, st_rev, st)
  end)
  return done and done.reply
end

-- drain_step reads one page of the automation's desired watch (at most WATCH_PAGE rows) and
-- commits it in one transaction. A created row without a marker gets its run and marker (both new
-- rows). A removed or created_removed row of a marked appearance gets its retired row. The ack
-- (through = next) follows only when the page committed.
local function drain_step(id)
  local asked = S.drain[id]
  local auto = D.auto(id)
  local st, st_rev = D.state(id)
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
  local writes, marked = {}, {}
  for _, row in ipairs(page.rows or {}) do
    if type(row.appearance_key) ~= 'string' or appearance_watch(row.appearance_key) ~= w.watch_id then
      fail('internal', 'A watch row has no valid appearance_key')
    end
    local mk = marker_key(id, row.appearance_key)
    if marked[mk] == nil then marked[mk] = D.marker(mk) ~= nil end
    if row.kind == 'created' and not marked[mk] then
      local run_key = run_prefix(id) .. 'f/' .. row.appearance_key
      local run = file_run(id, auto, row, (st.next_q or 0) + 1)
      if run.q then st.next_q = (st.next_q or 0) + 1 end
      if run.status == 'failed' then terminal(st, id, run) end
      writes[#writes + 1] = function() D.put_run(run_key, '0', run); D.put_marker(mk, '0', {run = run_key}) end
      marked[mk] = true
    elseif (row.kind == 'removed' or row.kind == 'created_removed') and marked[mk] then
      local rk, seq = retire_key(id, row.appearance_key), row.seq
      writes[#writes + 1] = function() D.put_retired(rk, {seq = seq}) end
    end
  end
  if #writes > 0 and not commit_page(id, st, st_rev, writes) then return true end
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

-- retire_step deletes each marker whose removal row is acknowledged: its retired seq is at or
-- below the watch's cursor. Then the hub has deleted that tombstone, and a new file of that name
-- gets a new created_seq (docs/hub.md, "Rows and kinds"). After a crash between the ack and the
-- delete, the cursor still proves it.
local function retire_step(id)
  local prefix = 'rt/' .. id .. '/'
  local after = type(S.retire[id]) == 'string' and S.retire[id] or nil
  local page, more = D.retired(prefix, after, WATCH_PAGE)
  local cursors = {}
  for _, w in pairs(S.watches) do cursors[w.watch_id] = tonumber(w.cursor) end
  local gone = {}
  for _, r in ipairs(page) do
    local ak = r.key:sub(#prefix + 1)
    local cursor = cursors[appearance_watch(ak) or '']
    local seq = type(r.value) == 'table' and tonumber(r.value.seq) or nil
    if cursor and seq and seq <= cursor then gone[#gone + 1] = ak end
  end
  if #gone > 0 then
    commit(function()
      for _, ak in ipairs(gone) do D.delete_marker(marker_key(id, ak)); D.delete_retired(retire_key(id, ak)) end
    end)
  end
  if #page > 0 and more then S.retire[id] = page[#page].key; return true end
  S.retire[id] = nil
  return #gone > 0
end

-- sweep_step deletes the markers (and retired rows) of watches that the hub no longer lists
-- (B2, rule 2). Steps run one at a time, so no drain makes a marker between the list and the
-- delete.
local function sweep_step(id)
  local live = {}
  for _, w in ipairs(hub('hub.watch.list').watches or {}) do live[w.watch_id] = true end
  local prefix = 'seen/' .. id .. '/'
  local after = type(S.sweep[id]) == 'string' and S.sweep[id] or nil
  local page, more = D.markers(prefix, after, WATCH_PAGE)
  local gone = {}
  for _, r in ipairs(page) do
    local ak = r.key:sub(#prefix + 1)
    if not live[appearance_watch(ak) or ''] then gone[#gone + 1] = ak end
  end
  if #gone > 0 then
    commit(function()
      for _, ak in ipairs(gone) do D.delete_marker(marker_key(id, ak)); D.delete_retired(retire_key(id, ak)) end
    end)
  end
  if #page > 0 and more then S.sweep[id] = page[#page].key; return true end
  S.sweep[id] = nil
  return #gone > 0
end

-- --- Delete cleanup (amendment 1, B3; the coordinator's decision, 2026-10-20: a delete also
-- deletes the run history) ---

local CLEANUP_RUNS, CLEANUP_KEYS = 20, 50

-- cancel_step cancels at most CLEANUP_RUNS queued runs of a deleted automation, one commit for
-- each step. A starting or unknown_start run keeps its place in the queue: that run continues
-- (design v2, 5f). It returns nil when no queued run is left.
local function cancel_step(id, st, st_rev)
  local writes = {}
  for _, r in ipairs((queued_runs(id, nil, CLEANUP_RUNS + 1))) do
    if r.value.status == 'queued' and #writes < CLEANUP_RUNS then
      local run = r.value
      run.status, run.error, run.q = 'cancelled', 'automation deleted', nil
      terminal(st, id, run)
      writes[#writes + 1] = function() D.put_run(r.key, r.rev, run) end
    end
  end
  if #writes == 0 then return nil end
  commit_page(id, st, st_rev, writes)
  return true
end

-- purge_step deletes the rows of a deleted automation when no run is active, at most
-- CLEANUP_KEYS in each step: markers, retired rows, and the terminal runs. The last commit
-- deletes the state and the automation tombstone.
local ACTIVE = {queued = true, starting = true, unknown_start = true, delivered = true}
local function purge_step(id, st, st_rev)
  local writes = {}
  for _, r in ipairs((D.markers('seen/' .. id .. '/', nil, CLEANUP_KEYS))) do writes[#writes + 1] = function() D.delete_marker(r.key) end end
  if #writes == 0 then
    for _, r in ipairs((D.retired('rt/' .. id .. '/', nil, CLEANUP_KEYS))) do writes[#writes + 1] = function() D.delete_retired(r.key) end end
  end
  if #writes == 0 then
    for _, r in ipairs((D.run_page('automation_id = ? ORDER BY run_key', {id}, CLEANUP_KEYS))) do
      if ACTIVE[r.value.status] then fail('internal', 'Run ' .. r.key .. ' is ' .. r.value.status .. ' after the cleanup') end
      writes[#writes + 1] = function() D.delete_run(r.key) end
    end
  end
  if #writes > 0 then
    commit_page(id, st, st_rev, writes)
    return true
  end
  commit(function() D.delete_state(id, st_rev); D.delete_auto(id) end)
  return false
end

-- prune_step keeps the newest KEEP_RUNS terminal runs. It reads the state first: every change of
-- the terminal set (a terminal change, a retry) writes it, and the prune commit writes it back
-- unchanged with the observed rev. So a change after the read makes the commit fail, and the
-- next step computes the cutoff again (review of 451691c, R1). Then it deletes at most PRUNE_PAGE
-- terminal runs after the newest KEEP_RUNS, in t order, each with its observed rev, so a run that
-- a retry made active stays: the commit writes nothing, and a later step reads again. The query
-- reads no document (a page of 100 documents can need more than one reply). Markers are never
-- touched (B2).
local KEEP_RUNS, PRUNE_PAGE = 100, 50
local TERMINAL = {done = true, failed = true, cancelled = true, dismissed = true}
local function prune_step(id)
  local st, st_rev = D.state(id)
  if not st then S.prune[id] = nil; return false end
  local old = db.query("SELECT run_key, rev FROM runs WHERE automation_id = ? AND t IS NOT NULL "
    .. "AND status IN ('done', 'failed', 'cancelled', 'dismissed') ORDER BY t LIMIT ? OFFSET ?", id, PRUNE_PAGE, KEEP_RUNS)
  if #old == 0 then S.prune[id] = nil; return false end
  local writes = {}
  for _, row in ipairs(old) do writes[#writes + 1] = function() D.delete_run(row.run_key, row.rev) end end
  commit_page(id, st, st_rev, writes)
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
  local st, st_rev = D.state(id)
  if not st then return false end
  -- After a delete: queued runs are cancelled first. A pending start still replays and delivers
  -- its run, and a delivered run stays until done or a worker loss. Then the rows go.
  if st.deleted then
    local cancelled = cancel_step(id, st, st_rev)
    if cancelled ~= nil then return cancelled end
  end
  if st.spawning then return spawn_step(id, st, st_rev) end
  local lost = lost_step(id, st, st_rev)
  if lost ~= nil then return lost end
  if st.deleted then
    if #delivered_runs(id, nil, 1) > 0 then return S.dv_after[id] ~= nil end
    return purge_step(id, st, st_rev)
  end
  local first = queued_runs(id, nil, 1)[1]
  -- A delivered-run pass that is not at its end continues in the next step.
  if not first then return S.dv_after[id] ~= nil end
  local run_key, run, run_rev = first.key, first.value, first.rev
  if run.status ~= 'queued' then fail('internal', 'The first run in the queue, ' .. run_key .. ', is ' .. tostring(run.status)) end
  if type(st.worker) == 'table' and st.worker.spec == spec(run.task) and worker_runs(st.worker) then
    commit(function()
      deliver(run_key, run, run_rev, st.worker.agent_id, st.worker.spawn_id)
      D.put_state(id, st_rev, st)
    end)
    return true
  end
  -- Start admission: a new start counter gives a new key; the request is stored before the call.
  -- The profile can change after save, so a new start checks it again (design v2, 5d). A replay
  -- in spawn_step does not: its earlier effect may already exist.
  local problem = profile_problem(run.task)
  if problem then
    run.status = 'failed'
    run.error = cut(problem, MAX_ERROR)
    run.q = nil
    terminal(st, id, run)
  else
    run.starts = (run.starts or 0) + 1
    run.status = 'starting'
    st.spawning = {run = run_key, since = now(), request = spawn_request(run_key, run.starts, run.task)}
  end
  commit(function() D.put_run(run_key, run_rev, run); D.put_state(id, st_rev, st) end)
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
  each_auto(function(id, auto)
    if auto.enabled and not auto.deleted and auto.trigger.kind == 'daily' then
      local s = slot(auto.trigger.at, t)
      local st = D.state(id)
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
  local n, rev = D.next_id()
  return tostring(n + 1), n + 1, rev
end

-- The hub allows 8 watches per plugin, one for each enabled file automation.
local function check_file_limit(except_id)
  local others = {n = 0}
  each_auto(function(id, a)
    if id ~= except_id and a.enabled and not a.deleted and a.trigger.kind == 'file' then others.n = others.n + 1 end
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
    local id, n, n_rev, old, st, st_rev = args.id, nil, nil, nil, nil, '0'
    if id == nil then
      id, n, n_rev = next_id()
    else
      text_arg(id, 'id', 32)
      if type(args.if_rev) ~= 'string' then fail('invalid_input', 'if_rev is required to change an automation') end
      local auto_rev
      old, auto_rev = D.auto(id)
      st, st_rev = D.state(id)
      if not old or (st or {}).deleted then fail('not_found', 'No automation ' .. id) end
      if auto_rev ~= args.if_rev then fail('conflict', 'Automation ' .. id .. ' is at rev ' .. auto_rev) end
      if args.preset ~= nil and args.preset ~= old.preset then fail('invalid_input', 'Automation ' .. id .. ' is not from preset ' .. args.preset) end
    end
    local preset = old and old.preset or args.preset
    st = st or {v = 1, gen = 0, next_q = 0, next_manual = 0}
    local trigger_changed = not old or canon(old.trigger) ~= canon(trigger)
    local enabling = enabled and (not old or not old.enabled)
    if trigger_changed or (old and old.enabled ~= enabled) then st.gen = (st.gen or 0) + 1 end
    st.enabled = enabled
    -- The baseline moves only on create, enable, a change to daily and a time change (B4). An
    -- unrelated save keeps a due catch-up. daily_high is never cleared.
    if trigger.kind == 'daily' and enabled and (trigger_changed or enabling) then st.daily_base = slot(trigger.at, t) or '' end
    local auto = {v = 1, id = id, name = name, enabled = enabled, gen = st.gen, trigger = trigger, action = action,
      instruction = instruction, preset = preset, by = old and old.by or caller.id, created_at = old and old.created_at or t, updated_at = t}
    local done, conflict = commit(function()
      local rev = D.put_auto(id, old and args.if_rev or '0', auto)
      D.put_state(id, st_rev, st)
      if n then D.put_next_id(n, n_rev) end
      if preset and not old then D.put_preset(preset, '0', id) end
      return {id = id, rev = rev}
    end, {key = op_key('save', caller.id, args.key), fingerprint = fingerprint})
    if done then
      mark(id)
      S.reconcile_due = true
      S.reconcile_at = nil
      pump()
      return done.replayed or done.reply
    end
    if conflict.what == 'automation ' .. id and args.id then fail('conflict', 'Automation ' .. id .. ' is at rev ' .. select(2, D.auto(id))) end
    if preset and conflict.what == 'preset ' .. preset then
      fail('conflict', 'Preset ' .. preset .. ' is installed as automation ' .. tostring(D.preset(preset) or '(unknown)'))
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
  -- next is the last key (auto/<id>) that the page consumed, also a deleted one: after is
  -- exclusive. A visible automation that does not fit is not consumed, so the next page starts
  -- with it.
  local out, used, next_after, last = {}, 64, nil, args.after
  local from = args.after and args.after:sub(1, 5) == 'auto/' and args.after:sub(6) or nil
  local page, more = D.autos(from, limit)
  local listed = {}
  for _, w in ipairs(hub('hub.watch.list').watches or {}) do listed[w.key] = w end
  for _, a in ipairs(page) do
    local key, auto = 'auto/' .. a.key, a.value
    -- A deleted automation (a tombstone until its cleanup ends) is listed only with deleted = true.
    if args.deleted or not auto.deleted then
      local st = D.state(auto.id) or {}
      local view = {id = auto.id, rev = a.rev, name = auto.name, enabled = auto.enabled, trigger = auto.trigger,
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
  if not next_after and more then next_after = last end
  return {automations = out, next = next_after}
end

-- presets lists each preset with its fields and the automation that installed it.
local function presets(_, args)
  only(args, {})
  local out = {}
  for _, n in ipairs(PRESET_NAMES) do
    local p, installed = PRESETS[n], D.preset(n)
    out[#out + 1] = {preset = n, name = p.name, about = p.about, trigger = p.trigger, action = {cwd = p.cwd}, instruction = p.instruction,
      fill = {'action.profile'}, installed = installed}
  end
  return {presets = out}
end

-- runs lists the runs of one automation by phase (6b plan, amendments 1 and 2). Each run is in
-- one phase by its status: S, the run of state.spawning (starting or unknown_start); D, the
-- delivered runs; Q, the runs in queue order (queued, without the S run); T, the runs in t order
-- (terminal, the newest end first). The cursor is the last consumed position: '<P>' (phase P, nothing consumed
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
  local st = D.state(id) or {}
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
        local run = D.run(spawning)
        if run and (run.status == 'starting' or run.status == 'unknown_start') and not add(spawning, run, 'S:1') then
          return {runs = C.out, next = 'S'}
        end
      end
      C.reads = C.reads + 1
      phase, pos = 'D', nil
    else
      -- A position is the run's q or t, or dv/<id>/<run key> for D (the cursors of the index
      -- records stay valid).
      local prefix = PHASE_PREFIX[phase] .. id .. '/'
      local ended = false
      while not ended do
        if full() then return {runs = C.out, next = at(phase, pos)} end
        local page, more
        if phase == 'D' then page, more = delivered_runs(id, pos and pos:sub(#prefix + 1), READ_LIMIT - C.reads)
        elseif phase == 'Q' then page, more = queued_runs(id, pos, READ_LIMIT - C.reads)
        else page, more = terminal_runs(id, pos, READ_LIMIT - C.reads) end
        for _, rec in ipairs(page) do
          if #C.out >= limit then return {runs = C.out, next = at(phase, pos)} end
          local rk, run = rec.key, rec.value
          local k = phase == 'D' and prefix .. rk or (phase == 'Q' and run.q or run.t)
          local visible = phase == 'D' or (phase == 'Q' and run.status == 'queued' and rk ~= spawning) or (phase == 'T' and TERMINAL[run.status])
          if visible and not add(rk, run, phase .. ':' .. k) then return {runs = C.out, next = at(phase, pos)} end
          C.reads = C.reads + 1
          pos = k
        end
        if #page == 0 or not more then ended = true end
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
  local st = D.state(id)
  if not st or st.deleted then fail('not_found', 'No automation ' .. id) end
  local n = (st.next_manual or 0) + 1
  local run_key, how, done = create_run(id, nil, 'm', string.format('%06d', n), function(state) state.next_manual = n end,
    {by = caller.id, record = {key = op_key('run', caller.id, args.key), fingerprint = fingerprint},
      reply = {run_key = run_prefix(id) .. 'm/' .. string.format('%06d', n)}})
  if how == 'disabled' then fail('disabled', 'Automation ' .. id .. ' is disabled') end
  if how == 'not_found' then fail('not_found', 'No automation ' .. id) end
  if done and done.replayed then return done.replayed end
  pump()
  return {run_key = run_key}
end

-- managed reads the automation and its state for a management change, and refuses a deleted
-- automation. commit_managed commits the change with if_rev on both rows, extra() (more writes)
-- and the saved reply: op.reply, or {id, rev} with the new automation revision.
local function managed(id)
  local auto, auto_rev = D.auto(id)
  local st, st_rev = D.state(id)
  if not auto or not st or auto.deleted or st.deleted then fail('not_found', 'No automation ' .. id) end
  return auto, st, auto_rev, st_rev
end
local function commit_managed(id, auto, auto_rev, st, st_rev, op, extra)
  local done = commit(function()
    local rev = D.put_auto(id, auto_rev, auto)
    D.put_state(id, st_rev, st)
    if extra then extra() end
    return op.reply or {id = id, rev = rev}
  end, {key = op.key, fingerprint = op.fingerprint})
  if not done then return nil end
  mark(id)
  S.reconcile_due = true
  S.reconcile_at = nil
  pump()
  return done.replayed or done.reply
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
    local result = commit_managed(id, auto, auto_rev, st, st_rev, {key = op_key('enable', caller.id, args.key), fingerprint = fingerprint})
    if result then return result end
  end
  fail('unavailable', 'The automation changed during the change; try again')
end

-- delete is the fence of B3: one commit marks the automation (the tombstone) and its state
-- deleted, with a new gen. Every admission commit has if_rev on the state, so no new run, start or
-- delivery of a queued run commits after it. The cleanup runs in later steps (cancel_step,
-- purge_step). The fence also deletes the preset row when it names this automation (with the
-- observed rev), so the preset can install again at once; purge_step never touches presets.
local function delete(caller, args)
  only(args, {id = true, key = true})
  local fingerprint = 'delete-v1/' .. canon({id = args.id})
  local prior = replay('delete', caller, args.key, fingerprint)
  if prior then return prior end
  local id = text_arg(args.id, 'id', 32)
  for _ = 1, 5 do
    local auto, st, auto_rev, st_rev = managed(id)
    local extra
    if auto.preset then
      local owner, p_rev = D.preset(auto.preset)
      if owner == id then extra = function() D.delete_preset(auto.preset, p_rev) end end
    end
    st.deleted = true
    st.gen = (st.gen or 0) + 1
    auto.deleted, auto.gen, auto.deleted_at, auto.deleted_by = true, st.gen, now(), caller.id
    local result = commit_managed(id, auto, auto_rev, st, st_rev, {key = op_key('delete', caller.id, args.key), fingerprint = fingerprint,
      reply = {id = id, status = 'deleting'}}, extra)
    if result then return {id = id, status = 'deleting'} end
  end
  fail('unavailable', 'The automation changed during the delete; try again')
end

-- run_change applies a keyed change to one run. change(run, st, auto) changes the run and the
-- state, or refuses. The batch has if_rev on the run and on state/<id> (the fence), so a step
-- that moved the run or the state makes it read again.
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
    local run, run_rev = D.run(run_key)
    if not run then fail('not_found', 'No run ' .. run_key) end
    local st, st_rev = D.state(id)
    if not st then fail('not_found', 'No automation ' .. id) end
    change(run, st, D.auto(id), run_key, id)
    local done = commit(function()
      D.put_run(run_key, run_rev, run)
      D.put_state(id, st_rev, st)
      return {run_key = run_key, status = run.status}
    end, {key = op_key(kind, caller.id, args.key), fingerprint = fingerprint})
    if done then
      mark(id)
      pump()
      return done.replayed or done.reply
    end
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
    -- The run is active again: it leaves the terminal order, and its next end gets a new sequence.
    run.t, run.tseq = nil, nil
  end)
end

-- cancel_run takes only a queued run: no side effect has started (design v2, section 9).
local function cancel_run(caller, args)
  return run_change('cancel', caller, args, function(run, st, _, run_key, id)
    if run.status ~= 'queued' then fail('not_cancellable', 'Run ' .. run_key .. ' is ' .. tostring(run.status) .. '; only a queued run can be cancelled') end
    run.status, run.q, run.error = 'cancelled', nil, nil
    run.cancelled = {by = caller.id, at = now()}
    terminal(st, id, run)
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
    run.status, run.q = 'dismissed', nil
    terminal(st, id, run)
  end)
end

local function task_view(run_key, run)
  return {run_key = run_key, attempt = run.attempt, token = run_key .. '#' .. tostring(run.attempt), automation = run.name,
    kind = run.kind, slot = run.slot, item = run.item, task = run.task, delivered_at = run.delivered_at}
end

-- read lists the caller's delivered tasks, one page at a time, in the order of the box key
-- box/<agent ID>/<run key> (the cursor). It changes nothing, so a lost reply reads the same page
-- again.
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
    local page, more = {}, false
    if not skip then
      page, more = D.run_page("status = 'delivered' AND agent = ? AND run_key > ? ORDER BY run_key",
        {prefix:sub(5, -2), after and after:sub(#prefix + 1) or ''}, limit + 1)
    end
    for _, rec in ipairs(page) do
      if #tasks >= limit then cursor = tasks[#tasks].box break end
      local key = prefix .. rec.key
      local view = task_view(rec.key, rec.value)
      local n = size(view) + 1
      if used + n > PAGE_BUDGET then
        if #tasks == 0 then fail('too_large', 'Task ' .. rec.key .. ' is too large to list; use after = "' .. key .. '"') end
        cursor = tasks[#tasks].box
        break
      end
      view.box = key
      tasks[#tasks + 1] = view
      used = used + n
    end
    if cursor then break end
    if #tasks >= limit and more then cursor = tasks[#tasks].box break end
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
    local run, run_rev = D.run(run_key)
    local st, st_rev = D.state(id)
    if not run or not st then fail('not_found', 'No run ' .. run_key) end
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
    terminal(st, id, run)
    local done = commit(function()
      D.put_run(run_key, run_rev, run)
      app.notice(run.agent, other_task(run.agent, run_key))
      D.put_state(id, st_rev, st)
      return {run_key = run_key, status = run.status}
    end, {key = op_key('done', caller.id, args.key), fingerprint = fingerprint})
    if done then
      -- A delete cleanup can wait for this run.
      mark(id)
      pump()
      return done.replayed or done.reply
    end
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
-- The SQL storage (slice 2): the schema and the copy from hub.store.
local sql = dofile(plugin_dir .. '/automations_sql.lua')({app = app, fail = fail, scan = store_scan, hub = hub,
  canonical = D.canonical, valid_counter = D.valid_counter})
app.db.migrate(sql.migrations)
local views = dofile(plugin_dir .. '/automations_view.lua')({
  fail = fail, hub = hub, D = D, size = size, cut = cut, USER = USER,
  queue_size = queue_size, last_run = last_run, PAGE_BUDGET = PAGE_BUDGET, PRESETS = PRESETS, PRESET_NAMES = PRESET_NAMES, run_prefix = run_prefix,
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

-- The gate (plan, "The cutover", point 2): until the copy is done, S.ready is false, and no entry
-- point changes anything. S.not_ready is the text that the exports and the views give.
S.not_ready = 'Starting: Automations is importing the automations'
local function closed() fail('unavailable', S.not_ready) end

-- Each export is an SDK action without SDK saved replies: the engine and its replay by key (the
-- ops table) stay authoritative. A raised error keeps its code; any other error is internal.
for _, e in ipairs(exports) do
  local handler = agent_handlers[e.name]
  app.action(e.name, e.args, function(ctx, args)
    if not S.ready then closed() end
    args.key = ctx.key
    local ok, result = pcall(handler, caller_of(ctx), args)
    if ok then return result end
    if type(result) == 'table' and type(result.code) == 'string' then error(result, 0) end
    fail('internal', tostring(result))
  end, {tx = false, store = false, title = e.title, description = e.description})
end

-- The panel and the forms: raw views. The view module parses the routes and calls the handlers
-- above with the user as caller. tx = false: each batch is its own transaction, as in the engine,
-- and no transaction spans a hub call.
local view_handlers = {
  render = function(_, args)
    if not S.ready then return {title = 'Automations', nodes = {{id = 'not_ready', type = 'widget', text = S.not_ready}}} end
    return views.render(args).tree
  end,
  ['view.action'] = function(_, args)
    if not S.ready then closed() end
    return views.action(args)
  end,
}
app.view('/panels/automations*', view_handlers, {store = false, tx = false})
app.view('/forms/automation/*', view_handlers, {store = false, tx = false})
app.command({id = 'automations', title = 'Automations…', description = 'List the automations and their runs, and add a preset', keywords = {'schedule', 'watch'},
  surface = 'panel', landing = true, route = '/panels/automations', user_only = 'navigation'})
app.command({id = 'new_automation', title = 'New Automation…', description = 'Create an automation: a new file or a daily time starts an agent task',
  keywords = {'schedule', 'watch'}, route = '/forms/automation/new', action = 'automations.save'})

app.on('hub.changed', function(args)
  -- Before the copy is done, nothing: the start after it marks every automation, and its
  -- reconcile drains each watch (the hub keeps the watch events).
  if not S.ready then return end
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

-- The start (plan, "The cutover", points 1 to 3). The storage state picks one path: the copy
-- from hub.store (on empty tables, or to resume it), SQL as it is (done), or a refusal with no
-- write. The copy runs one step per callback; a failed step tries again after RECHECK. When the
-- copy is done, the engine starts as at a start before the cutover.
local function message(err) return type(err) == 'table' and tostring(err.message) or tostring(err) end
local function open()
  S.ready = true
  -- A crash can come after a watch remove and before its markers retire: sweep them all once.
  each_auto(function(id) mark(id); S.sweep[id] = true; S.prune[id] = true end)
  S.last_sweep = wall()
  tick()
  ui_changed()
end
local function copy_step()
  local ok, done = pcall(sql.copy_step)
  if not ok then
    print('automations: copy: ' .. message(done))
    rex.after(RECHECK, copy_step)
  elseif not done then
    rex.after(0, copy_step)
  else
    local open_ok, err = pcall(open)
    if not open_ok then print('automations: startup: ' .. message(err)) end
  end
end
local function start()
  local state, why = sql.state()
  if state == nil then
    S.not_ready = 'Automations cannot start: the storage state is not known (' .. why .. ')'
    print('automations: refused: ' .. why)
    return
  end
  if state == 'empty' then sql.begin(); state = 'copying' end
  if state == 'copying' then rex.after(0, copy_step); return end
  open()
end

-- Startup work is not in the main chunk: a catch there can split module-level locals.
rex.after(0, function()
  local function attempt()
    local ok, err = pcall(function()
      -- Automations has no tab: a palette command and a side panel. The SDK registered first (its
      -- start callback comes before this one).
      hub('hub.ui.tabs', {tabs = {}})
      start()
    end)
    if not ok then
      print('automations: startup: ' .. message(err))
      if not S.ready then rex.after(RECHECK, attempt) end
    end
  end
  attempt()
  rex.every(TICK, function()
    if not S.ready then return end
    local tick_ok, tick_err = pcall(tick)
    if not tick_ok then print('automations: tick: ' .. message(tick_err)) end
  end)
end)
