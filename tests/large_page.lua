-- The row bound of one watch page (SDK port plan, slice 3e): one page commits in one transaction.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

-- A gate holds the watch read until 50 files are there, so one read page has all 50 rows. Each run
-- is near the largest size (an instruction of 8 KiB encoded): the page is 100 writes and about
-- 450 KB. The first commit of the page fails: no run and no marker stay. The next one must hold
-- the whole page: the record of hub calls after the failure shows one transaction with all 50
-- run inserts, committed once (the byte bound of d0bb6a1 split this page into about 10). The spawn gate holds the
-- start, so no worker starts.
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
  local failed = inject({match = {sql_commit_writes = 'runs'}, fail = 'the first page commit fails', fail_code = 'unavailable', times = 1})
  local t0 = os.time()
  fault_release(read)
  wait('the failed page commit', function() return injection(failed).consumed >= 1 end, 20)
  -- The plugin tries again after the recheck (1 s in the lab). The second baseline keeps the
  -- failed transaction out of the record below (one reply holds about 1 MB).
  local _, after_fail = calls('none')
  expect(#runs()).to_be(0)
  expect(markers()).to_be(0)
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
  -- From the read release to 50 committed runs: two page transactions and the 1 s recheck, far
  -- within the hub's 10 s for one transaction (a longer one gets tx_expired and commits nothing).
  print('large page: ' .. (t1 - t0) .. ' s from the read release to the committed page')
  expect(t1 - t0 <= 6).to_be(true)
  wait('the held start', function() return fault_fired(spawn) end, 10)
  fault_release(spawn)
end)
