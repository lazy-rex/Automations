-- Start outcomes (design v2, 5d). Only a definite failure ends a start: then the run fails and
-- the pending request is forgotten. Every unknown outcome keeps the stored request, and the
-- plugin replays it with the same key, so it never starts a second worker.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local function automation(key)
  return alice:call('automations.save', {key = key, name = 'Start ' .. key, trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'worker'}, instruction = 'Start task.'}).id
end

-- The reviewer's case for 997b1eb (R3). Rex reports client_unavailable when a connection drops
-- while a request waits (LazyRex docs/rex-protocol.md, "Client RPC"): the spawn may have run.
-- The fault injects that error reply after the handler ran; it does not drop a connection.
test('client_unavailable from hub.spawn is an unknown outcome: the same key is replayed', function()
  local id = automation('unavailable')
  local before = #F.workers('worker')
  local run_key = 'run/' .. id .. '/m/000001'
  local f = fault({point = 'action', action = 'hub.spawn', when = 'after', mode = 'fail', fail_code = 'client_unavailable',
    key = 'automations/spawn/' .. run_key .. '/1'})
  local first = alice:call('automations.run', {id = id, key = 'unavailable-1'})
  expect(first.run_key).to_be(run_key)
  local run = F.wait_status(run_key, 'delivered')
  expect(fault_fired(f)).to_be(true)
  expect(run.starts).to_be(1)
  expect(#F.workers('worker')).to_be(before + 1)
  local second = alice:call('automations.run', {id = id, key = 'unavailable-2'})
  expect(F.wait_status(second.run_key, 'delivered').agent).to_be(run.agent)
  expect(#F.workers('worker')).to_be(before + 1)
end)

-- A definite failure: Rex refuses the create, so hub.spawn answers failed.
test('a refused start fails its run, and the next run starts with a new key', function()
  local id = automation('refused')
  local run_key = 'run/' .. id .. '/m/000001'
  local f = fault({point = 'spawn-create', mode = 'refuse', op = 'automations/spawn/' .. run_key .. '/1'})
  local before = F.running('worker')
  local first = alice:call('automations.run', {id = id, key = 'refused-1'})
  local failed = F.wait_status(first.run_key, 'failed')
  expect(fault_fired(f)).to_be(true)
  expect(failed.error).to_match('refused')
  expect(store('state/' .. id).value.spawning).to_be(nil)
  expect(store('q/' .. id .. '/000000000001').rev).to_be('0')
  local second = alice:call('automations.run', {id = id, key = 'refused-2'})
  local run = F.wait_status(second.run_key, 'delivered')
  expect(run.starts).to_be(1)
  expect(F.running('worker')).to_be(before + 1)
end)
