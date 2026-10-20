-- Restart coverage (restart plan, review of adf74bf). These are blocked-commit recovery tests,
-- not outage tests: the old hub runs, but an injection fails every batch that would make the
-- due run, so the slot stays pending. Then the hub crashes; the injections live in hub memory,
-- so the new hub is the first that can commit the run. A true outage is a separate manual lab
-- check.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 8, 0))
local alice = agent('alice')

local function daily(key, at)
  return alice:call('automations.save', {key = key, name = 'Restart ' .. key, trigger = {kind = 'daily', at = at},
    action = {profile = 'worker'}, instruction = 'Restart task.'}).id
end
local function day_key(id, day) return 'run/' .. id .. '/d/' .. day end
local function blocked(id, day)
  return inject({match = {writes = day_key(id, day)}, fail = 'blocked for the restart test', fail_code = 'unavailable', times = 'always'})
end
local function slots(id)
  local out = {}
  for _, r in ipairs(F.runs(alice, id, 'd')) do out[#out + 1] = r.slot end
  table.sort(out)
  return table.concat(out, ' ')
end
local function crash_and_settle()
  hub:restart({crash = true})
  rex.sleep(5)
end

test('a daily slot blocked until a crash runs exactly once after the restart', function()
  local id = daily('one', '09:00')
  local inj = blocked(id, '2026-11-03')
  F.set_clock(F.at(2026, 11, 3, 9, 30))
  wait('the blocked run batch', function() return injection(inj).consumed >= 1 end, 20)
  expect(store(day_key(id, '2026-11-03')).rev).to_be('0')
  expect(store('state/' .. id).value.daily_high).to_be(nil)
  hub:restart({crash = true})
  wait('the catch-up run', function() return store(day_key(id, '2026-11-03')).rev ~= '0' end, 20)
  rex.sleep(5)
  expect(slots(id)).to_be('2026-11-03')
  expect(store('state/' .. id).value.daily_high).to_be('2026-11-03')
  crash_and_settle()
  expect(slots(id)).to_be('2026-11-03')
end)

-- The clock jumps three dates: only the newest date is due, so only its batch is tried.
test('after a jump over several dates, only the newest date runs, once', function()
  local id = daily('jump', '10:00')
  local skipped = {blocked(id, '2026-11-03'), blocked(id, '2026-11-04'), blocked(id, '2026-11-05')}
  local inj = blocked(id, '2026-11-06')
  F.set_clock(F.at(2026, 11, 6, 10, 30))
  wait('the blocked run batch', function() return injection(inj).consumed >= 1 end, 20)
  for _, s in ipairs(skipped) do expect(injection(s).consumed).to_be(0) end
  expect(slots(id)).to_be('')
  expect(store('state/' .. id).value.daily_high).to_be(nil)
  hub:restart({crash = true})
  wait('the catch-up run', function() return store(day_key(id, '2026-11-06')).rev ~= '0' end, 20)
  rex.sleep(5)
  expect(slots(id)).to_be('2026-11-06')
  expect(store('state/' .. id).value.daily_high).to_be('2026-11-06')
  crash_and_settle()
  expect(slots(id)).to_be('2026-11-06')
end)

-- The delete fence and a preset reinstall across a crash: A's cleanup ends after its run, and
-- B's reservation stays.
test('a crash after a delete and a preset reinstall: the old cleanup ends, the new reservation stays', function()
  local made = rex.exec({'mkdir', '-p', H.args.lab .. '/home/knowledge'})
  assert(made and made.ok, 'mkdir failed')
  local function install(key)
    local p
    for _, x in ipairs(alice:call('automations.presets', {}).presets) do if x.preset == 'vault-health' then p = x end end
    return alice:call('automations.save', {key = key, preset = 'vault-health', name = p.name, trigger = p.trigger,
      action = {profile = 'worker', cwd = p.action.cwd}, instruction = p.instruction}).id
  end
  local a = install('preset-a')
  local run = 'run/' .. a .. '/m/000001'
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = 'automations/spawn/' .. run .. '/1'})
  alice:call('automations.run', {id = a, key = 'preset-a-run'})
  wait('the gated start', function() return fault_fired(gate) end, 10)
  alice:call('automations.delete', {id = a, key = 'preset-a-delete'})
  local b = install('preset-b')
  -- The boundary before the crash: A's fence, B's reservation and the held start.
  expect(store('auto/' .. a).value.deleted).to_be(true)
  expect(store('state/' .. a).value.deleted).to_be(true)
  expect(store('state/' .. a).value.spawning.run).to_be(run)
  expect(store(run).value.status).to_be('starting')
  local reserved = store('preset/vault-health')
  expect(reserved.value.id).to_be(b)
  hub:restart({crash = true})
  -- The gate is gone with the old hub: the stored start replays and delivers.
  local delivered = F.wait_status(run, 'delivered', 30)
  F.worker(delivered.agent):call('automations.done', {run_key = run, attempt = delivered.attempt, key = 'preset-a-done'})
  wait('A to be purged', function() return store('auto/' .. a).rev == '0' and store('state/' .. a).rev == '0' end, 30)
  local after = store('preset/vault-health')
  expect(after.value.id).to_be(b)
  expect(after.rev).to_be(reserved.rev)
  local _, tree = F.panel()
  local item = F.item(tree, 'presets', 'vault-health')
  expect(item.action.enabled).to_be(false)
  expect(item.detail).to_match('automation ' .. b)
  expect(F.item(tree, 'automations', b)).to_be_truthy()
end)

-- Run now through the view, cut by a crash (amendment (b)). F1 lets the run batch commit and
-- loses its reply, so the plugin answers unavailable (an unknown outcome) and the hub keeps the
-- operation pending. F2 refuses every later replay check of the operation record, so the hub's
-- retries stay unknown until the crash. After the restart, the hub resumes the operation with the
-- same key and stored args (hub viewsvc.go at 06b22ca); the plugin replays its op record.
test('Run now cut by a crash: the hub resumes the same operation, and there is one run', function()
  local id = daily('view', '09:00')
  local v = F.open(id)
  local key = 'crash-run-now'
  local record = 'run/' .. #'user' .. ':user' .. #('view/' .. key) .. ':view/' .. key
  local f1 = fault({point = 'action', action = 'hub.store.batch', when = 'after', mode = 'lose-reply'})
  local f2 = fault({point = 'action', action = 'hub.store.op', when = 'before', mode = 'gate', key = record, nth = 2})
  v:admit('action', {node_id = 'run', action = 'run', input = {}, revision = v.revision, operation_key = key})
  wait('the refused replay check', function() return fault_fired(f2) end, 20)
  -- The boundary before the crash: the batch committed, both faults fired, the operation pending.
  expect(fault_fired(f1)).to_be(true)
  expect(store('run/' .. id .. '/m/000001').rev).not_to_be('0')
  expect(store('state/' .. id).value.next_manual).to_be(1)
  expect(operation(key).status).to_be('pending')
  hub:restart({crash = true})
  local done = wait('the resumed operation', function()
    local s = operation(key)
    return s.status ~= 'pending' and s
  end, 30)
  expect(done.status).to_be('succeeded')
  expect(store('state/' .. id).value.next_manual).to_be(1)
  expect(#F.runs(alice, id, 'm')).to_be(1)
  expect(store('run/' .. id .. '/m/000002').rev).to_be('0')
  crash_and_settle()
  expect(#F.runs(alice, id, 'm')).to_be(1)
  expect(store('state/' .. id).value.next_manual).to_be(1)
end)
