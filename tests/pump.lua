-- Pump fairness (review of d66cdc5, panel.lua timeouts). The engine takes one step at a time, and
-- each delivery is one step. Automations with work wait in a FIFO order, so one backlog cannot
-- hold back another automation until it is empty.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')

local BACKLOG = 8
local function manual(id, n) return 'run/' .. id .. '/m/' .. string.format('%06d', n) end
-- A store rev is a decimal string: compare by length, then as text.
local function below(a, b)
  if #a ~= #b then return #a < #b end
  return a < b
end

test('three backlogs that are ready at once deliver in turns', function()
  local ids = {}
  for _, name in ipairs({'a', 'b', 'c'}) do
    local id = alice:call('automations.save', {key = 'pump-' .. name, name = 'Pump ' .. name, trigger = {kind = 'daily', at = '09:00'},
      action = {profile = 'worker'}, instruction = 'Pump task.'}).id
    alice:call('automations.run', {id = id, key = 'pump-' .. name .. '-1'})
    F.wait_status(manual(id, 1), 'delivered', 30)
    ids[#ids + 1] = id
  end
  -- The barrier: the worker check of each delivery calls hub.workers, so a closed gate holds every
  -- delivery. The backlogs queue behind it.
  local gate = fault({point = 'action', action = 'hub.workers', when = 'before', mode = 'gate'})
  for _, id in ipairs(ids) do
    for n = 2, BACKLOG + 1 do alice:call('automations.run', {id = id, key = 'pump-' .. id .. '-' .. n}) end
  end
  wait('the gated worker check', function() return fault_fired(gate) end, 20)
  for _, id in ipairs(ids) do
    for n = 2, BACKLOG + 1 do expect(F.run(manual(id, n)).status).to_be('queued') end
  end
  fault_release(gate)
  -- dv/<id>/<run_key> is written once, by the delivery, and no done follows. Its rev is the
  -- commit order of the deliveries.
  local first, last = {}, {}
  for _, id in ipairs(ids) do
    for n = 2, BACKLOG + 1 do
      F.wait_status(manual(id, n), 'delivered', 60)
      expect(F.delivered(id, manual(id, n))).not_to_be(nil)
      local rev = F.rev('runs', manual(id, n))
      if not first[id] or below(rev, first[id]) then first[id] = rev end
      if not last[id] or below(last[id], rev) then last[id] = rev end
    end
  end
  -- No automation delivers its whole backlog before another delivers its first backlog run.
  for _, x in ipairs(ids) do
    for _, y in ipairs(ids) do
      if x ~= y and not below(first[y], last[x]) then
        error('automation ' .. x .. ' delivered its backlog (revs ' .. first[x] .. '-' .. last[x] .. ') before automation '
          .. y .. ' delivered its first backlog run (rev ' .. first[y] .. ')')
      end
    end
  end
end)
