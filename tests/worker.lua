-- Whether the worker runs (design v2, 5c). Only a definite observation counts: a lookup that
-- fails for another reason keeps the worker, and the step tries again later. A wrong "absent"
-- would start a second worker.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

test('a failed hub.workers read does not replace a running worker', function()
  local saved = alice:call('automations.save', {key = 'workers-save', name = 'Workers',
    trigger = {kind = 'daily', at = '09:00'}, action = {profile = 'worker'}, instruction = 'Workers task.'})
  local first = alice:call('automations.run', {id = saved.id, key = 'workers-first'})
  local delivered = F.wait_status(first.run_key, 'delivered')
  F.worker(delivered.agent)
  local before = #F.workers('worker')
  local injected = fault({point = 'action', action = 'hub.workers', when = 'before', mode = 'fail', fail_code = 'unavailable'})
  local second = alice:call('automations.run', {id = saved.id, key = 'workers-second'})
  local next_run = F.wait_status(second.run_key, 'delivered')
  expect(fault_fired(injected)).to_be(true)
  expect(#F.workers('worker')).to_be(before)
  expect(next_run.agent).to_be(delivered.agent)
end)

test('a stopped worker is replaced by a new one', function()
  local saved = alice:call('automations.save', {key = 'stopped-save', name = 'Stopped',
    trigger = {kind = 'daily', at = '09:00'}, action = {profile = 'worker'}, instruction = 'Stopped task.'})
  local first = alice:call('automations.run', {id = saved.id, key = 'stopped-first'})
  local delivered = F.wait_status(first.run_key, 'delivered')
  F.worker(delivered.agent):call('automations.done', {run_key = first.run_key, attempt = 1, key = 'stopped-done'})
  expect(alice:hub('hub.stop', {spawn_id = delivered.spawn_id}).status).to_be('closed')
  local second = alice:call('automations.run', {id = saved.id, key = 'stopped-second'})
  local next_run = F.wait_status(second.run_key, 'delivered')
  expect(next_run.agent).not_to_be(delivered.agent)
  expect(next_run.starts).to_be(1)
end)
