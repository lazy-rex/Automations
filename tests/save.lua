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
      local value = store(manual.run_key).value
      return value and (value.status == 'delivered' or value.status == 'failed') and value
    end, 20)
    expect(run.status).to_be('delivered')
  end
end)

-- The reviewer's case for 3b2cba7 (R2): save refuses it and stores nothing.
test('a title of 61 characters is refused before anything is stored', function()
  local before, next_id = count(), store('meta/next_id').rev
  expect_error(function() save('title-61', string.rep('t', 61)) end, 'invalid_input')
  expect_error(function() save('title-61-wide', string.rep('é', 61)) end, 'invalid_input')
  expect(count()).to_be(before)
  expect(store('meta/next_id').rev).to_be(next_id)
end)
