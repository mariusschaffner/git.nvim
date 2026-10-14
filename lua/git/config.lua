local M = {}

---@alias GitWindowKind "float"|"split"|"vsplit"|"tab"

---@class GitStatusConfig
---@field window { kind: GitWindowKind, width: number, height: number, border: string|string[] }
---@field protected_branches string[]
---@field graph { max_commits: integer }
---@field stash { max: integer }
---@field diff { max_lines: integer }
---@field untracked_files "normal"|"all"|"no"
---@field tags { check_remote: boolean, timeout: integer, cache_ttl: integer }
---@field auto_refresh boolean
---@field refresh_debounce integer
---@field hints boolean
---@field keymaps table<string, string|string[]|false>

---@class GitConfig
---@field icons boolean Use Nerd Font icons (false = plain ASCII labels)
---@field timeout integer Timeout in ms for local git commands
---@field status GitStatusConfig The :GitStatus dashboard

-- Top-level options are shared by all features; each feature has its own table.
---@type GitConfig
M.defaults = {
  icons = true,
  timeout = 15000,
  status = {
    window = {
      kind = "float",
      width = 0.8, -- fraction of the editor (<= 1) or absolute columns (> 1)
      height = 0.9,
      border = "none",
    },
    protected_branches = { "main", "master" },
    graph = { max_commits = 12 },
    stash = { max = 5 },
    diff = { max_lines = 500 },
    untracked_files = "normal",
    tags = {
      -- Detecting unpushed tags needs `git ls-remote`, i.e. network access. Off by default.
      check_remote = false,
      timeout = 5000,
      cache_ttl = 60,
    },
    auto_refresh = true,
    refresh_debounce = 150,
    hints = true,
    keymaps = {
      stage = "s",
      unstage = "u",
      discard = "X",
      toggle_diff = { "<Tab>", "=" },
      open = "<CR>",
      open_split = "o",
      open_vsplit = "v",
      open_tab = "t",
      stash_pop = "P",
      stash_apply = "A",
      stash_drop = "D",
      next_section = "]]",
      prev_section = "[[",
      refresh = "r",
      close = { "q", "<Esc>" },
      help = "?",
    },
  },
}

---@type GitConfig
M.options = vim.deepcopy(M.defaults)

local function check(name, value, expected, msg)
  local ok
  if type(expected) == "function" then
    ok = expected(value)
  else
    ok = type(value) == expected
  end
  if not ok then
    error(("%s: expected %s, got %s"):format(name, msg or expected, vim.inspect(value)), 0)
  end
end

local function one_of(...)
  local set = {}
  for _, v in ipairs({ ... }) do
    set[v] = true
  end
  return function(v)
    return set[v] == true
  end
end

local function validate(o)
  check("icons", o.icons, "boolean")
  check("timeout", o.timeout, "number")
  check("status", o.status, "table")

  local s = o.status
  for _, key in ipairs({ "window", "protected_branches", "graph", "stash", "diff", "tags", "keymaps" }) do
    check("status." .. key, s[key], "table")
  end
  for _, key in ipairs({ "auto_refresh", "hints" }) do
    check("status." .. key, s[key], "boolean")
  end
  check("status.refresh_debounce", s.refresh_debounce, "number")
  check("status.untracked_files", s.untracked_files, one_of("normal", "all", "no"), '"normal", "all" or "no"')
  local kinds = one_of("float", "split", "vsplit", "tab")
  check("status.window.kind", s.window.kind, kinds, '"float", "split", "vsplit" or "tab"')
  check("status.window.width", s.window.width, "number")
  check("status.window.height", s.window.height, "number")
  check("status.graph.max_commits", s.graph.max_commits, "number")
  check("status.stash.max", s.stash.max, "number")
  check("status.diff.max_lines", s.diff.max_lines, "number")
  check("status.tags.check_remote", s.tags.check_remote, "boolean")
  check("status.tags.timeout", s.tags.timeout, "number")
  check("status.tags.cache_ttl", s.tags.cache_ttl, "number")
  for action, lhs in pairs(s.keymaps) do
    if M.defaults.status.keymaps[action] == nil then
      error(("unknown keymap action %q"):format(action), 0)
    end
    local t = type(lhs)
    if not (lhs == false or t == "string" or t == "table") then
      error(("status.keymaps.%s must be a string, a list of strings or false"):format(action), 0)
    end
  end
end

--- Move dashboard options given at the top level (the pre-`status` layout) into `status`, with a warning.
---@param opts table
---@return table
local function migrate(opts)
  local moved = {}
  for key in pairs(M.defaults.status) do
    if opts[key] ~= nil then
      moved[#moved + 1] = key
    end
  end
  if #moved == 0 then
    return opts
  end
  table.sort(moved)
  opts = vim.deepcopy(opts)
  opts.status = opts.status or {}
  for _, key in ipairs(moved) do
    if opts.status[key] == nil then
      opts.status[key] = opts[key]
    end
    opts[key] = nil
  end
  vim.notify(
    ("git.nvim: options %s moved into `status = { ... }`; please update your setup()"):format(
      table.concat(moved, ", ")
    ),
    vim.log.levels.WARN,
    { title = "git.nvim" }
  )
  return opts
end

---@param opts table?
function M.setup(opts)
  opts = migrate(opts or {})
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts)
  -- Lists should be replaced, not merged index-by-index.
  local status = type(opts.status) == "table" and opts.status or {}
  if status.protected_branches then
    merged.status.protected_branches = status.protected_branches
  end
  if type(status.keymaps) == "table" then
    for action, lhs in pairs(status.keymaps) do
      merged.status.keymaps[action] = lhs
    end
  end
  local ok, err = pcall(validate, merged)
  if not ok then
    vim.notify("git.nvim: invalid config: " .. tostring(err), vim.log.levels.ERROR, { title = "git.nvim" })
    return false
  end
  M.options = merged
  return true
end

--- All lhs for a status view action as a list (empty when disabled).
---@param action string
---@return string[]
function M.keys(action)
  local lhs = M.options.status.keymaps[action]
  if not lhs then
    return {}
  end
  return type(lhs) == "table" and lhs or { lhs }
end

--- First lhs for an action, used in on-screen hints.
---@param action string
---@return string?
function M.key(action)
  return M.keys(action)[1]
end

local NERD = {
  tag = "\u{f412} ",
  unpushed_tag = "\u{f46a} ",
  remote = "\u{f427} ",
  head = "\u{f418} ",
  behind = "\u{ea9a} ",
  ahead = "\u{eaa1} ",
  protected = " \u{ea6c}",
  stash = "\u{f187} ",
  warning = "\u{f071} ",
  conflicted = "\u{f467} ",
  staged = "\u{f067} ",
  unstaged = "\u{f06a} ",
  untracked = "\u{f059} ",
  clean = "\u{f00c} ",
  bullet = "\u{ebf9}  ",
  new_file = "\u{f0f6}  ",
  status = {
    M = "\u{f044}  ",
    A = "\u{f0fe}  ",
    D = "\u{f014}  ",
    R = "\u{f061}  ",
  },
}

local ASCII = {
  tag = "",
  unpushed_tag = "",
  remote = "",
  head = "",
  behind = "v",
  ahead = "^",
  protected = " (protected)",
  stash = "",
  warning = "! ",
  conflicted = "",
  staged = "",
  unstaged = "",
  untracked = "",
  clean = "",
  bullet = "",
  new_file = "?  ",
  status = {},
}

--- Icon set for the current config. Unknown status letters fall back to the letter itself.
function M.icons()
  return M.options.icons and NERD or ASCII
end

return M
