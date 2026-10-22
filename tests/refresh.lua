-- Read tracking (hub 4.2 default): a view that is already open and subscribed gets the new tree
-- with no render request from the test. The test reads only the renderer's snapshot (v:get()) and
-- the render causes (renders()).
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))

local function count(v)
  for _, c in ipairs(renders()) do
    if c.view_id == v.id then return c end
  end
  return {attempts = 0, causes = {}}
end
local function invalidates(v) return count(v).causes.invalidate or 0 end
local function snapshot(v) return (v:get() or {}).tree or {nodes = {}} end
local function options(tree)
  local out = {}
  local form = H.node(tree, 'profile')
  for _, f in ipairs(form and form.fields or {}) do
    if f.id == 'profile' then
      for _, o in ipairs(f.options or {}) do out[o.value] = true end
    end
  end
  return out
end

test('a new agent profile shows in an open profile picker with no plugin handler', function()
  user:command('new_automation')
  local v = F.view_of('/forms/automation/new')
  expect(options(snapshot(v)).worker).to_be(true)
  expect(options(snapshot(v)).extra).to_be(nil)
  local list = F.profile_list()
  list[#list + 1] = {id = 'extra', name = 'Extra', kind = 'agent', command = {'/bin/sh', '-c', 'exec tail -f /dev/null'}}
  H.write_profiles({profiles = list})
  -- The hub checks the profiles file when a view gets focus (or a caller lists profiles).
  v:seen('focus')
  wait('the picker shows the new profile', function() return options(snapshot(v)).extra == true end, 10)
  F.profiles()
  v:seen('focus')
  wait('the picker drops the profile', function() return options(snapshot(v)).extra == nil end, 10)
end)

test('the start refusal text replaces the starting text in an open panel', function()
  local p = F.panel()
  local base = invalidates(p)
  -- An unknown import marker: the start refuses and writes nothing.
  F.reload(function() F.sql_write("UPDATE meta SET value = 'refresh-test:unknown' WHERE name = 'import'") end)
  wait('the panel shows the refusal', function()
    local n = H.node(snapshot(p), 'not_ready')
    return n and tostring(n.text):find('cannot start', 1, true) ~= nil
  end, 20)
  -- The refusal reached the view through app.refresh, not through a commit or the registration.
  expect(invalidates(p) > base).to_be(true)
  expect_error(function() agent('alice'):call('automations.list', {}) end, 'unavailable')
  F.reload(function() F.sql_write("UPDATE meta SET value = 'cutover-1:done' WHERE name = 'import'") end)
  wait('the panel opens again', function() return H.node(snapshot(p), 'not_ready') == nil end, 20)
end)
