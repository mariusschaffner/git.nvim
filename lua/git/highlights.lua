local M = {}

-- Every group copies a standard group by default, so it follows the user's colorscheme, but never
-- italic (the plugin renders no italic text) and without background, so text never paints over the
-- row backgrounds below it (e.g. GitStatusSubject copies Normal, whose bg would hide the unpushed row).
-- Override any group with `vim.api.nvim_set_hl(0, "GitStatus...", {...})`.
M.links = {
  GitStatusFloatTitle = "FloatTitle",
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
  GitStatusHashIncoming = "DiagnosticWarn",
  GitStatusDeco = "String",
  GitStatusSubject = "Normal",
  GitStatusDiffAdd = "Added",
  GitStatusDiffDelete = "Removed",
  GitStatusDiffHunk = "Function",
  GitStatusDiffHeader = "Comment",
  GitStatusDiffContext = "Normal",
}

--- `color` blended over the view's background with opacity `alpha`, as "#rrggbb".
---@param color integer
---@param alpha number
---@return string
function M.blend(color, alpha)
  local float = require("git.config").options.status.window.kind == "float"
  local bg = vim.api.nvim_get_hl(0, { name = float and "NormalFloat" or "Normal", link = false }).bg
    or vim.api.nvim_get_hl(0, { name = "Normal", link = false }).bg
    or (vim.o.background == "light" and 0xffffff or 0x1e1e1e)
  local out = 0
  for shift = 16, 0, -8 do
    local c, b = bit.band(bit.rshift(color, shift), 0xff), bit.band(bit.rshift(bg, shift), 0xff)
    out = out * 256 + math.floor(c * alpha + b * (1 - alpha) + 0.5)
  end
  return ("#%06x"):format(out)
end

-- Groups with fixed colors instead of a colorscheme source.
M.colors = {
  GitStatusBorder = { fg = "#808080", ctermfg = 244 },
  -- Background of whole graph rows; background only, so the row keeps its text colors.
  -- Unpushed rows get a translucent green, blended over the window background.
  GitStatusUnpushedLine = function()
    local light = vim.o.background == "light"
    return { bg = M.blend(light and 0x2da44e or 0x3fb950, light and 0.18 or 0.16), ctermbg = light and 194 or 22 }
  end,
  GitStatusIncomingLine = function()
    return vim.o.background == "light" and { bg = "#f5dfa8", ctermbg = 223 } or { bg = "#5c4a1f", ctermbg = 58 }
  end,
}

-- What setup() last applied per group, to tell our own definitions apart from user overrides.
local applied = {}

local function apply(group, spec)
  if type(spec) == "function" then
    spec = spec()
  end
  local hl = type(spec) == "string" and vim.api.nvim_get_hl(0, { name = spec, link = false }) or vim.deepcopy(spec)
  hl.italic = false
  if hl.cterm then
    hl.cterm.italic = nil
  end
  if type(spec) == "string" then
    hl.bg, hl.ctermbg = nil, nil
  end
  vim.api.nvim_set_hl(0, group, hl)
  applied[group] = vim.api.nvim_get_hl(0, { name = group })
end

function M.setup()
  for _, specs in ipairs({ M.links, M.colors }) do
    for group, spec in pairs(specs) do
      local cur = vim.api.nvim_get_hl(0, { name = group })
      -- Only (re)define groups that are unset or still hold our own definition.
      if vim.tbl_isempty(cur) or vim.deep_equal(cur, applied[group]) then
        apply(group, spec)
      end
    end
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
