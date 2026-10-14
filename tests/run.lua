-- Minimal, dependency-free test runner.
--
--   nvim --clean --headless -l tests/run.lua            run all specs
--   nvim --clean --headless -l tests/run.lua graph      run specs whose file name contains "graph"
--
-- Provides busted-style globals: describe, it, before_each, after_each, eq, ok, matches.

local root = vim.fs.normalize(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h"))
vim.opt.rtp:prepend(root)
package.path = root .. "/tests/?.lua;" .. package.path

-- Hermetic git: ignore the user's/system config, fixed identity.
local empty = vim.fn.tempname()
vim.fn.writefile({}, empty)
vim.env.GIT_CONFIG_NOSYSTEM = "1"
vim.env.GIT_CONFIG_GLOBAL = empty
vim.env.GIT_AUTHOR_NAME = "Test"
vim.env.GIT_AUTHOR_EMAIL = "test@example.com"
vim.env.GIT_COMMITTER_NAME = "Test"
vim.env.GIT_COMMITTER_EMAIL = "test@example.com"

local filter = _G.arg and _G.arg[1]
local stats = { pass = 0, fail = 0 }
local failures = {}
local scopes = { { name = nil, before = {}, after = {} } }

function _G.describe(name, fn)
  scopes[#scopes + 1] = { name = name, before = {}, after = {} }
  local ok, err = xpcall(fn, debug.traceback)
  if not ok then
    stats.fail = stats.fail + 1
    failures[#failures + 1] = { name = name .. " (describe)", err = err }
  end
  scopes[#scopes] = nil
end

function _G.before_each(fn)
  table.insert(scopes[#scopes].before, fn)
end

function _G.after_each(fn)
  table.insert(scopes[#scopes].after, fn)
end

function _G.it(name, fn)
  local parts = {}
  for _, s in ipairs(scopes) do
    if s.name then
      parts[#parts + 1] = s.name
    end
  end
  parts[#parts + 1] = name
  local full = table.concat(parts, " › ")

  local ok, err = xpcall(function()
    for _, s in ipairs(scopes) do
      for _, b in ipairs(s.before) do
        b()
      end
    end
    fn()
  end, debug.traceback)
  for i = #scopes, 1, -1 do
    for _, a in ipairs(scopes[i].after) do
      pcall(a)
    end
  end

  if ok then
    stats.pass = stats.pass + 1
    io.write("  ok   " .. full .. "\n")
  else
    stats.fail = stats.fail + 1
    failures[#failures + 1] = { name = full, err = err }
    io.write("  FAIL " .. full .. "\n")
  end
end

function _G.eq(expected, actual, msg)
  if not vim.deep_equal(expected, actual) then
    error(
      ("%sexpected:\n%s\nactual:\n%s"):format(msg and (msg .. "\n") or "", vim.inspect(expected), vim.inspect(actual)),
      2
    )
  end
end

function _G.ok(value, msg)
  if not value then
    error(msg or ("expected a truthy value, got " .. vim.inspect(value)), 2)
  end
  return value
end

function _G.matches(pattern, s, msg)
  if type(s) ~= "string" or not s:find(pattern) then
    error(("%sexpected %s to match %q"):format(msg and (msg .. "\n") or "", vim.inspect(s), pattern), 2)
  end
end

local specs = vim.fn.globpath(root .. "/tests/spec", "*_spec.lua", false, true)
table.sort(specs)
for _, file in ipairs(specs) do
  if not filter or file:find(filter, 1, true) then
    io.write(vim.fs.basename(file) .. "\n")
    local chunk, err = loadfile(file)
    if not chunk then
      stats.fail = stats.fail + 1
      failures[#failures + 1] = { name = file, err = err }
    else
      local ok, run_err = xpcall(chunk, debug.traceback)
      if not ok then
        stats.fail = stats.fail + 1
        failures[#failures + 1] = { name = file, err = run_err }
      end
    end
  end
end

for _, f in ipairs(failures) do
  io.write(("\n--- %s\n%s\n"):format(f.name, f.err))
end
io.write(("\n%d passed, %d failed\n"):format(stats.pass, stats.fail))
os.exit(stats.fail == 0 and 0 or 1)
