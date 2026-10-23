-- Read tracking (hub 4.2 default): a view that is already open and subscribed gets the new tree
-- with no render request from the test. The test reads the renderer's snapshot (v:get()) and the
-- render causes (renders()); the profiles case also sends a focus event (v:seen), as the
-- renderer does.
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

test('a start refusal asks for an invalidate render of an open panel', function()
  local p = F.panel()
  local base = invalidates(p)
  local rev = sql("SELECT value FROM meta WHERE name = 'rev'")[1].value
  -- A revision counter that is not valid: the start refuses and writes nothing. The registration
  -- render can also show the refusal text; the invalidate render comes from app.refresh after the
  -- refusal.
  F.reload(function() F.sql_write("UPDATE meta SET value = '12a' WHERE name = 'rev'") end)
  wait('the refusal text and an invalidate render', function()
    local n = H.node(snapshot(p), 'not_ready')
    return n and tostring(n.text):find('cannot start', 1, true) ~= nil and invalidates(p) > base
  end, 20)
  expect_error(function() agent('alice'):call('automations.list', {}) end, 'unavailable')
  F.reload(function() F.sql_write("UPDATE meta SET value = ? WHERE name = 'rev'", {rev}) end)
  wait('the panel opens again', function() return H.node(snapshot(p), 'not_ready') == nil end, 20)
end)
