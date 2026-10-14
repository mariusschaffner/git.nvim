if vim.g.loaded_git_nvim then
  return
end
vim.g.loaded_git_nvim = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("git.nvim requires Neovim >= 0.10", vim.log.levels.ERROR)
  return
end

vim.api.nvim_create_user_command("GitStatus", function(opts)
  require("git").command(opts.fargs)
end, {
  nargs = "?",
  desc = "git.nvim: open the git status view",
  complete = function(arg)
    return vim.tbl_filter(function(s)
      return vim.startswith(s, arg)
    end, require("git").subcommands)
  end,
})

vim.keymap.set("n", "<Plug>(GitStatus)", function()
  require("git").open()
end, { desc = "git.nvim: open the git status view" })

vim.keymap.set("n", "<Plug>(GitStatusToggle)", function()
  require("git").toggle()
end, { desc = "git.nvim: toggle the git status view" })
