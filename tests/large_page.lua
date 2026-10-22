-- The row bound of one watch page (SDK port plan, slice 3e): one page commits in one transaction.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

-- One watch page (50 rows) commits in one transaction. With runs near the largest size (an
-- instruction of 8 KiB encoded), the 50 runs and markers are about 100 statements and 450 KB: the
-- row bound of a page must fit the hub's transaction limits (slice 3e). The gate holds the start,
-- so no worker starts.
test('a page of 50 large file runs commits whole', function()
  local dir = F.dir('large-page')
  local id = alice:call('automations.save', {key = 'large-page', name = 'Large page', trigger = {kind = 'file', path = dir, glob = '*.md'},
    action = {profile = 'tasked', args = {task = string.rep('t', 480)}}, instruction = string.rep('\1', 1365)}).id
  F.watching(alice, id)
  local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate'})
  for i = 1, 50 do F.put(string.format('%s/l%02d.md', dir, i)) end
  local function rows() return sql('SELECT status, length(doc) AS n FROM runs WHERE automation_id = ?', {id}) end
  wait('50 large file runs', function() return #rows() >= 50 end, 60)
  wait('the held start', function() return fault_fired(gate) end, 10)
  rex.sleep(2)
  local list = rows()
  expect(#list).to_be(50)
  for _, r in ipairs(list) do
    expect(r.n > 8000).to_be(true)
    expect(r.status == 'queued' or r.status == 'starting').to_be(true)
  end
  expect(#sql('SELECT key FROM seen WHERE substr(key, 1, ?) = ?', {#('seen/' .. id .. '/'), 'seen/' .. id .. '/'})).to_be(50)
  fault_release(gate)
end)
