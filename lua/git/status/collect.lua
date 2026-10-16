local runner = require("git.core.runner")
local util = require("git.core.util")
local parse_status = require("git.parse.status")
local parse_numstat = require("git.parse.numstat")
local parse_log = require("git.parse.log")

local M = {}

---@class GitTags
---@field at_head string?
---@field nearest string?
---@field local_at_head string[]
---@field unpushed string[]

---@class GitState
---@field repo GitRepo
---@field branch GitBranchStatus
---@field remote string? Remote of the current branch (branch.<name>.remote)
---@field remotes string[]
---@field operation string? "merge", "rebase", "cherry-pick", "revert", "bisect"
---@field tags GitTags
---@field stashes GitStash[]
---@field files table<GitSection, GitFile[]>
---@field incoming table<string, boolean> Hashes of commits on the upstream not yet in HEAD
---@field unpushed table<string, boolean> Hashes of commits not on the upstream (or on any remote)
---@field graph GitCommit[] HEAD's history, plus the upstream's when it has incoming commits

-- Remote tag lists per repo/remote: { at = os.time(), tags = set }
local remote_tag_cache = {}

---@param repo GitRepo
---@return string?
local function detect_operation(repo)
  local uv = vim.uv or vim.loop
  local function exists(name)
    return uv.fs_stat(repo.gitdir .. "/" .. name) ~= nil
  end
  if exists("rebase-merge") or exists("rebase-apply") then
    return "rebase"
  elseif exists("MERGE_HEAD") then
    return "merge"
  elseif exists("CHERRY_PICK_HEAD") then
    return "cherry-pick"
  elseif exists("REVERT_HEAD") then
    return "revert"
  elseif exists("BISECT_LOG") then
    return "bisect"
  end
end

--- Attach numstat counts to files.
local function attach_counts(files, map)
  for _, f in ipairs(files) do
    local n = map[f.path]
    if n then
      f.added, f.deleted, f.binary = n.added, n.deleted, n.binary
    end
  end
end

---@param repo GitRepo
---@param remote string
---@return table<string, boolean>? tags, boolean fresh
function M.cached_remote_tags(repo, remote)
  local entry = remote_tag_cache[repo.root .. "\0" .. remote]
  if not entry then
    return nil, false
  end
  local ttl = require("git.config").options.status.tags.cache_ttl
  return entry.tags, os.time() - entry.at < ttl
end

--- Fetch the remote's tag list (network). Results are cached for `tags.cache_ttl` seconds.
---@param repo GitRepo
---@param remote string
---@param cb fun(ok: boolean)
function M.fetch_remote_tags(repo, remote, cb)
  local config = require("git.config").options.status
  runner.run(
    { "ls-remote", "--tags", "--refs", remote },
    { cwd = repo.root, timeout = config.tags.timeout },
    function(res)
      if res.code ~= 0 then
        cb(false)
        return
      end
      local tags = {}
      for _, line in ipairs(util.lines(res.stdout)) do
        local name = line:match("refs/tags/(.+)$")
        if name then
          tags[name] = true
        end
      end
      remote_tag_cache[repo.root .. "\0" .. remote] = { at = os.time(), tags = tags }
      cb(true)
    end
  )
end

--- Collect everything the status view shows.
---@param repo GitRepo
---@param cb fun(state: GitState?, err: string?)
---@param opts { max_commits: integer? }? max_commits: graph length (default `status.graph.max_commits`)
function M.collect(repo, cb, opts)
  local max_commits = opts and opts.max_commits
  local config = require("git.config").options.status
  local cwd = repo.root
  local status_res, staged_res, unstaged_res
  local stashes, remotes = {}, {}
  local tags = { local_at_head = {}, unpushed = {} }

  local function git(args, on_done)
    return function(done)
      runner.run(args, { cwd = cwd }, function(res)
        on_done(res)
        done()
      end)
    end
  end

  util.all({
    git({ "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=" .. config.untracked_files }, function(res)
      status_res = res
    end),
    git({ "diff", "--cached", "--numstat", "-z" }, function(res)
      staged_res = res
    end),
    git({ "diff", "--numstat", "-z" }, function(res)
      unstaged_res = res
    end),
    git({ "stash", "list", parse_log.STASH_FORMAT }, function(res)
      if res.code == 0 then
        stashes = parse_log.parse_stashes(res.stdout)
      end
    end),
    git({ "describe", "--tags", "--exact-match", "HEAD" }, function(res)
      if res.code == 0 then
        tags.at_head = vim.trim(res.stdout)
      end
    end),
    git({ "describe", "--tags", "HEAD" }, function(res)
      if res.code == 0 then
        tags.nearest = vim.trim(res.stdout)
      end
    end),
    git({ "tag", "--points-at", "HEAD" }, function(res)
      if res.code == 0 then
        tags.local_at_head = util.lines(res.stdout)
      end
    end),
    git({ "remote" }, function(res)
      if res.code == 0 then
        remotes = util.lines(res.stdout)
      end
    end),
  }, function()
    if status_res.code ~= 0 then
      cb(nil, runner.error_message(status_res))
      return
    end
    local status = parse_status.parse(status_res.stdout)
    if staged_res.code == 0 then
      attach_counts(status.files.staged, parse_numstat.parse(staged_res.stdout))
    end
    if unstaged_res.code == 0 then
      attach_counts(status.files.unstaged, parse_numstat.parse(unstaged_res.stdout))
    end

    ---@type GitState
    local state = {
      repo = repo,
      branch = status.branch,
      remotes = remotes,
      operation = detect_operation(repo),
      tags = tags,
      stashes = stashes,
      files = status.files,
      incoming = {},
      unpushed = {},
      graph = {},
    }

    -- Second round: everything that depends on the branch/upstream.
    local b = status.branch
    local second = {}
    if not b.detached and b.head ~= "" then
      second[#second + 1] = git({ "config", "--get", "branch." .. b.head .. ".remote" }, function(res)
        if res.code == 0 then
          state.remote = vim.trim(res.stdout)
        end
      end)
    end
    if not b.unborn then
      local has_upstream = b.upstream and not b.gone
      local incoming = has_upstream and b.behind > 0
      local n = max_commits or config.graph.max_commits
      local log = { "log", "--topo-order", "-n", tostring(n), parse_log.FORMAT, "HEAD" }
      if incoming then
        log[#log + 1] = "@{upstream}"
      end
      log[#log + 1] = "--"
      second[#second + 1] = git(log, function(res)
        if res.code == 0 then
          state.graph = parse_log.parse(res.stdout)
        end
      end)
      if incoming then
        second[#second + 1] = git({ "rev-list", "--max-count=1000", "HEAD..@{upstream}", "--" }, function(res)
          if res.code == 0 then
            for _, h in ipairs(util.lines(res.stdout)) do
              state.incoming[h] = true
            end
          end
        end)
      end
      local range = has_upstream and { "@{upstream}..HEAD" } or { "HEAD", "--not", "--remotes" }
      local args = { "rev-list", "--max-count=1000" }
      vim.list_extend(args, range)
      vim.list_extend(args, { "--" })
      second[#second + 1] = git(args, function(res)
        if res.code == 0 then
          for _, h in ipairs(util.lines(res.stdout)) do
            state.unpushed[h] = true
          end
        end
      end)
    end

    util.all(second, function()
      M.resolve_unpushed_tags(state)
      cb(state)
    end)
  end)
end

--- Fill `state.tags.unpushed` from the remote tag cache. Without a cached list nothing is reported.
---@param state GitState
---@return boolean needs_fetch Whether the cache is missing or stale
function M.resolve_unpushed_tags(state)
  local config = require("git.config").options.status
  state.tags.unpushed = {}
  if not config.tags.check_remote or #state.tags.local_at_head == 0 then
    return false
  end
  local remote = M.tag_remote(state)
  if not remote then
    return false
  end
  local remote_tags, fresh = M.cached_remote_tags(state.repo, remote)
  if remote_tags then
    for _, t in ipairs(state.tags.local_at_head) do
      if not remote_tags[t] then
        table.insert(state.tags.unpushed, t)
      end
    end
  end
  return not fresh
end

--- Remote whose tags should be checked for this state, if any.
---@param state GitState
---@return string?
function M.tag_remote(state)
  return state.remote or (vim.tbl_contains(state.remotes, "origin") and "origin") or state.remotes[1]
end

return M
