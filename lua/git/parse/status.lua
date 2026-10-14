local util = require("git.util")

local M = {}

---@alias GitSection "conflicted"|"staged"|"unstaged"|"untracked"

---@class GitFile
---@field path string
---@field orig string? Original path for renames/copies
---@field code string Single status letter for the section (M, A, D, R, C, T, U, ?), or XY for conflicts
---@field section GitSection
---@field submodule boolean
---@field added integer?
---@field deleted integer?
---@field binary boolean?

---@class GitBranchStatus
---@field oid string?
---@field head string Branch name, or "(detached)"
---@field detached boolean
---@field unborn boolean
---@field upstream string?
---@field ahead integer
---@field behind integer
---@field gone boolean Upstream configured but missing on the remote

---@class GitStatus
---@field branch GitBranchStatus
---@field files table<GitSection, GitFile[]>

--- Parse `git status --porcelain=v2 --branch -z` output.
---@param out string
---@return GitStatus
function M.parse(out)
  ---@type GitBranchStatus
  local branch = { head = "", detached = false, unborn = false, ahead = 0, behind = 0, gone = false }
  local files = { conflicted = {}, staged = {}, unstaged = {}, untracked = {} }
  local has_ab = false

  local fields = util.split(out, "\0")
  local i = 1
  while i <= #fields do
    local entry = fields[i]
    i = i + 1
    local kind = entry:sub(1, 1)

    if kind == "#" then
      local key, value = entry:match("^# (%S+) ?(.*)$")
      if key == "branch.oid" then
        if value == "(initial)" then
          branch.unborn = true
        else
          branch.oid = value
        end
      elseif key == "branch.head" then
        branch.head = value
        branch.detached = value == "(detached)"
      elseif key == "branch.upstream" then
        branch.upstream = value
      elseif key == "branch.ab" then
        local a, b = value:match("^%+(%d+) %-(%d+)$")
        branch.ahead, branch.behind = tonumber(a) or 0, tonumber(b) or 0
        has_ab = true
      end
    elseif kind == "1" or kind == "2" then
      -- 1 XY sub mH mI mW hH hI <path>
      -- 2 XY sub mH mI mW hH hI Xscore <path>\0<origPath>
      local parts = util.split_n(entry, kind == "1" and 9 or 10)
      local path = parts[#parts]
      local orig
      if kind == "2" then
        orig = fields[i]
        i = i + 1
      end
      local xy, sub = parts[2] or "..", parts[3] or "N..."
      local x, y = xy:sub(1, 1), xy:sub(2, 2)
      local is_sub = sub:sub(1, 1) == "S"
      if x ~= "." then
        table.insert(files.staged, { path = path, orig = orig, code = x, section = "staged", submodule = is_sub })
      end
      if y ~= "." then
        -- An unstaged change on a renamed file is a change to the new path only.
        table.insert(files.unstaged, { path = path, code = y, section = "unstaged", submodule = is_sub })
      end
    elseif kind == "u" then
      -- u XY sub m1 m2 m3 mW h1 h2 h3 <path>
      local parts = util.split_n(entry, 11)
      table.insert(files.conflicted, {
        path = parts[#parts],
        code = parts[2] or "UU",
        section = "conflicted",
        submodule = (parts[3] or ""):sub(1, 1) == "S",
      })
    elseif kind == "?" then
      table.insert(files.untracked, { path = entry:sub(3), code = "?", section = "untracked", submodule = false })
    end
    -- "!" (ignored) and empty trailing fields are skipped.
  end

  branch.gone = branch.upstream ~= nil and not has_ab
  return { branch = branch, files = files }
end

return M
