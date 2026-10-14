local M = {}

---@alias GitWindowKind "float"|"split"|"vsplit"|"tab"

---@class GitConfig
---@field window { kind: GitWindowKind, width: number, height: number, border: string|string[] }
---@field icons boolean Use Nerd Font icons (false = plain ASCII labels)
---@field protected_branches string[]
---@field graph { max_commits: integer }
---@field stash { max: integer }
---@field diff { max_lines: integer }
---@field untracked_files "normal"|"all"|"no"
---@field tags { check_remote: boolean, timeout: integer, cache_ttl: integer }
---@field auto_refresh boolean
---@field refresh_debounce integer
---@field timeout integer Timeout in ms for local git commands
---@field hints boolean
---@field keymaps table<string, string|string[]|false>

---@type GitConfig
M.defaults = {
  window = {
    kind = "float",
    width = 0.8, -- fraction of the editor (<= 1) or absolute columns (> 1)
    height = 0.9,
    border = "rounded",
  },
  icons = true,
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
  timeout = 15000,
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
  for _, key in ipairs({ "window", "protected_branches", "graph", "stash", "diff", "tags", "keymaps" }) do
    check(key, o[key], "table")
  end
  for _, key in ipairs({ "icons", "auto_refresh", "hints" }) do
    check(key, o[key], "boolean")
  end
  check("refresh_debounce", o.refresh_debounce, "number")
  check("timeout", o.timeout, "number")
  check("untracked_files", o.untracked_files, one_of("normal", "all", "no"), '"normal", "all" or "no"')
  check("window.kind", o.window.kind, one_of("float", "split", "vsplit", "tab"), '"float", "split", "vsplit" or "tab"')
  check("window.width", o.window.width, "number")
  check("window.height", o.window.height, "number")
  check("graph.max_commits", o.graph.max_commits, "number")
  check("stash.max", o.stash.max, "number")
  check("diff.max_lines", o.diff.max_lines, "number")
  check("tags.check_remote", o.tags.check_remote, "boolean")
  check("tags.timeout", o.tags.timeout, "number")
  check("tags.cache_ttl", o.tags.cache_ttl, "number")
  for action, lhs in pairs(o.keymaps) do
    if M.defaults.keymaps[action] == nil then
      error(("git.nvim: unknown keymap action %q"):format(action), 0)
    end
    local t = type(lhs)
    if not (lhs == false or t == "string" or t == "table") then
      error(("git.nvim: keymaps.%s must be a string, a list of strings or false"):format(action), 0)
    end
  end
end

---@param opts table?
function M.setup(opts)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
  -- Lists should be replaced, not merged index-by-index.
  if opts and opts.protected_branches then
    merged.protected_branches = opts.protected_branches
  end
  if opts and opts.keymaps then
    for action, lhs in pairs(opts.keymaps) do
      merged.keymaps[action] = lhs
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

--- All lhs for an action as a list (empty when disabled).
---@param action string
---@return string[]
function M.keys(action)
  local lhs = M.options.keymaps[action]
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
