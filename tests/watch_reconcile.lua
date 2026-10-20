-- Watch reconcile (design v2 section 6; amendment 1, B1). Each trigger generation has its own
-- watch key a-<id>-<gen>. The reconcile removes every watch that is not desired, by its exact
-- watch_id, then ensures the desired ones. It keeps no watch_id across runs, so a crash or a lost
-- reply at any point repeats it from hub.watch.list.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function body(name, dir, enabled)
  return {name = name, trigger = {kind = 'file', path = dir, glob = '*.md'}, action = {profile = 'worker'},
    instruction = 'Reconcile task.', enabled = enabled}
end

local function create(key, dir)
  local b = body('Reconcile ' .. key, dir)
  b.key = key
  local id = alice:call('automations.save', b).id
  F.watching(alice, id)
  return id
end

-- change saves the automation with another directory or enabled flag. It returns at once: the
-- reconcile runs later.
local function change(id, key, dir, enabled)
  local view = F.view(alice, id)
  local b = body(view.name, dir, enabled)
  b.id, b.if_rev, b.key = id, view.rev, key
  return alice:call('automations.save', b)
end

-- moved checks that only the new directory makes runs: a file in old makes none.
local function moved(id, old, new, tag)
  F.watching(alice, id)
  local before = #F.runs(alice, id, 'f')
  F.put(old .. '/' .. tag .. '-old.md')
  F.put(new .. '/' .. tag .. '-new.md')
  local runs = F.wait_runs(alice, id, before + 1)
  rex.sleep(2)
  runs = F.runs(alice, id, 'f')
  expect(#runs).to_be(before + 1)
  local last
  for _, r in ipairs(runs) do if r.item.name:find(tag, 1, true) then last = r end end
  expect(last.item.name).to_be(tag .. '-new.md')
end

test('a directory change moves the watch; old watches do not count against the limit', function()
  local a, b = F.dir('edit-a'), F.dir('edit-b')
  local id = create('edit', a)
  change(id, 'edit-1', b)
  moved(id, a, b, 'e1')
  -- Nine more changes: each makes a new watch key. Without the removal of the old watch, the
  -- hub's limit of 8 watches would refuse a later ensure.
  for i = 2, 10 do
    change(id, 'edit-' .. i, (i % 2 == 0) and a or b)
    F.watching(alice, id)
  end
  local view = F.watching(alice, id)
  expect(view.watch.state).to_be('active')
  moved(id, b, a, 'e10')
end)

test('a hub crash right after the save: the reconcile runs after the restart', function()
  local a, b = F.dir('crash-a'), F.dir('crash-b')
  local id = create('crash', a)
  change(id, 'crash-1', b)
  hub:restart({crash = true})
  moved(id, a, b, 'c1')
end)

test('a lost remove reply and a lost ensure reply: the reconcile repeats and converges', function()
  local a, b = F.dir('lost-a'), F.dir('lost-b')
  local id = create('lost', a)
  local remove = fault({point = 'action', action = 'hub.watch.remove', when = 'after', mode = 'lose-reply', key = 'a-' .. id .. '-1'})
  local ensure = fault({point = 'action', action = 'hub.watch.ensure', when = 'after', mode = 'lose-reply', key = 'a-' .. id .. '-2'})
  change(id, 'lost-1', b)
  wait('the lost remove reply', function() return fault_fired(remove) end, 10)
  wait('the lost ensure reply', function() return fault_fired(ensure) end, 10)
  moved(id, a, b, 'l1')
end)

test('a crash after the remove and a crash after the ensure', function()
  local a, b = F.dir('step-a'), F.dir('step-b')
  local id = create('step', a)
  local remove = fault({point = 'action', action = 'hub.watch.remove', when = 'after', mode = 'fail', key = 'a-' .. id .. '-1'})
  change(id, 'step-1', b)
  wait('the remove', function() return fault_fired(remove) end, 10)
  hub:restart({crash = true})
  moved(id, a, b, 's1')
  local ensure = fault({point = 'action', action = 'hub.watch.ensure', when = 'after', mode = 'fail', key = 'a-' .. id .. '-3'})
  change(id, 'step-2', a)
  wait('the ensure', function() return fault_fired(ensure) end, 10)
  hub:restart({crash = true})
  moved(id, b, a, 's2')
end)

-- Disable removes the watch. Enable makes a new one (a new gen), whose baseline holds the files
-- that came while it was disabled: they make no run.
test('disable, then enable: files from the disabled time are the baseline', function()
  local dir = F.dir('toggle')
  local id = create('toggle', dir)
  change(id, 'toggle-off', dir, false)
  wait('the disabled automation', function() return F.view(alice, id).enabled == false end, 10)
  rex.sleep(2)
  F.put(dir .. '/while-off.md')
  rex.sleep(1)
  change(id, 'toggle-on', dir, true)
  F.watching(alice, id)
  F.put(dir .. '/after-on.md')
  local runs = F.wait_runs(alice, id, 1)
  rex.sleep(2)
  runs = F.runs(alice, id, 'f')
  expect(#runs).to_be(1)
  expect(runs[1].item.name).to_be('after-on.md')
end)
