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
local hub_id = assert(rex.args.hub_client_id, 'hub_client_id is required')
local instance_id = assert(rex.args.instance_id, 'instance_id is required')

local function fail(code, message) error({code = code, message = message}, 0) end

-- A hub error arrives as text that ends with "(status=<n> code=<code>)" (observed on Rex
-- 0.0.1792158932-g88fd41, lab; see Profiles). An error with no code (a lost or timed-out call) is
-- unavailable: its outcome is not known.
local function hub(action, args)
  local response, call_error = rex.call('client.perform', {client_id = hub_id, action = action, args = args or {}, timeout_ms = 10000})
  if type(response) ~= 'table' then
    if type(call_error) == 'table' then fail(call_error.code or 'unavailable', call_error.message or 'Hub request failed') end
    local text = tostring(call_error or 'Hub request failed')
    local code = text:match('code=([%w_]+)%)$')
    if not code or code == 'unavailable' or code == 'disconnected' or code == 'timeout' then fail('unavailable', text) end
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

local function check_trigger(t)
  if type(t) ~= 'table' then fail('invalid_input', 'trigger is required') end
  if t.kind == 'daily' then
    only(t, {kind = true, at = true})
    local at = t.at
    if type(at) ~= 'string' or not at:match('^%d%d:%d%d$') or tonumber(at:sub(1, 2)) > 23 or tonumber(at:sub(4, 5)) > 59 then
      fail('invalid_input', 'trigger.at is a local time HH:MM, 00:00 to 23:59')
    end
    return {kind = 'daily', at = at}
  end
  fail('invalid_input', 'trigger.kind must be daily')
end

-- check_action validates the profile now: it must exist, be an agent profile, have every
-- required arg, and declare every given arg. The same check runs again at each start.
local function check_action(a)
  if type(a) ~= 'table' then fail('invalid_input', 'action is required') end
  only(a, {profile = true, args = true, title = true})
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
  if a.title ~= nil and a.title ~= '' then out.title = text_arg(a.title, 'action.title', MAX_TEXT) end
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
local function agent_caller(pid)
  if type(pid) ~= 'number' or pid <= 0 or pid % 1 ~= 0 then fail('refused', 'A positive requester PID is required') end
  local r = hub('hub.identify', {pid = pid})
  if r.found ~= true or type(r.agent) ~= 'string' or r.agent == '' then fail('refused', 'The hub does not recognize this agent') end
  local ids = {r.agent}
  for _, l in ipairs(type(r.legacy) == 'table' and r.legacy or {}) do
    if type(l) == 'string' and l ~= '' then ids[#ids + 1] = l end
  end
  for _, id in ipairs(ids) do
    if #id > 128 or id:find('[%c/]') then fail('refused', 'An ID of this agent has a slash or control characters, or is over 128 bytes') end
  end
  return {id = r.agent, ids = ids}
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
-- a run writes it with if_rev. A save writes it too, so the engine sees gen, enabled and the
-- schedule baseline of the record that it acts on.
local function state_of(record) return type(record.value) == 'table' and record.value or nil end

local S = {dirty = {}, pumping = false, retry_at = {}, ready = false}

local function mark(id) S.dirty[id] = true end
local pump -- forward

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
      task = {instruction = auto.instruction, profile = auto.action.profile, args = auto.action.args, title = auto.action.title},
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
  local ok, resolved = pcall(hub, 'hub.agents.resolve', {to = worker.agent_id})
  if not ok or type(resolved.id) ~= 'string' then return false end
  for _, a in ipairs(hub('hub.agents', {all = true}).agents or {}) do
    if a.id == resolved.id then
      if a.legacy then return a.alias_of == nil end
      return a.state == 'current'
    end
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
  return r
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
    st.worker = {spawn_id = result.spawn_id, agent_id = result.agent_id}
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
  run.status = 'failed'
  run.error = cut(tostring(result.error or ('The start ended as ' .. tostring(result.status))), MAX_ERROR)
  local q = run.q
  run.q = nil
  st.spawning = nil
  batch({{key = sp.run, if_rev = run_rec.rev, value = run}, {key = q, delete = true}, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}})
  return true
end

-- step does one unit of work for one automation and says whether more work may follow now.
local function step(id)
  local st_rec = get1('state/' .. id)
  local st = state_of(st_rec)
  if not st then return false end
  if st.spawning then return spawn_step(id, st_rec) end
  local keys, records = scan('q/' .. id .. '/', nil, 1)
  if #keys == 0 then return false end
  local run_key = records[keys[1]].value.run
  local run_rec = get1(run_key)
  if run_rec.rev == '0' or run_rec.value.status ~= 'queued' then fail('internal', 'Queue entry ' .. keys[1] .. ' names no queued run') end
  if worker_runs(st.worker) then
    local ops = deliver_ops(id, run_key, run_rec, st.worker.agent_id, st.worker.spawn_id)
    ops[#ops + 1] = {key = 'state/' .. id, if_rev = st_rec.rev, value = st}
    batch(ops)
    return true
  end
  -- Start admission: a new start counter gives a new key; the request is stored before the call.
  local run = run_rec.value
  run.starts = (run.starts or 0) + 1
  run.status = 'starting'
  st.spawning = {run = run_key, since = now(), request = spawn_request(run_key, run.starts, run.task)}
  batch({{key = run_key, if_rev = run_rec.rev, value = run}, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}})
  return true
end

-- pump runs one step per callback, so hub requests and other callbacks do not wait long.
pump = function()
  if S.pumping or not S.ready then return end
  local t = wall()
  local id
  for candidate in pairs(S.dirty) do
    if not S.retry_at[candidate] or S.retry_at[candidate] <= t then id = candidate break end
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
      S.dirty[id] = true
    elseif more or S.retry_at[id] then
      S.dirty[id] = true
    end
    S.pumping = false
    pump()
  end)
end

-- --- Schedule tick ---

local function each_auto(fn)
  local after
  repeat
    local keys, records, next_after = scan('auto/', after, 100)
    for _, key in ipairs(keys) do fn(key:sub(6), records[key]) end
    after = next_after
  until type(after) ~= 'string' or after == ''
end

local function tick()
  local t = now()
  each_auto(function(id, rec)
    local auto = rec.value
    if type(auto) == 'table' and auto.enabled and auto.trigger.kind == 'daily' then
      local s = slot(auto.trigger.at, t)
      local st = state_of(get1('state/' .. id))
      if s and st and s > (st.daily_high or '') and s > (st.daily_base or '') then
        create_run(id, st.gen, 'd', s, function(state) state.daily_high = s end)
      end
    end
  end)
  -- Due rechecks (a pending spawn) and every automation with work: the recheck interval.
  if not S.last_sweep or wall() - S.last_sweep >= RECHECK then
    S.last_sweep = wall()
    each_auto(function(id) mark(id) end)
  end
  pump()
end

-- --- Exports (design v2 section 9) ---

local function next_id()
  local rec = get1('meta/next_id')
  local n = (rec.rev ~= '0' and tonumber(rec.value.n) or 0) + 1
  return tostring(n), {key = 'meta/next_id', if_rev = rec.rev, value = {n = n}}
end

local function save(caller, args)
  only(args, {id = true, if_rev = true, key = true, name = true, enabled = true, trigger = true, action = true, instruction = true})
  local content = {}
  for k, v in pairs(args) do if k ~= 'key' then content[k] = v end end
  local fingerprint = 'save-v1/' .. canon(content)
  local prior = replay('save', caller, args.key, fingerprint)
  if prior then return prior end
  local name = text_arg(args.name, 'name', MAX_NAME)
  local trigger = check_trigger(args.trigger)
  local action = check_action(args.action)
  local instruction = check_instruction(args.instruction)
  local enabled = args.enabled ~= false
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
      auto_rev = args.if_rev
    end
    local st = state_of(st_rec) or {v = 1, gen = 0, next_q = 0, next_manual = 0}
    local trigger_changed = not old or old.trigger.kind ~= trigger.kind or old.trigger.at ~= trigger.at
    local enabling = enabled and (not old or not old.enabled)
    if trigger_changed or (old and old.enabled ~= enabled) then st.gen = (st.gen or 0) + 1 end
    st.enabled = enabled
    -- The baseline moves only on create, enable, a change to daily and a time change (B4). An
    -- unrelated save keeps a due catch-up. daily_high is never cleared.
    if trigger.kind == 'daily' and enabled and (trigger_changed or enabling) then st.daily_base = slot(trigger.at, t) or '' end
    local auto = {v = 1, id = id, name = name, enabled = enabled, gen = st.gen, trigger = trigger, action = action,
      instruction = instruction, by = old and old.by or caller.id, created_at = old and old.created_at or t, updated_at = t}
    local ops = {{key = 'auto/' .. id, if_rev = auto_rev, value = auto}, {key = 'state/' .. id, if_rev = st_rec.rev, value = st}}
    if meta_op then ops[#ops + 1] = meta_op end
    local stored = batch(ops, {key = op_key('save', caller.id, args.key), fingerprint = fingerprint, result = {id = id},
      result_revs = {rev = 'auto/' .. id}})
    local result, conflict = committed(stored, 'a save')
    if result then
      if result.op_exists == nil and result.revs then result = {id = id, rev = result.revs['auto/' .. id]} end
      mark(id)
      pump()
      return result
    end
    if conflict.kind == 'operation' then fail('conflict', 'The key ' .. args.key .. ' was used for other content') end
    if conflict.key == 'auto/' .. id and args.id then fail('conflict', 'Automation ' .. id .. ' is at rev ' .. tostring(conflict.rev)) end
  end
  fail('unavailable', 'The automations changed during the save; try again')
end

local function list(_, args)
  only(args, {after = true})
  if args.after ~= nil then text_arg(args.after, 'after', 64) end
  -- next is the last key in the page: scan's after is exclusive.
  local out, used, next_after, last = {}, 64, nil, args.after
  local keys, records, more = scan('auto/', args.after, 50)
  for _, key in ipairs(keys) do
    local auto = records[key].value
    if type(auto) == 'table' then
      local st = state_of(get1('state/' .. auto.id)) or {}
      local view = {id = auto.id, rev = records[key].rev, name = auto.name, enabled = auto.enabled, trigger = auto.trigger,
        action = auto.action, instruction = auto.instruction, worker = st.worker, spawning = st.spawning and st.spawning.run or nil,
        daily_high = st.daily_high}
      local n = size(view) + 1
      if used + n > PAGE_BUDGET then
        if #out == 0 then fail('too_large', 'Automation ' .. auto.id .. ' is too large to list; use after = "' .. key .. '"') end
        next_after = last
        break
      end
      out[#out + 1] = view
      used = used + n
      last = key
    end
  end
  if not next_after and type(more) == 'string' and more ~= '' then next_after = last end
  return {automations = out, next = next_after}
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
  for _ = 1, 5 do
    local run_rec = get1(run_key)
    local run = run_rec.value
    if run_rec.rev == '0' then fail('not_found', 'No run ' .. run_key) end
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
    -- The notice stays pending while this agent ID has another box entry (not this one).
    local box = box_key(run.agent, run_key)
    local keys = scan('box/' .. run.agent .. '/', nil, 2)
    local others = false
    for _, k in ipairs(keys) do if k ~= box then others = true end end
    local stored = batch({
      {key = run_key, if_rev = run_rec.rev, value = run},
      {key = box, delete = true},
      {key = delivered_key(run.auto, run_key), delete = true},
      {notify = {agent = run.agent, pending = others}},
    }, {key = op_key('done', caller.id, args.key), fingerprint = fingerprint, result = {run_key = run_key, status = run.status}})
    local result, conflict = committed(stored, 'done')
    if result then
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
  ['automations.read'] = read,
  ['automations.done'] = done,
}
local key_arg = {type = 'string', minLength = 1, maxLength = 128, description = 'Your operation key. Retry with the same key and content after an unknown outcome.'}
local exports = {
  {name = 'automations.save', title = 'Create or change an automation',
    description = 'Create an automation (no id) or change one (id and if_rev from automations.list). trigger: {kind = "daily", at = "HH:MM"} (local time). action: {profile (an agent profile from hub.profiles), args?, title?}. instruction: the task text for the agent. A run goes to the automation\'s worker if it runs, else the hub starts one from the profile.',
    args = {type = 'object', properties = {id = {type = 'string', minLength = 1}, if_rev = {type = 'string', minLength = 1},
      key = key_arg, name = {type = 'string', minLength = 1, maxLength = MAX_NAME}, enabled = {type = 'boolean'},
      trigger = {type = 'object'}, action = {type = 'object'}, instruction = {type = 'string', minLength = 1, maxLength = MAX_INSTRUCTION}},
      required = {'key', 'name', 'trigger', 'action', 'instruction'}, additionalProperties = false}},
  {name = 'automations.list', title = 'List automations',
    description = 'List the automations, at most about 40 KB a page: id, rev, name, enabled, trigger, action, instruction, worker, spawning and daily_high. When more exist, next is set: pass it as after.',
    args = {type = 'object', properties = {after = {type = 'string', minLength = 1}}, additionalProperties = false}},
  {name = 'automations.run', title = 'Run an automation now',
    description = 'Make a manual run of an enabled automation. It does not change the daily schedule. A disabled automation is refused.',
    args = {type = 'object', properties = {id = {type = 'string', minLength = 1}, key = key_arg}, required = {'id', 'key'}, additionalProperties = false}},
  {name = 'automations.read', title = 'Read your automation tasks',
    description = 'List the tasks delivered to you: run_key, attempt, token, automation, kind, slot, item and task (instruction, profile, args, title). Reading changes nothing. A task can come again after a worker loss: skip work that is already done. Pages: limit (default 20, at most 50) and about 40 KB; pass next as after.',
    args = {type = 'object', properties = {after = {type = 'string', minLength = 1}, limit = {type = 'integer', minimum = 1, maximum = 50}}, additionalProperties = false}},
  {name = 'automations.done', title = 'Complete an automation task',
    description = 'Complete one of your tasks: run_key and attempt from automations.read. outcome: done (default) or failed. summary: optional, at most 2000 bytes. A task of an earlier attempt is refused (stale_delivery).',
    args = {type = 'object', properties = {run_key = {type = 'string', minLength = 1}, attempt = {type = 'integer', minimum = 1}, key = key_arg,
      outcome = {type = 'string', enum = {'done', 'failed'}}, summary = {type = 'string', maxLength = MAX_SUMMARY}},
      required = {'run_key', 'attempt', 'key'}, additionalProperties = false}},
}

local actions, export_names = {}, {}
for _, e in ipairs(exports) do
  export_names[#export_names + 1] = e.name
  actions[#actions + 1] = {name = e.name, kind = 'client', title = e.title, description = e.description, args = e.args}
end
for _, name in ipairs({'view.render', 'view.action', 'view.seen', 'hub.changed'}) do
  actions[#actions + 1] = {name = name, kind = 'client', title = name, args = {type = 'object', additionalProperties = true}}
end
-- Only the hub can assert the original caller of a forwarded export.
actions[#actions + 1] = {name = 'hub.forward', kind = 'client', title = 'Forward an agent action',
  args = {type = 'object', properties = {action = {type = 'string'}, args = {type = 'object'}, requester_pid = {type = 'integer'}},
    required = {'action', 'args', 'requester_pid'}, additionalProperties = false}}
rex.call('client.keymap', {actions = actions})
hub('hub.register', {plugin = 'automations', instance_id = instance_id, exports = export_names})

rex.on('client_perform_requested', function(ctx, ev)
  local call_id = ev.call_id
  local ok, result = pcall(function()
    if not ev.requester or ev.requester.client_id ~= hub_id then fail('refused', 'Only the hub calls this plugin') end
    local args = ev.args or {}
    if ev.action == 'hub.forward' then
      local handler = agent_handlers[args.action]
      if not handler then fail('refused', 'The forwarded action is not exported') end
      return handler(agent_caller(args.requester_pid), type(args.args) == 'table' and args.args or {})
    end
    if ev.action == 'hub.changed' then
      -- A worker change can finish a pending start or show a lost worker. Reply first; the steps
      -- run in later callbacks.
      if args.what == 'workers' then
        each_auto(function(id) mark(id); S.retry_at[id] = nil end)
        pump()
      end
      return {}
    end
    if ev.action == 'view.seen' then return {} end
    fail('not_supported', 'Unknown action ' .. tostring(ev.action))
  end)
  rex.call('client.reply', {call_id = call_id, result = ok and result or nil,
    error = not ok and (type(result) == 'table' and result or {code = 'internal', message = tostring(result)}) or nil})
end)
rex.call('client.set_label', {label = 'lazyrex-plugin:automations'})

-- Startup work is not in the main chunk: a catch there can split module-level locals.
rex.after(0, function()
  local ok, err = pcall(function()
    S.ready = true
    each_auto(function(id) mark(id) end)
    S.last_sweep = wall()
    tick()
  end)
  if not ok then print('automations: startup: ' .. (type(err) == 'table' and tostring(err.message) or tostring(err))) end
  rex.every(TICK, function()
    local tick_ok, tick_err = pcall(tick)
    if not tick_ok then print('automations: tick: ' .. (type(tick_err) == 'table' and tostring(tick_err.message) or tostring(tick_err))) end
  end)
end)
