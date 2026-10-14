--- Read-only git queries shared by features (not tied to a view).
local runner = require("git.core.runner")

local M = {}

---@param stdout string
---@return string[]
local function output_lines(stdout)
  local lines = vim.split((stdout:gsub("\r\n", "\n")), "\n", { plain = true })
  if lines[#lines] == "" then
    lines[#lines] = nil
  end
  return lines
end

--- Diff of one file as shown in its status section (staged: index vs HEAD, untracked: against /dev/null).
---@param repo GitRepo
---@param file GitFile
---@param cb fun(lines: string[]?, err: string?)
function M.file_diff(repo, file, cb)
  local args
  if file.section == "staged" then
    args = { "diff", "--cached", "--no-ext-diff", "--" }
    if file.orig then
      table.insert(args, file.orig)
    end
    table.insert(args, file.path)
  elseif file.section == "untracked" then
    args = { "diff", "--no-index", "--no-ext-diff", "--", "/dev/null", file.path }
  else
    args = { "diff", "--no-ext-diff", "--", file.path }
  end
  runner.run(args, { cwd = repo.root, literal = file.section ~= "untracked" }, function(res)
    -- `diff --no-index` exits 1 when files differ.
    if res.code ~= 0 and not (file.section == "untracked" and res.code == 1) then
      cb(nil, runner.error_message(res))
      return
    end
    cb(output_lines(res.stdout))
  end)
end

--- `git show` of a commit: header, message, stat and patch.
---@param repo GitRepo
---@param hash string
---@param cb fun(lines: string[]?, err: string?)
function M.commit_details(repo, hash, cb)
  local args = { "show", "--stat", "--patch", "--no-ext-diff", "--format=fuller", hash, "--" }
  runner.run(args, { cwd = repo.root }, function(res)
    if res.code ~= 0 then
      cb(nil, runner.error_message(res))
      return
    end
    cb(output_lines(res.stdout))
  end)
end

return M
