-- Save checks the action against the hub's own contract before it stores the automation, so a
-- saved automation never fails at its first start for a reason that save could see.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function count() return #alice:call('automations.list', {}).automations end

local function save(key, title)
  return alice:call('automations.save', {key = key, name = 'Title ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker', title = title}, instruction = 'Title task.'})
end

-- hub.spawn allows a title of at most 60 characters (hub workers.go at 06b22ca), counted as
-- Unicode characters, not bytes.
test('a title of 60 characters is accepted and its worker starts', function()
  local ascii = save('title-60', string.rep('t', 60))
  local wide = save('title-60-wide', string.rep('é', 60))
  for _, id in ipairs({ascii.id, wide.id}) do
    local manual = alice:call('automations.run', {id = id, key = 'title-run-' .. id})
    local run = wait('the run of ' .. id .. ' to finish its start', function()
      local value = F.run(manual.run_key)
      return value and (value.status == 'delivered' or value.status == 'failed') and value
    end, 20)
    expect(run.status).to_be('delivered')
  end
end)

-- The reviewer's case for 3b2cba7 (R2): save refuses it and stores nothing.
test('a title of 61 characters is refused before anything is stored', function()
  local before, next_id = count(), select(2, F.next_id())
  expect_error(function() save('title-61', string.rep('t', 61)) end, 'invalid_input')
  expect_error(function() save('title-61-wide', string.rep('é', 61)) end, 'invalid_input')
  expect(count()).to_be(before)
  expect(select(2, F.next_id())).to_be(next_id)
end)

local function file_save(key, path, enabled)
  return alice:call('automations.save', {key = key, name = 'Watch ' .. key, enabled = enabled,
    trigger = {kind = 'file', path = path}, action = {profile = 'worker'}, instruction = 'Watch task.'})
end

-- The hub allows 8 watches per plugin (docs/hub.md, "Limits"): one per enabled file automation.
test('the 9th enabled file automation is refused; a disabled one is accepted', function()
  local ids = {}
  for i = 1, 8 do ids[i] = file_save('limit-' .. i, F.dir('limit-' .. i)).id end
  for _, id in ipairs(ids) do F.watching(alice, id) end
  local before = count()
  expect_error(function() file_save('limit-9', F.dir('limit-9')) end, 'limit')
  expect(count()).to_be(before)
  local off = file_save('limit-9-off', F.dir('limit-9'), false)
  expect(F.view(alice, off.id).enabled).to_be(false)
  -- Free one place: disable an enabled one.
  local view = F.view(alice, ids[8])
  alice:call('automations.save', {id = ids[8], if_rev = view.rev, key = 'limit-8-off', name = view.name, enabled = false,
    trigger = view.trigger, action = view.action, instruction = view.instruction})
end)

-- ~ expands with HOME at save. HOME is outside the lab's watch_roots, so the ensure is refused,
-- and list names the config field.
test('~ expands with HOME, and a path outside watch_roots shows the grant hint', function()
  local home = os.getenv('HOME')
  local id = file_save('home', '~').id
  local view = wait('the refused watch', function()
    local v = F.view(alice, id)
    return v.watch and v.watch.state ~= 'pending' and v
  end, 20)
  if home then expect(view.trigger.path).to_be(home) end
  expect(view.trigger.path:sub(1, 1)).to_be('/')
  expect(view.watch.state).to_be('refused')
  expect(view.watch.code).to_be('watch_not_granted')
  expect(view.watch.hint).to_match('watch_roots')
  expect_error(function() file_save('relative', 'notes/inbox') end, 'invalid_input')
  expect_error(function() file_save('unclean', F.dir('x') .. '/../x') end, 'invalid_input')
end)

-- Rex Lua: table.concat of more than 2559 items fails with "registry overflow" (hub
-- docs/rex-protocol.md). The save fingerprint encodes its args before they are checked, so a
-- trigger with a long list must get the refusal of a bad trigger, not an internal error.
test('a trigger with a list of 3000 items is refused as invalid input', function()
  local before = count()
  local list = {}
  for n = 1, 3000 do list[n] = n end
  local err = expect_error(function() alice:call('automations.save', {key = 'long-list', name = 'Long list',
    trigger = {kind = 'daily', at = '09:00', extra = list}, action = {profile = 'worker'}, instruction = 'Long list task.'}) end, 'invalid_input')
  expect(err.message:find('registry', 1, true)).to_be(nil)
  expect(count()).to_be(before)
end)

-- The object path of the same join: action.args with 3000 keys. The check of action.args (at most
-- 512 bytes encoded) refuses it after the fingerprint.
test('action args with 3000 keys are refused as invalid input', function()
  local before = count()
  local args = {}
  for n = 1, 3000 do args['k' .. n] = 'v' end
  local err = expect_error(function() alice:call('automations.save', {key = 'many-args', name = 'Many args',
    trigger = {kind = 'daily', at = '09:00'}, action = {profile = 'worker', args = args}, instruction = 'Many args task.'}) end, 'invalid_input')
  expect(err.message:find('registry', 1, true)).to_be(nil)
  expect(count()).to_be(before)
end)
