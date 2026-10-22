-- Presets. A preset installs
-- once: preset/<name> = {id} commits with if_rev '0' in the save batch. The delete fence deletes
-- it only when it names that automation, so a reinstall during an old cleanup stays.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')
-- HOME is LAB/home in the lab, so this is ~/knowledge, the cwd of both presets.
local KNOWLEDGE = H.args.lab .. '/home/knowledge'
local made = rex.exec({'mkdir', '-p', KNOWLEDGE})
assert(made and made.ok, 'mkdir failed')

local HEALTH = 'The nightly vault health check is due. Run it as this repository\'s instructions say, and report the results. This run can come again: if tonight\'s check is already done, say so. Call automations_done when you finish.'
local INBOX = 'A new note arrived in the vault inbox. The task item has its name and path. Process it as this repository\'s instructions say. The same note can come again in a later run: if it is already processed, skip it. Call automations_done when you finish.'

local function presets()
  local out = {}
  for _, p in ipairs(alice:call('automations.presets', {}).presets) do out[p.preset] = p end
  return out
end
local function install(name, key)
  local p = presets()[name]
  return alice:call('automations.save', {key = key, preset = name, name = p.name, trigger = p.trigger,
    action = {profile = 'worker', cwd = p.action.cwd}, instruction = p.instruction}).id
end
local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function gone(id) wait('automation ' .. id .. ' to be gone', function() return F.auto(id) == nil end, 30) end
local function preset_item(name)
  local _, tree = F.panel()
  return F.item(tree, 'presets', name)
end

test('presets list their fields; an install replays, a second install is a conflict, and an edit keeps the preset', function()
  local p = presets()
  expect(p['vault-health'].name).to_be('Vault health')
  expect(p['vault-health'].trigger.kind).to_be('daily')
  expect(p['vault-health'].trigger.at).to_be('22:00')
  expect(p['vault-health'].action.cwd).to_be('~/knowledge')
  expect(p['vault-health'].instruction).to_be(HEALTH)
  expect(p['vault-inbox'].trigger.path).to_be('~/knowledge/inbox')
  expect(p['vault-inbox'].trigger.glob).to_be('*.md')
  expect(p['vault-inbox'].instruction).to_be(INBOX)
  expect(p['vault-health'].installed).to_be(nil)
  expect(preset_item('vault-health').action.enabled).to_be(true)
  local id = install('vault-health', 'health-1')
  expect(install('vault-health', 'health-1')).to_be(id)
  expect(presets()['vault-health'].installed).to_be(id)
  expect(F.preset('vault-health')).to_be(id)
  expect(F.view(alice, id).preset).to_be('vault-health')
  local err = expect_error(function() install('vault-health', 'health-2') end, 'conflict')
  expect(err.message).to_match('installed as automation ' .. id)
  local item = preset_item('vault-health')
  expect(item.action.enabled).to_be(false)
  expect(item.detail).to_match('automation ' .. id)
  -- The agent face checks the schema enum first.
  expect_error(function() alice:call('automations.save', {key = 'bad', preset = 'other', name = 'x', trigger = {kind = 'daily', at = '01:00'},
    action = {profile = 'worker'}, instruction = 'x'}) end, 'bad_request')
  -- An edit changes the fields and keeps the preset; the identity is the record.
  local a = F.view(alice, id)
  alice:call('automations.save', {id = id, if_rev = a.rev, key = 'health-edit', name = 'My health', trigger = {kind = 'daily', at = '21:30'},
    action = a.action, instruction = a.instruction})
  a = F.view(alice, id)
  expect(a.name).to_be('My health')
  expect(a.trigger.at).to_be('21:30')
  expect(a.preset).to_be('vault-health')
  expect(presets()['vault-health'].installed).to_be(id)
  expect_error(function() alice:call('automations.save', {id = id, if_rev = a.rev, key = 'health-other', preset = 'vault-inbox', name = a.name,
    trigger = a.trigger, action = a.action, instruction = a.instruction}) end, 'not from preset vault%-inbox')
end)

-- Another install commits just before the save batch (the injection runs when the plugin begins
-- the batch transaction, after its reads): the save refuses and stores nothing.
test('a concurrent install makes the save refuse, and it stores nothing', function()
  local _, before = F.next_id()
  local count = #alice:call('automations.list', {}).automations
  local inj = F.inject_begin({{tbl = 'presets', key = 'vault-inbox', value = '999'}})
  local err = expect_error(function() install('vault-inbox', 'inbox-race') end, 'conflict')
  expect(err.message).to_match('installed as automation 999')
  expect(injection(inj).consumed).to_be(1)
  expect(select(2, F.next_id())).to_be(before)
  expect(#alice:call('automations.list', {}).automations).to_be(count)
  F.write({{tbl = 'presets', key = 'vault-inbox', delete = true}})
end)

-- The overlap: a reinstall while the old automation's cleanup waits for its active run. The old
-- cleanup ends and leaves the new reservation.
test('delete, then the preset installs again; an old cleanup keeps the new reservation', function()
  local old = presets()['vault-health'].installed
  alice:call('automations.delete', {id = old, key = 'health-delete-1'})
  expect(presets()['vault-health'].installed).to_be(nil)
  expect(preset_item('vault-health').action.enabled).to_be(true)
  local b = install('vault-health', 'health-3')
  expect(b).not_to_be(old)
  gone(old)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = 'automations/spawn/' .. manual(b, 1) .. '/1'})
  alice:call('automations.run', {id = b, key = 'health-run-b'})
  wait('the gated start', function() return fault_fired(gate) end, 10)
  alice:call('automations.delete', {id = b, key = 'health-delete-b'})
  local c = install('vault-health', 'health-4')
  local reserved, reserved_rev = F.preset('vault-health'), F.rev('presets', 'vault-health')
  expect(reserved).to_be(c)
  fault_release(gate)
  local run = F.wait_status(manual(b, 1), 'delivered')
  F.worker(run.agent):call('automations.done', {run_key = manual(b, 1), attempt = run.attempt, key = 'health-done-b'})
  gone(b)
  local after, after_rev = F.preset('vault-health'), F.rev('presets', 'vault-health')
  expect(after).to_be(c)
  expect(after_rev).to_be(reserved_rev)
  expect(preset_item('vault-health').action.enabled).to_be(false)
  alice:call('automations.delete', {id = c, key = 'health-delete-c'})
  gone(c)
end)

-- The user's path: Add on the panel, the profile, the preset's fields, then Run now in the view.
-- The worker starts in ~/knowledge and reads the preset's instruction.
test('the preset through the forms starts its worker in ~/knowledge', function()
  local p = F.panel()
  local s1 = F.view_of(F.ok(p:action('presets', 'add', {item_id = 'vault-health'})).form)
  local route = F.ok(s1:action('profile', 'submit', {values = {profile = 'worker'}})).form
  expect(route).to_be('/forms/automation/preset/vault-health?profile=worker')
  local s2, tree = F.view_of(route)
  local values = {}
  for _, f in ipairs(node(tree, 'automation').fields) do values[f.id] = f.value end
  expect(values.name).to_be('Vault health')
  expect(values.trigger).to_be('daily')
  expect(values.at).to_be('22:00')
  expect(values.cwd).to_be('~/knowledge')
  expect(values.instruction).to_be(HEALTH)
  expect(F.ok(s2:action('automation', 'submit', {values = values})).close_form).to_be(true)
  local id = presets()['vault-health'].installed
  expect(F.view(alice, id).action.cwd).to_be(KNOWLEDGE)
  local v = F.open(id)
  F.ok(v:action('run', 'run'))
  local run = F.wait_status(manual(id, 1), 'delivered')
  local cwd
  for _, w in ipairs(F.workers()) do if w.spawn_id == run.spawn_id then cwd = w.cwd end end
  expect(cwd == KNOWLEDGE or cwd == '/private' .. KNOWLEDGE).to_be(true)
  local tasks = F.worker(run.agent):call('automations.read', {}).tasks
  expect(#tasks).to_be(1)
  expect(tasks[1].task.cwd).to_be(KNOWLEDGE)
  expect(tasks[1].task.instruction).to_be(HEALTH)
end)

-- The lab grants only LAB/inbox (test.watch_roots), so the vault inbox watch is refused, and the
-- panel and list show the grant hint. The hub refuses a missing directory first (watch_missing),
-- so the test makes it.
test('vault-inbox shows its refused watch with the grant hint', function()
  local r = rex.exec({'mkdir', '-p', KNOWLEDGE .. '/inbox'})
  assert(r and r.ok, 'mkdir failed')
  local before = invalidates()
  local id = install('vault-inbox', 'inbox-1')
  local a = wait('the refused watch', function()
    local x = F.view(alice, id)
    return x and x.watch and x.watch.state == 'refused' and x
  end, 20)
  expect(a.watch.code).to_be('watch_not_granted')
  -- A watch state is not in the store, so the plugin asks the hub to render its views again.
  wait('a view invalidation', function() return invalidates() > before end, 10)
  expect(a.watch.hint).to_match('watch_roots')
  expect(a.trigger.path).to_be(KNOWLEDGE .. '/inbox')
  local _, tree = F.panel()
  expect(F.item(tree, 'automations', id).detail).to_match('watch_roots')
end)
