local config = require("git.config")

describe("config", function()
  it("rejects invalid options and keeps the previous config", function()
    config.setup({})
    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    local res = config.setup({ status = { window = { kind = "popup" } } })
    vim.notify = orig
    eq(false, res)
    matches("window%.kind", notified)
    eq("float", config.options.status.window.kind)
  end)

  it("rejects unknown keymap actions", function()
    local orig = vim.notify
    vim.notify = function() end
    eq(false, config.setup({ status = { keymaps = { nope = "x" } } }))
    vim.notify = orig
  end)

  it("replaces lists instead of merging them", function()
    config.setup({ status = { protected_branches = { "trunk" } } })
    eq({ "trunk" }, config.options.status.protected_branches)
    config.setup({ status = { keymaps = { close = "Q" } } })
    eq({ "Q" }, config.keys("close"))
    config.setup({})
  end)

  it("moves top-level dashboard options into status with a warning", function()
    local warned
    local orig = vim.notify
    vim.notify = function(msg, level)
      warned = level == vim.log.levels.WARN and msg or warned
    end
    local res = config.setup({
      icons = false,
      hints = false,
      keymaps = { close = "Q" },
      status = { graph = { max_commits = 3 }, hints = true },
    })
    vim.notify = orig
    eq(true, res)
    matches("hints, keymaps", warned)
    eq(false, config.options.icons)
    -- an explicit status value wins over the legacy top-level one
    eq(true, config.options.status.hints)
    eq({ "Q" }, config.keys("close"))
    eq(3, config.options.status.graph.max_commits)
    eq(nil, config.options.hints)
    config.setup({})
  end)
end)
