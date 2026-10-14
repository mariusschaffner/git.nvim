local util = require("git.core.util")

local M = {}

-- Unit separator between fields, record separator after each commit.
M.FORMAT = "--pretty=tformat:%H%x1f%h%x1f%P%x1f%D%x1f%s%x1e"
M.STASH_FORMAT = "--pretty=tformat:%gd%x1f%s%x1e"

---@class GitCommit
---@field hash string
---@field abbrev string
---@field parents string[]
---@field deco string Ref names (without the surrounding parentheses)
---@field subject string

local function records(out)
  local recs = {}
  for _, rec in ipairs(util.split(out, "\30")) do
    rec = rec:gsub("^[\r\n]+", "")
    if rec ~= "" then
      recs[#recs + 1] = util.split(rec, "\31")
    end
  end
  return recs
end

--- Parse `git log` output produced with `M.FORMAT`.
---@param out string
---@return GitCommit[]
function M.parse(out)
  local commits = {}
  for _, f in ipairs(records(out)) do
    if #f >= 5 then
      commits[#commits + 1] = {
        hash = f[1],
        abbrev = f[2],
        parents = f[3] ~= "" and vim.split(f[3], " ", { trimempty = true }) or {},
        deco = f[4],
        -- a subject could in theory contain the separator; keep everything after the 4th field
        subject = table.concat(f, "\31", 5),
      }
    end
  end
  return commits
end

---@class GitStash
---@field ref string e.g. stash@{0}
---@field subject string

--- Parse `git stash list` output produced with `M.STASH_FORMAT`.
---@param out string
---@return GitStash[]
function M.parse_stashes(out)
  local stashes = {}
  for _, f in ipairs(records(out)) do
    if #f >= 2 then
      stashes[#stashes + 1] = { ref = f[1], subject = table.concat(f, "\31", 2) }
    end
  end
  return stashes
end

return M
