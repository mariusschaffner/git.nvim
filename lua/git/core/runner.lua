local M = {}

---@class GitResult
---@field code integer
---@field stdout string
---@field stderr string
---@field cmd string[]

---@class GitRunOpts
---@field cwd string
---@field stdin string?
---@field timeout integer?
---@field write boolean? Command may write to the repo (disables GIT_OPTIONAL_LOCKS=0)
---@field literal boolean? Treat pathspecs literally (no globbing / magic)

--- Build the full argv for a git invocation.
---@param args string[]
---@param opts GitRunOpts?
---@return string[]
function M.argv(args, opts)
  local cmd = { "git", "--no-pager", "-c", "core.quotepath=false", "-c", "color.ui=never" }
  if opts and opts.literal then
    table.insert(cmd, "--literal-pathspecs")
  end
  vim.list_extend(cmd, args)
  return cmd
end

local function env(opts)
  local e = {
    GIT_TERMINAL_PROMPT = "0",
    -- Never let a git command we spawn sit waiting for an editor.
    GIT_EDITOR = "true",
    GIT_SEQUENCE_EDITOR = "true",
  }
  if not opts.write then
    -- Read-only commands must not take index.lock, so they never fight with the user's own git commands.
    e.GIT_OPTIONAL_LOCKS = "0"
  end
  return e
end

--- Run git asynchronously. `cb` is always invoked on the main loop (safe to call API functions).
---@param args string[]
---@param opts GitRunOpts
---@param cb fun(res: GitResult)
function M.run(args, opts, cb)
  local cmd = M.argv(args, opts)
  local config = require("git.config").options
  local done = vim.schedule_wrap(cb)
  local ok, err = pcall(vim.system, cmd, {
    cwd = opts.cwd,
    env = env(opts),
    stdin = opts.stdin or false,
    text = false,
    timeout = opts.timeout or config.timeout,
  }, function(obj)
    local stderr = obj.stderr or ""
    if obj.code == 124 and stderr == "" then
      stderr = "git command timed out"
    end
    done({ code = obj.code, stdout = obj.stdout or "", stderr = stderr, cmd = cmd })
  end)
  if not ok then
    done({ code = -1, stdout = "", stderr = tostring(err), cmd = cmd })
  end
end

-- Mutations (add, restore, stash, ...) run one at a time so they never race each other on index.lock.
local queue = {}
local busy = false

local function pump()
  local job = table.remove(queue, 1)
  if not job then
    busy = false
    return
  end
  busy = true
  M.run(job.args, job.opts, function(res)
    local ok, err = pcall(job.cb, res)
    if not ok then
      vim.notify("git.nvim: " .. tostring(err), vim.log.levels.ERROR, { title = "git.nvim" })
    end
    pump()
  end)
end

--- Queue a repo-modifying git command. Commands run serially in submission order.
---@param args string[]
---@param opts GitRunOpts
---@param cb fun(res: GitResult)?
function M.mutate(args, opts, cb)
  opts = vim.tbl_extend("force", opts, { write = true })
  queue[#queue + 1] = { args = args, opts = opts, cb = cb or function() end }
  if not busy then
    pump()
  end
end

--- Whether any mutation is queued or running.
function M.busy()
  return busy
end

--- Human readable error for a failed result.
---@param res GitResult
---@return string
function M.error_message(res)
  local msg = vim.trim(res.stderr ~= "" and res.stderr or res.stdout)
  if msg == "" then
    msg = ("exit code %d"):format(res.code)
  end
  -- Drop the fixed prefix (git, --no-pager, -c x, -c y) so the message shows the actual subcommand.
  local args = vim.list_slice(res.cmd or {}, 7)
  return ("`git %s` failed: %s"):format(table.concat(args, " "), msg)
end

return M
