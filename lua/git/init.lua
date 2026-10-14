--- git.nvim — an interactive git status dashboard.
local M = {}

--- Configure git.nvim. Optional: the plugin works with defaults.
---@param opts table?
function M.setup(opts)
  require("git.config").setup(opts)
end

--- Open (or focus) the status view for the repository of the current file / cwd.
---@param opts GitOpenOpts?
function M.open(opts)
  require("git.ui").open(opts)
end

function M.close()
  require("git.ui").close()
end

---@param opts GitOpenOpts?
function M.toggle(opts)
  require("git.ui").toggle(opts)
end

function M.refresh()
  require("git.ui").refresh()
end

local SUBCOMMANDS = {
  float = function()
    M.open({ kind = "float" })
  end,
  split = function()
    M.open({ kind = "split" })
  end,
  vsplit = function()
    M.open({ kind = "vsplit" })
  end,
  tab = function()
    M.open({ kind = "tab" })
  end,
  close = M.close,
  toggle = function()
    M.toggle()
  end,
  refresh = M.refresh,
}

M.subcommands = vim.tbl_keys(SUBCOMMANDS)
table.sort(M.subcommands)

--- Entry point of :GitStatus.
---@param args string[]
function M.command(args)
  local sub = args[1]
  if not sub then
    M.open()
    return
  end
  local fn = SUBCOMMANDS[sub]
  if not fn then
    vim.notify(
      ("git.nvim: unknown subcommand %q (expected one of: %s)"):format(sub, table.concat(M.subcommands, ", ")),
      vim.log.levels.ERROR,
      { title = "git.nvim" }
    )
    return
  end
  fn()
end

return M
