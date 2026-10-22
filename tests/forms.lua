-- The automation forms: step 1 chooses the agent profile,
-- step 2 has the fields and that profile's args. Every form is measured complete against the
-- 40 KB page budget: a picker page ends early, and a form that cannot fit is a refusal.
local F = assert(loadfile(H.args.file:match('^(.*)/[^/]*$') .. '/support/fixture.lua'))()(H)
F.profiles()
F.set_clock(F.at(2026, 11, 3, 10, 0))
local alice = agent('alice')
local BUDGET = 40 * 1024

local function step1()
  user:command('new_automation')
  return F.view_of('/forms/automation/new')
end
local function options(tree)
  local out = {}
  for _, o in ipairs(F.field(tree, 'profile', 'profile').options) do out[#out + 1] = o.value end
  return out
end
local function find(name)
  for _, a in ipairs(alice:call('automations.list', {}).automations) do if a.name == name then return a end end
end

test('a new automation in two steps: the profile, then the fields and its args', function()
  local s1, t1 = step1()
  expect(table.concat(options(t1), ' ')).to_be('tasked worker')
  local route = F.ok(s1:action('profile', 'submit', {values = {profile = 'tasked'}})).form
  expect(route).to_be('/forms/automation/new?profile=tasked')
  local s2, t2 = F.view_of(route)
  expect(F.field(t2, 'automation', 'arg/task').required).to_be(true)
  expect(node(t2, 'change_profile').text).to_match('not kept')
  expect(node(t2, 'automation').submit_action.tool).to_be('automations.save')
  -- A refused submit fails the operation with the message and keeps the form open.
  local values = {name = 'Form one', enabled = true, trigger = 'daily', at = '07:45', glob = '*', path = '', cwd = '', title = '',
    instruction = '', ['arg/task'] = 'from form'}
  local op = s2:action('automation', 'submit', {values = values})
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('instruction is required')
  expect(user:view(route)).to_be_truthy()
  expect(find('Form one')).to_be(nil)
  -- Change profile goes back to step 1.
  local back = F.ok(s2:action('change_profile', 'change')).form
  expect(back).to_be('/forms/automation/new')
  local s3 = F.view_of(back)
  local s4 = F.view_of(F.ok(s3:action('profile', 'submit', {values = {profile = 'tasked'}})).form)
  values.instruction = 'Form task.'
  expect(F.ok(s4:action('automation', 'submit', {values = values})).close_form).to_be(true)
  local a = find('Form one')
  expect(a.action.profile).to_be('tasked')
  expect(a.action.args.task).to_be('from form')
  expect(a.action.cwd).to_be(nil)
  expect(a.trigger.kind).to_be('daily')
  expect(a.trigger.at).to_be('07:45')
  expect(a.enabled).to_be(true)
end)

test('a profile that is not an agent profile shows a warning and still shows the fields', function()
  local s1 = step1()
  local s2, tree = F.view_of(F.ok(s1:action('profile', 'submit', {values = {profile = 'logtail'}})).form)
  expect(node(tree, 'profile_warning').text).to_match('no longer an agent profile')
  expect(F.field(tree, 'automation', 'name')).to_be_truthy()
  local op = s2:action('automation', 'submit', {values = {name = 'Accessory', trigger = 'daily', at = '07:00', instruction = 'Task.'}})
  expect(op.status).to_be('failed')
  expect(op.error.message).to_match('not an agent profile')
end)

test('120 agent profiles: the picker has pages of at most 50 and reaches the last profile', function()
  local profiles = {}
  for i = 1, 120 do
    profiles[#profiles + 1] = {id = string.format('p%03d', i), name = string.rep('N', 80) .. i, kind = 'agent', command = {'/bin/sh', '-c', 'exit 0'}}
  end
  for _, p in ipairs(F.profile_list()) do profiles[#profiles + 1] = p end
  write_profiles({profiles = profiles})
  local v, tree = step1()
  local all = {}
  for page = 1, 5 do
    expect(F.size(tree) < BUDGET).to_be(true)
    local opts = F.field(tree, 'profile', 'profile').options
    expect(#opts <= 50).to_be(true)
    for _, o in ipairs(opts) do
      all[#all + 1] = o.value
      expect(#o.label <= 60 + 4 + #o.value).to_be(true)
    end
    if not node(tree, 'more_profiles') then break end
    expect(page < 3).to_be(true)
    v, tree = F.view_of(F.ok(v:action('more_profiles', 'more')).form)
    expect(node(tree, 'first_profiles')).to_be_truthy()
  end
  expect(#all).to_be(122)
  expect(all[1]).to_be('p001')
  expect(all[120]).to_be('p120')
  expect(all[122]).to_be('worker')
  F.profiles()
end)

-- A profile whose args alone pass the budget gets a refusal, not a cut form.
test('a profile with 400 args gets a refusal widget in step 2, under the budget', function()
  local profiles = F.profile_list()
  -- The hub requires each arg in the command.
  local args, command = {}, {'/bin/sh', '-c', 'exit 0'}
  for i = 1, 400 do
    args[i] = {name = string.format('a%03d', i), label = string.rep('L', 56) .. string.format('%04d', i)}
    command[#command + 1] = '${' .. args[i].name .. '}'
  end
  profiles[#profiles + 1] = {id = 'wide', name = 'Wide', kind = 'agent', args = args, command = command}
  write_profiles({profiles = profiles})
  local s1 = step1()
  local _, tree = F.view_of(F.ok(s1:action('profile', 'submit', {values = {profile = 'wide'}})).form)
  expect(node(tree, 'too_large').text).to_match('Profile wide has too many args for this form')
  expect(node(tree, 'automation')).to_be(nil)
  expect(node(tree, 'change_profile')).to_be_truthy()
  expect(F.size(tree) < BUDGET).to_be(true)
  F.profiles()
end)

test('an edit form with a 4000-byte instruction and full args renders under the budget', function()
  F.profiles()
  local instruction = string.rep('\195\169', 2000)
  local task = string.rep('t', 480)
  local id = alice:call('automations.save', {key = 'long', name = string.rep('n', 60), trigger = {kind = 'daily', at = '09:00'},
    action = {profile = 'tasked', args = {task = task}, title = string.rep('t', 60)}, instruction = instruction}).id
  local v = F.open(id)
  local _, tree = F.view_of(F.ok(v:action('edit', 'edit')).form)
  expect(F.field(tree, 'automation', 'instruction').value).to_be(instruction)
  expect(F.field(tree, 'automation', 'arg/task').value).to_be(task)
  expect(F.size(tree) < BUDGET).to_be(true)
end)
