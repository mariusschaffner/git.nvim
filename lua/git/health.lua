local M = {}

-- `git restore` (stage/unstage/discard) needs 2.23.
local MIN_GIT = { 2, 23, 0 }

---@param out string
---@return integer[]?
function M.parse_git_version(out)
  local major, minor, patch = out:match("git version (%d+)%.(%d+)%.?(%d*)")
  if not major then
    return nil
  end
  return { tonumber(major), tonumber(minor), tonumber(patch) or 0 }
end

local function at_least(v, min)
  for i = 1, 3 do
    if v[i] ~= min[i] then
      return v[i] > min[i]
    end
  end
  return true
end

function M.check()
  local health = vim.health
  health.start("git.nvim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim >= 0.10")
  else
    health.error("Neovim >= 0.10 is required")
  end

  if vim.fn.executable("git") == 0 then
    health.error("`git` not found on PATH")
  else
    local res = vim.system({ "git", "--version" }, { text = true }):wait()
    local v = res.code == 0 and M.parse_git_version(res.stdout or "")
    if not v then
      health.warn("Could not determine the git version: " .. vim.trim((res.stdout or "") .. (res.stderr or "")))
    elseif at_least(v, MIN_GIT) then
      health.ok(("git %d.%d.%d"):format(v[1], v[2], v[3]))
    else
      health.error(
        ("git %d.%d.%d is too old; git >= %d.%d is required"):format(v[1], v[2], v[3], MIN_GIT[1], MIN_GIT[2])
      )
    end
  end

  local config = require("git.config").options
  if config.icons then
    health.info("Nerd Font icons enabled (`icons = true`). If you see boxes or blanks, set `icons = false`.")
  else
    health.info("Using ASCII labels (`icons = false`).")
  end
  if config.status.tags.check_remote then
    health.info(
      "`status.tags.check_remote` is on: opening the view runs `git ls-remote` (network) at most every "
        .. config.status.tags.cache_ttl
        .. "s."
    )
  end
end

return M
