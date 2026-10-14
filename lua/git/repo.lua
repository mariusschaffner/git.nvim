local runner = require("git.runner")

local M = {}

---@class GitRepo
---@field root string Work tree root
---@field gitdir string Absolute git dir (differs from root/.git for worktrees and submodules)

--- Directory to start the repo search from: the current file's directory, falling back to cwd.
---@param bufnr integer?
---@return string
function M.start_dir(bufnr)
  bufnr = bufnr or 0
  local uv = vim.uv or vim.loop
  local name = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr) or ""
  if name ~= "" and vim.bo[bufnr].buftype == "" and not name:match("^%w[%w+.-]*://") then
    local dir = vim.fs.dirname(name)
    local stat = dir and uv.fs_stat(dir)
    if stat and stat.type == "directory" then
      return dir
    end
  end
  return uv.cwd() or "."
end

--- Resolve the repository containing `dir`.
---@param dir string
---@param cb fun(repo: GitRepo?, err: string?)
function M.find(dir, cb)
  runner.run({ "rev-parse", "--show-toplevel", "--absolute-git-dir" }, { cwd = dir }, function(res)
    if res.code ~= 0 then
      cb(nil, "Not a git repository")
      return
    end
    local lines = require("git.util").lines(res.stdout)
    if #lines < 2 then
      -- e.g. inside a bare repo or the .git dir itself: no work tree to show.
      cb(nil, "Not inside a git work tree")
      return
    end
    cb({ root = vim.fs.normalize(lines[1]), gitdir = vim.fs.normalize(lines[2]) })
  end)
end

return M
