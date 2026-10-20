-- automations.list pages (review of 59bf455, R1). The cursor moves over every record that a page
-- reads, also a deleted one (a tombstone stays while a run is active). A page can be empty and
-- still have next. The byte limit never skips a visible record.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function automation(key, instruction)
  return alice:call('automations.save', {key = key, name = 'List ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = instruction or 'List task.'}).id
end
-- tombstone makes a deleted automation that stays: its run is starting (a dropped spawn), so the
-- cleanup waits.
local function tombstone(key)
  local id = automation(key)
  local run_key = 'run/' .. id .. '/m/000001'
  local drop = fault({point = 'spawn-create', mode = 'drop', op = 'automations/spawn/' .. run_key .. '/1'})
  alice:call('automations.run', {id = id, key = key .. '-run'})
  wait('the dropped spawn of ' .. key, function() return fault_fired(drop) end, 10)
  F.wait_status(run_key, 'starting')
  alice:call('automations.delete', {id = id, key = key .. '-delete'})
  expect(store('auto/' .. id).value.deleted).to_be(true)
  return id
end
-- pages lists every page with the given limit and returns the pages and the visible ids.
local function pages(limit)
  local out, ids, after = {}, {}, nil
  for _ = 1, 50 do
    local page = alice:call('automations.list', {after = after, limit = limit})
    out[#out + 1] = page
    for _, a in ipairs(page.automations) do ids[#ids + 1] = a.id end
    if not page.next then return out, ids end
    expect(page.next).not_to_be(after)
    after = page.next
  end
  error('the list does not end')
end

-- Ids 1 to 7 sort in id order as keys. Pages of 2: {1 2} deleted, {3 4} with 3, {5 6} deleted,
-- {7} with 7.
test('pages of only deleted automations, first and in the middle, keep the cursor going', function()
  local t1, t2 = tombstone('t1'), tombstone('t2')
  local a3 = automation('a3')
  local t4, t5, t6 = tombstone('t4'), tombstone('t5'), tombstone('t6')
  local a7 = automation('a7')
  expect(t1 .. t2 .. a3 .. t4 .. t5 .. t6 .. a7).to_be('1234567')
  local list, ids = pages(2)
  expect(table.concat(ids, ' ')).to_be(a3 .. ' ' .. a7)
  expect(#list[1].automations).to_be(0)
  expect(list[1].next).to_be('auto/2')
  expect(#list[3].automations).to_be(0)
  expect(list[3].next).to_be('auto/6')
  local _, all = pages(nil)
  expect(table.concat(all, ' ')).to_be(a3 .. ' ' .. a7)
end)

-- Instructions near the 8 KiB encoded limit: about 4 fit a 40 KB page. Every visible automation
-- comes exactly once, in key order.
test('a page limited by bytes skips no automation', function()
  local big = {}
  for i = 1, 7 do big[#big + 1] = automation('big' .. i, string.rep('\1', 1365)) end
  local list, ids = pages(nil)
  expect(#list > 1).to_be(true)
  expect(#list[1].automations < 9).to_be(true)
  local want = {'3', '7'}
  for _, id in ipairs(big) do want[#want + 1] = id end
  table.sort(want)
  expect(table.concat(ids, ' ')).to_be(table.concat(want, ' '))
end)
