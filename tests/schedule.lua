-- The daily schedule (design v2 section 7; amendment 1, B4). daily_high is the newest date that
-- got a daily run; daily_base moves only on create, enable, a change to daily and a time change.
-- A date runs only when it is newer than both. The lab time zone is PST8PDT (manifest test.env).
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
local alice = agent('alice')

local function daily(key, at, enabled)
  return alice:call('automations.save', {key = key, name = 'Daily ' .. key, enabled = enabled, trigger = {kind = 'daily', at = at},
    action = {profile = 'worker'}, instruction = 'Daily task.'}).id
end
-- change saves the automation again with other fields (the rev from automations.list).
local function change(id, key, fields)
  local a = F.view(alice, id)
  local args = {id = id, if_rev = a.rev, key = key, name = a.name, enabled = a.enabled, trigger = a.trigger,
    action = a.action, instruction = a.instruction}
  for k, v in pairs(fields) do args[k] = v end
  return alice:call('automations.save', args)
end
local function slots(id)
  local out = {}
  for _, r in ipairs(F.runs(alice, id, 'd')) do out[#out + 1] = r.slot end
  table.sort(out)
  return table.concat(out, ' ')
end
-- settle waits for at least two plugin ticks (tick = 1 s).
local function settle() rex.sleep(3) end
local function wait_slots(id, want)
  return wait('the daily runs ' .. want .. ' of automation ' .. id, function() return slots(id) == want end, 20)
end

test('a date runs at its time, not before', function()
  F.set_clock(F.at(2026, 12, 1, 8, 0))
  local id = daily('due', '09:00')
  F.set_clock(F.at(2026, 12, 1, 8, 59))
  settle()
  expect(slots(id)).to_be('')
  F.set_clock(F.at(2026, 12, 1, 9, 0))
  wait_slots(id, '2026-12-01')
  settle()
  expect(slots(id)).to_be('2026-12-01')
end)

test('after three missed dates one run catches up, for the newest date', function()
  F.set_clock(F.at(2026, 12, 2, 8, 0))
  local id = daily('missed', '09:00')
  F.set_clock(F.at(2026, 12, 5, 10, 0))
  wait_slots(id, '2026-12-05')
  settle()
  expect(slots(id)).to_be('2026-12-05')
end)

-- An unrelated save (here a rename) keeps the baseline, so a due date still runs, once. The
-- tick and the save are not ordered in this test: it proves the baseline in the state record.
test('an unrelated save keeps the baseline: the due date runs once', function()
  F.set_clock(F.at(2026, 12, 6, 8, 0))
  local id = daily('unrelated', '09:00')
  local base = F.store('state/' .. id).value.daily_base
  expect(base).to_be('2026-12-05')
  change(id, 'unrelated-1', {name = 'Daily renamed'})
  expect(F.store('state/' .. id).value.daily_base).to_be(base)
  F.set_clock(F.at(2026, 12, 6, 9, 1))
  change(id, 'unrelated-2', {name = 'Daily renamed again'})
  expect(F.store('state/' .. id).value.daily_base).to_be(base)
  wait_slots(id, '2026-12-06')
  change(id, 'unrelated-3', {instruction = 'Other task.'})
  settle()
  expect(slots(id)).to_be('2026-12-06')
end)

test('a time change on the same date gives no second run', function()
  F.set_clock(F.at(2026, 12, 7, 8, 0))
  local id = daily('moved', '09:00')
  F.set_clock(F.at(2026, 12, 7, 9, 1))
  wait_slots(id, '2026-12-07')
  F.set_clock(F.at(2026, 12, 7, 9, 30))
  change(id, 'moved-1', {trigger = {kind = 'daily', at = '10:00'}})
  F.set_clock(F.at(2026, 12, 7, 10, 1))
  settle()
  expect(slots(id)).to_be('2026-12-07')
  F.set_clock(F.at(2026, 12, 8, 10, 0))
  wait_slots(id, '2026-12-07 2026-12-08')
end)

test('enable after the time gives no run on that date', function()
  F.set_clock(F.at(2026, 12, 9, 8, 0))
  local id = daily('enable', '09:00', false)
  F.set_clock(F.at(2026, 12, 9, 10, 0))
  settle()
  alice:call('automations.set_enabled', {id = id, enabled = true, key = 'enable-on'})
  expect(F.store('state/' .. id).value.daily_base).to_be('2026-12-09')
  settle()
  expect(slots(id)).to_be('')
  F.set_clock(F.at(2026, 12, 10, 9, 0))
  wait_slots(id, '2026-12-10')
end)

-- daily_high only increases: a change to file and back to daily, with the clock moved back, gives
-- no run at or before the newest date that ran.
test('daily, file, daily with a clock moved back: no run at or before daily_high', function()
  F.set_clock(F.at(2026, 12, 11, 8, 0))
  local id = daily('roundtrip', '09:00')
  F.set_clock(F.at(2026, 12, 12, 9, 1))
  wait_slots(id, '2026-12-12')
  expect(F.store('state/' .. id).value.daily_high).to_be('2026-12-12')
  change(id, 'roundtrip-file', {trigger = {kind = 'file', path = F.dir('roundtrip'), glob = '*.md'}})
  F.set_clock(F.at(2026, 12, 11, 10, 0))
  change(id, 'roundtrip-daily', {trigger = {kind = 'daily', at = '09:00'}})
  expect(F.store('state/' .. id).value.daily_base).to_be('2026-12-11')
  F.set_clock(F.at(2026, 12, 12, 9, 30))
  settle()
  expect(slots(id)).to_be('2026-12-12')
  F.set_clock(F.at(2026, 12, 13, 9, 0))
  wait_slots(id, '2026-12-12 2026-12-13')
end)

-- The coordinator's rule (2026-10-20): the instant of a date is the first local minute at or after
-- the set time. On 2027-03-14 (PST8PDT) local time goes from 01:59 to 03:00, so 02:30 runs at
-- 03:00.
test('on a spring-forward date, 02:30 runs at 03:00', function()
  local three = F.at(2027, 3, 14, 3, 0)
  expect(os.date('%H:%M', three - 60)).to_be('01:59')
  F.set_clock(F.at(2027, 3, 13, 12, 0))
  local id = daily('spring', '02:30')
  F.set_clock(three - 60)
  settle()
  expect(slots(id)).to_be('')
  F.set_clock(three)
  wait_slots(id, '2027-03-14')
end)
