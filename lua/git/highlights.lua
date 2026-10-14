local M = {}

-- Every group links to a standard group by default, so it follows the user's colorscheme.
-- Override any of them with `vim.api.nvim_set_hl(0, "GitStatus...", {...})`.
M.links = {
  GitStatusBorder = "FloatBorder",
  GitStatusBoxTitle = "Title",
  GitStatusDim = "Comment",
  GitStatusLabel = "Keyword",
  GitStatusTagLabel = "Label",
  GitStatusTag = "Constant",
  GitStatusTagNearest = "Special",
  GitStatusTagUnpushed = "DiagnosticWarn",
  GitStatusUpstream = "String",
  GitStatusBranch = "Type",
  GitStatusProtected = "DiagnosticError",
  GitStatusAhead = "DiagnosticInfo",
  GitStatusBehind = "DiagnosticWarn",
  GitStatusRemoteCommit = "WarningMsg",
  GitStatusWarning = "WarningMsg",
  GitStatusStash = "Special",
  GitStatusSectionConflicted = "DiagnosticError",
  GitStatusSectionStaged = "Added",
  GitStatusSectionUnstaged = "Changed",
  GitStatusSectionUntracked = "Special",
  GitStatusConflicted = "DiagnosticError",
  GitStatusStaged = "Added",
  GitStatusUnstaged = "Changed",
  GitStatusUntracked = "Special",
  GitStatusFile = "Normal",
  GitStatusAdded = "Added",
  GitStatusDeleted = "Removed",
  GitStatusGraph = "Comment",
  GitStatusGraphCommit = "Function",
  GitStatusGraphMerge = "Statement",
  GitStatusHash = "Identifier",
  GitStatusHashUnpushed = "Added",
  GitStatusDeco = "String",
  GitStatusSubject = "Normal",
  GitStatusDiffAdd = "Added",
  GitStatusDiffDelete = "Removed",
  GitStatusDiffHunk = "Function",
  GitStatusDiffHeader = "Comment",
  GitStatusDiffContext = "Normal",
}

function M.setup()
  for group, link in pairs(M.links) do
    vim.api.nvim_set_hl(0, group, { link = link, default = true })
  end
end

local initialized = false

--- Define highlight groups once and keep them across colorscheme changes.
function M.ensure()
  if initialized then
    return
  end
  initialized = true
  M.setup()
  vim.api.nvim_create_autocmd("ColorScheme", {
    group = vim.api.nvim_create_augroup("git.nvim.highlights", { clear = true }),
    callback = M.setup,
  })
end

return M
