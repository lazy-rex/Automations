-- Parity fixture (LazyRex docs/testing.md, "Agent parity"): renders the views that open only from
-- another view: the automation view (with a queued run, a cancelled run and a starting run), the
-- edit and delete forms, step 2 of a new automation, and both preset steps. The parity lab is
-- fresh, so the first automation has id 1 (the manifest's parity_routes name it).
local F = assert(loadfile(FIXTURE:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')
local id = alice:call('automations.save', {key = 'parity', name = 'Parity', trigger = {kind = 'daily', at = '09:00'},
  action = {profile = 'worker'}, instruction = 'Parity task.'}).id
local gate = fault({point = 'action', action = 'hub.spawn', when = 'before', mode = 'gate', key = 'automations/spawn/run/' .. id .. '/m/000001/1'})
for n = 1, 3 do alice:call('automations.run', {id = id, key = 'parity-' .. n}) end
alice:call('automations.cancel_run', {run_key = 'run/' .. id .. '/m/000003', key = 'parity-cancel'})

local v = F.open(id)
F.view_of(F.ok(v:action('delete', 'delete')).form)
v = F.open(id)
local edit = F.view_of(F.ok(v:action('edit', 'edit')).form)
F.view_of(F.ok(edit:action('change_profile', 'change')).form)

user:command('new_automation')
local s1 = F.view_of('/forms/automation/new')
F.view_of(F.ok(s1:action('profile', 'submit', {values = {profile = 'worker'}})).form)

local p = F.panel()
local preset = F.view_of(F.ok(p:action('presets', 'add', {item_id = 'vault-health'})).form)
F.view_of(F.ok(preset:action('profile', 'submit', {values = {profile = 'worker'}})).form)
fault_release(gate)
