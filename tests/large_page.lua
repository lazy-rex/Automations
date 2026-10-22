-- The row bound of one watch page: one page commits in one transaction.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

-- A gate holds the watch read until 50 files are there, so one read page has all 50 rows. Each run
-- is near the largest size (an instruction of 8 KiB encoded): the page is 100 writes and about
-- 450 KB. Page commits fail until the test cancels the failure: no run and no marker stay. The
-- next commit must hold the whole page: the record of hub calls after the failure shows one
-- transaction with all 50 run inserts, committed once.
-- The spawn gate holds the start, so no worker starts.
test('one watch page of 50 large file runs commits in one transaction; a failed commit leaves none', function()
  local dir = F.dir('large-page')
  local id = alice:call('automations.save', {key = 'large-page', name = 'Large page', trigger = {kind = 'file', path = dir, glob = '*.md'},
    action = {profile = 'tasked', args = {task = string.rep('t', 480)}}, instruction = string.rep('\1', 1365)}).id
  F.watching(alice, id)
  local spawn = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate'})
  local read = fault({point = 'action', action = 'hub.watch.read', when = 'before', mode = 'gate', key = 'a-' .. id .. '-1'})
  wait('the held read', function() return fault_fired(read) end, 10)
  for i = 1, 50 do F.put(string.format('%s/l%02d.md', dir, i)) end
  rex.sleep(3)
  local prefix = 'seen/' .. id .. '/'
  local function runs() return sql('SELECT run_key, status, length(doc) AS n FROM runs WHERE automation_id = ?', {id}) end
  local function markers() return #sql('SELECT key FROM seen WHERE substr(key, 1, ?) = ?', {#prefix, prefix}) end
  -- The injection fails every page commit until the test cancels it.
  local failed = inject({match = {sql_commit_writes = 'runs'}, fail = 'the page commit fails', fail_code = 'unavailable', times = 'always'})
  fault_release(read)
  wait('the failed page commit', function() return injection(failed).consumed >= 1 end, 20)
  -- A second gate stops the retries at their read: when it has refused one, no page transaction
  -- is open (the plugin runs one step at a time).
  local again = fault({point = 'action', action = 'hub.watch.read', when = 'before', mode = 'gate', key = 'a-' .. id .. '-1'})
  wait('the held retry', function() return fault_fired(again) end, 20)
  expect(#runs()).to_be(0)
  expect(markers()).to_be(0)
  -- The baseline keeps the failed transactions out of the record below (one reply holds about
  -- 1 MB). Then the retry may commit.
  local _, after_fail = calls('none')
  cancel_injection(failed)
  local t0 = os.time()
  fault_release(again)
  wait('50 large file runs', function() return #runs() >= 50 end, 30)
  local t1 = os.time()
  local list = runs()
  expect(#list).to_be(50)
  for _, r in ipairs(list) do
    expect(r.n > 8000).to_be(true)
    expect(r.status == 'queued' or r.status == 'starting').to_be(true)
  end
  expect(markers()).to_be(50)
  -- After the failure, one transaction inserted runs: all 50, and it committed once.
  local execs, reply = calls('hub.sql.exec', {after = after_fail.next})
  expect(reply.dropped).to_be(false)
  local per_tx, order = {}, {}
  for _, c in ipairs(execs) do
    if type(c.args.sql) == 'string' and c.args.sql:find('^INSERT INTO runs') and c.args.tx then
      if not per_tx[c.args.tx] then per_tx[c.args.tx] = 0; order[#order + 1] = c.args.tx end
      per_tx[c.args.tx] = per_tx[c.args.tx] + 1
    end
  end
  expect(#order).to_be(1)
  expect(per_tx[order[1]]).to_be(50)
  local commits = calls('hub.sql.commit', {after = after_fail.next})
  local committed = 0
  for _, c in ipairs(commits) do if c.args.tx == order[1] then committed = committed + 1 end end
  expect(committed).to_be(1)
  -- The time from the release of the retry to the committed page (the recheck wait, the read and
  -- the page transaction), for the record. The hub ends a transaction after 10 s with tx_expired,
  -- and then nothing commits: the commit above is the check of that limit.
  print('large page: ' .. (t1 - t0) .. ' s from the retry release to the committed page')
  wait('the held start', function() return fault_fired(spawn) end, 10)
  fault_release(spawn)
end)
