--- Read-only git queries shared by features (not tied to a view).
local runner = require("git.core.runner")
local util = require("git.core.util")

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
--- A stash's file: its change against the commit the stash was made on (untracked: the whole file).
---@param repo GitRepo
---@param file GitFile
---@param cb fun(lines: string[]?, err: string?)
function M.file_diff(repo, file, cb)
  local args
  if file.stash and file.section == "untracked" then
    -- The untracked files commit has no parent, so `show` diffs it against the empty tree.
    args = { "show", "--no-ext-diff", "--format=", file.stash .. "^3", "--", file.path }
  elseif file.stash then
    args = { "diff", "--no-ext-diff", file.stash .. "^1", file.stash, "--" }
    if file.orig then
      table.insert(args, file.orig)
    end
    table.insert(args, file.path)
  elseif file.section == "staged" then
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
  local no_index = file.section == "untracked" and not file.stash
  runner.run(args, { cwd = repo.root, literal = not no_index }, function(res)
    -- `diff --no-index` exits 1 when files differ.
    if res.code ~= 0 and not (no_index and res.code == 1) then
      cb(nil, runner.error_message(res))
      return
    end
    cb(output_lines(res.stdout))
  end)
end

--- Files of a stash with +/- counts: `changes` (tracked files, against the commit the stash was made on) and
--- `untracked` (stashed with --include-untracked).
---@param repo GitRepo
---@param hash string The stash commit
---@param cb fun(files: { changes: GitFile[], untracked: GitFile[] }?, err: string?)
function M.stash_files(repo, hash, cb)
  local parse_status = require("git.parse.status")
  local parse_numstat = require("git.parse.numstat").parse
  local out = { changes = {}, untracked = {} }
  local err
  --- `cmd` with --name-status and with --numstat over `revs`, merged into out[section].
  local function list(section, cmd, revs)
    return function(done)
      local res = {}
      local function run(format)
        return function(d)
          local args = vim.list_extend(vim.list_extend({}, cmd), { format, "-z" })
          vim.list_extend(args, revs)
          table.insert(args, "--")
          runner.run(args, { cwd = repo.root }, function(r)
            res[format] = r
            d()
          end)
        end
      end
      util.all({ run("--name-status"), run("--numstat") }, function()
        for _, r in pairs(res) do
          if r.code ~= 0 then
            err = err or runner.error_message(r)
            return done()
          end
        end
        local stats = parse_numstat(res["--numstat"].stdout)
        for _, f in ipairs(parse_status.parse_name_status(res["--name-status"].stdout, section)) do
          local s = stats[f.path]
          if s then
            f.added, f.deleted, f.binary = s.added, s.deleted, s.binary
          end
          f.stash = hash
          table.insert(out[section], f)
        end
        done()
      end)
    end
  end
  runner.run({ "rev-parse", "--verify", "--quiet", hash .. "^3" }, { cwd = repo.root }, function(res)
    local tasks = { list("changes", { "diff", "-M", "--no-ext-diff" }, { hash .. "^1", hash }) }
    if res.code == 0 then
      -- The untracked files commit has no parent: --root lists all its files as added.
      tasks[2] = list("untracked", { "diff-tree", "-r", "--root", "--no-commit-id" }, { hash .. "^3" })
    end
    util.all(tasks, function()
      if err then
        return cb(nil, err)
      end
      cb(out)
    end)
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

--- Full message of a commit, as lines.
---@param repo GitRepo
---@param hash string
---@param cb fun(lines: string[]?, err: string?)
function M.commit_message(repo, hash, cb)
  runner.run({ "log", "-1", "--format=%B", hash, "--" }, { cwd = repo.root }, function(res)
    if res.code ~= 0 then
      cb(nil, runner.error_message(res))
      return
    end
    local lines = output_lines(res.stdout)
    while #lines > 1 and lines[#lines] == "" do
      lines[#lines] = nil
    end
    cb(lines)
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
