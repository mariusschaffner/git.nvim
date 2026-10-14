local util = require("git.core.util")

local M = {}

---@class GitNumstat
---@field added integer
---@field deleted integer
---@field binary boolean

--- Parse `git diff --numstat -z` output into a map keyed by (new) path.
--- Regular entries are `A\tD\tpath\0`; renames are `A\tD\t\0old\0new\0`; binary files use `-` counts.
---@param out string
---@return table<string, GitNumstat>
function M.parse(out)
  local map = {}
  local fields = util.split(out, "\0")
  local i = 1
  while i <= #fields do
    local entry = fields[i]
    i = i + 1
    local a, d, path = entry:match("^([%d%-]+)\t([%d%-]+)\t(.*)$")
    if a then
      if path == "" then
        -- rename/copy: old path, then new path
        path = fields[i + 1]
        i = i + 2
      end
      if path and path ~= "" then
        local binary = a == "-" or d == "-"
        map[path] = {
          added = binary and 0 or tonumber(a) or 0,
          deleted = binary and 0 or tonumber(d) or 0,
          binary = binary,
        }
      end
    end
  end
  return map
end

return M
