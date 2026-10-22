-- The panel and the automation view, through the hub's real
-- view path: admission, durable operations and effects. Each view action calls the same handler
-- as its agent tool; the agent path of each tool has its own tests (lifecycle.lua, action.lua).
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
local T0 = F.at(2026, 11, 3, 10, 0)
F.set_clock(T0)
local alice = agent('alice')

-- A daily automation at 09:00, created at 10:00: no run today.
local function automation(key, name)
  return alice:call('automations.save', {key = key, name = name or ('Panel ' .. key), trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Panel task.'}).id
end
local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
local function spawn_key(id, n) return 'automations/spawn/' .. manual(id, n) .. '/1' end
-- hold gates the first start of an automation's manual run 1, so the runs after it stay queued.
local function hold(id)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = spawn_key(id, 1)})
  alice:call('automations.run', {id = id, key = 'hold-' .. id})
  wait('the gated start of automation ' .. id, function() return fault_fired(gate) end, 10)
  return gate
end
local function item_ids(tree, list)
  local out = {}
  for _, item in ipairs(F.items(tree, list)) do out[#out + 1] = item.id end
  return out
end

test('the panel pages 25 automations; a run of an automation on page 2 is cancelled from its view', function()
  local ids = {}
  for n = 1, 25 do ids[#ids + 1] = automation('page-' .. n) end
  local p, one = F.panel()
  expect(#F.items(one, 'automations')).to_be(20)
  expect(node(one, 'next_page')).to_be_truthy()
  expect(node(one, 'first_page')).to_be(nil)
  expect(F.size(one) < 40 * 1024).to_be(true)
  local p2, two = F.view_of(F.ok(p:action('next_page', 'next')).panel.route)
  expect(#F.items(two, 'automations')).to_be(5)
  expect(node(two, 'next_page')).to_be(nil)
  expect(node(two, 'first_page')).to_be_truthy()
  local seen = {}
  for _, tree in ipairs({one, two}) do
    for _, id in ipairs(item_ids(tree, 'automations')) do
      expect(seen[id]).to_be(nil)
      seen[id] = true
    end
  end
  for _, id in ipairs(ids) do expect(seen[id]).to_be(true) end
  -- The last automation of page 2: its queued run is cancelled from its view.
  local items = F.items(two, 'automations')
  local last = items[#items].id
  local gate = hold(last)
  local v = F.view_of(F.ok(p2:action('automations', 'open', {item_id = last})).form)
  F.ok(v:action('run', 'run'))
  expect(F.wait_status(manual(last, 2), 'queued').by).to_be('user')
  local tree = v:render()
  local queued = F.item(tree, 'runs', manual(last, 2))
  expect(queued.action.name).to_be('cancel')
  expect(queued.action.tool).to_be('automations.cancel_run')
  expect(F.item(tree, 'runs', manual(last, 1)).status).to_be('starting')
  F.ok(v:action('runs', 'cancel', {item_id = manual(last, 2)}))
  expect(F.run(manual(last, 2)).status).to_be('cancelled')
  fault_release(gate)
  F.wait_status(manual(last, 1), 'delivered')
end)

test('a view with 25 queued runs reaches the last one on its second page', function()
  local id = automation('many')
  local gate = hold(id)
  for n = 2, 26 do alice:call('automations.run', {id = id, key = 'many-' .. n}) end
  local v, one = F.open(id)
  local runs = F.items(one, 'runs')
  expect(#runs).to_be(20)
  -- The starting run comes first, then the queue in order.
  expect(runs[1].id).to_be(manual(id, 1))
  expect(runs[2].id).to_be(manual(id, 2))
  expect(runs[20].id).to_be(manual(id, 20))
  expect(node(one, 'more_runs')).to_be_truthy()
  local v2, two = F.view_of(F.ok(v:action('more_runs', 'more')).form)
  runs = F.items(two, 'runs')
  expect(#runs).to_be(6)
  expect(runs[6].id).to_be(manual(id, 26))
  expect(node(two, 'more_runs')).to_be(nil)
  expect(node(two, 'first_runs')).to_be_truthy()
  F.ok(v2:action('runs', 'cancel', {item_id = manual(id, 26)}))
  expect(F.run(manual(id, 26)).status).to_be('cancelled')
  fault_release(gate)
end)

test('retry is disabled while the automation is disabled', function()
  local id = automation('retry')
  local gate = hold(id)
  alice:call('automations.run', {id = id, key = 'retry-2'})
  alice:call('automations.cancel_run', {run_key = manual(id, 2), key = 'retry-cancel'})
  local v, tree = F.open(id)
  expect(F.item(tree, 'runs', manual(id, 2)).action.enabled).to_be(true)
  F.ok(v:action('enabled', 'disable'))
  expect(F.auto(id).enabled).to_be(false)
  tree = v:render()
  local cancelled = F.item(tree, 'runs', manual(id, 2))
  expect(cancelled.action.name).to_be('retry')
  expect(cancelled.action.enabled).to_be(false)
  expect(cancelled.detail).to_match('enable the automation first')
  expect(node(tree, 'run').action.enabled).to_be(false)
  expect(node(tree, 'enabled').action.name).to_be('enable')
  expect_error(function() alice:call('automations.retry', {run_key = manual(id, 2), key = 'retry-agent'}) end, 'disabled')
  F.ok(v:action('enabled', 'enable'))
  tree = v:render()
  expect(F.item(tree, 'runs', manual(id, 2)).action.enabled).to_be(true)
  F.ok(v:action('runs', 'retry', {item_id = manual(id, 2)}))
  expect(F.run(manual(id, 2)).status).to_be('queued')
  fault_release(gate)
  F.wait_status(manual(id, 2), 'delivered')
end)

-- The edit route carries the rev: a save after another change is refused, and the message says
-- to reopen. The failed submit keeps the form open (no close_form effect).
test('an edit after another change is refused and says to reopen; a current edit saves', function()
  local id = automation('edit', 'Before')
  local v = F.open(id)
  local route = F.ok(v:action('edit', 'edit')).form
  expect(route).to_match('^/forms/automation/edit/' .. id .. '%?rev=%d+$')
  local e, tree = F.view_of(route)
  expect(F.field(tree, 'automation', 'name').value).to_be('Before')
  expect(F.field(tree, 'automation', 'at').value).to_be('09:00')
  expect(node(tree, 'stale')).to_be(nil)
  local a = F.view(alice, id)
  alice:call('automations.save', {id = id, if_rev = a.rev, key = 'edit-agent', name = 'Agent name', trigger = a.trigger,
    action = a.action, instruction = a.instruction})
  tree = e:render()
  expect(node(tree, 'stale').text).to_match('reopen the automation')
  local values = {name = 'User name', enabled = true, trigger = 'daily', at = '08:15', glob = '*', path = '', cwd = '', title = '',
    instruction = 'Edited task.'}
  local op = e:action('automation', 'submit', {values = values})
  expect(op.status).to_be('failed')
  expect(op.error.code).to_be('conflict')
  expect(op.error.message).to_match('reopen it to edit the current version')
  expect(F.view(alice, id).name).to_be('Agent name')
  expect(user:view(route)).to_be_truthy()
  -- Reopen: the new route has the current rev, and the save commits and closes the form.
  local v2 = F.open(id)
  local e2 = F.view_of(F.ok(v2:action('edit', 'edit')).form)
  expect(F.ok(e2:action('automation', 'submit', {values = values})).close_form).to_be(true)
  local saved = F.view(alice, id)
  expect(saved.name).to_be('User name')
  expect(saved.trigger.at).to_be('08:15')
  expect(saved.instruction).to_be('Edited task.')
end)

-- A deleting automation: the panel shows "(deleting)", and its view has only the runs, with
-- Cancel and Dismiss. Dismiss of the pending start lets the cleanup end.
test('a deleting automation shows only its runs; dismiss from its view ends the cleanup', function()
  local id = automation('deleting', 'Doomed')
  local drop = fault({point = 'spawn-create', mode = 'drop', op = spawn_key(id, 1)})
  alice:call('automations.run', {id = id, key = 'deleting-1'})
  wait('the dropped spawn', function() return fault_fired(drop) end, 10)
  F.wait_status(manual(id, 1), 'starting')
  F.set_clock(T0 + 601)
  F.wait_status(manual(id, 1), 'unknown_start')
  local v, tree = F.open(id)
  expect(F.item(tree, 'runs', manual(id, 1)).action.name).to_be('dismiss')
  local d, confirm = F.view_of(F.ok(v:action('delete', 'delete')).form)
  expect(node(confirm, 'warning').text).to_match('also deletes its run history')
  expect(F.ok(d:action('delete_automation', 'submit', {values = {id = id}})).close_form).to_be(true)
  expect(F.auto(id).deleted).to_be(true)
  -- automations.list lists the tombstone only with deleted = true.
  local listed
  for _, a in ipairs(alice:call('automations.list', {deleted = true}).automations) do if a.id == id then listed = a end end
  expect(listed.status).to_be('deleting')
  expect(F.view(alice, id)).to_be(nil)
  local panel = F.panel()
  local p_tree = panel:render()
  local found
  for _ = 1, 3 do
    found = F.item(p_tree, 'automations', id)
    if found or not node(p_tree, 'next_page') then break end
    panel, p_tree = F.view_of(F.ok(panel:action('next_page', 'next')).panel.route)
  end
  expect(found.label).to_be('Doomed (deleting)')
  v, tree = F.view_of(F.ok(panel:action('automations', 'open', {item_id = id})).form)
  expect(node(tree, 'run')).to_be(nil)
  expect(node(tree, 'edit')).to_be(nil)
  expect(node(tree, 'enabled')).to_be(nil)
  expect(node(tree, 'delete')).to_be(nil)
  expect(F.item(tree, 'runs', manual(id, 1)).action.name).to_be('dismiss')
  F.ok(v:action('runs', 'dismiss', {item_id = manual(id, 1)}))
  wait('the cleanup to end', function() return F.auto(id) == nil end, 20)
  expect(node(v:render(), 'gone')).to_be_truthy()
  F.set_clock(T0)
end)
