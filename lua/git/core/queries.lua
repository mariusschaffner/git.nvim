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

--- Several commits shown as one: each commit's header and message, then the combined stat and patch
--- from the oldest commit's parent (the empty tree for a root commit) to the newest commit.
---@param repo GitRepo
---@param hashes string[] Newest first, as in the graph
---@param cb fun(lines: string[]?, err: string?)
function M.commits_details(repo, hashes, cb)
  local newest, oldest = hashes[1], hashes[#hashes]
  local function fail(res)
    cb(nil, runner.error_message(res))
  end
  local function diff(base)
    local header = vim.list_extend({ "show", "--no-patch", "--format=fuller" }, hashes)
    runner.run(header, { cwd = repo.root }, function(hres)
      if hres.code ~= 0 then
        return fail(hres)
      end
      local args = { "diff", "--stat", "--patch", "--no-ext-diff", base, newest, "--" }
      runner.run(args, { cwd = repo.root }, function(dres)
        if dres.code ~= 0 then
          return fail(dres)
        end
        local lines = output_lines(hres.stdout)
        lines[#lines + 1] = ""
        cb(vim.list_extend(lines, output_lines(dres.stdout)))
      end)
    end)
  end
  runner.run({ "rev-parse", "--verify", "--quiet", oldest .. "^" }, { cwd = repo.root }, function(res)
    if res.code == 0 then
      return diff(vim.trim(res.stdout))
    end
    -- Root commit: diff against the empty tree (its id depends on the repo's hash algorithm).
    runner.run({ "hash-object", "-t", "tree", "--stdin" }, { cwd = repo.root, stdin = "" }, function(tres)
      if tres.code ~= 0 then
        return fail(tres)
      end
      diff(vim.trim(tres.stdout))
    end)
  end)
end

return M
