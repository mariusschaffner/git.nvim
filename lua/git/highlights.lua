local M = {}

-- Every group copies a standard group by default, so it follows the user's colorscheme, but never
-- italic (the plugin renders no italic text) and without background, so text never paints over the
-- row backgrounds below it (e.g. GitStatusSubject copies Normal, whose bg would hide the unpushed row).
-- Override any group with `vim.api.nvim_set_hl(0, "GitStatus...", {...})`.

-- A muted green for everything added (staged, +N, unpushed, diff lines): Added is too bright in many colorschemes.
local function green()
  return vim.o.background == "light" and { fg = "#5f8700", ctermfg = 64 } or { fg = "#87af5f", ctermfg = 107 }
end

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
  GitStatusSectionUnstaged = "Changed",
  GitStatusSectionUntracked = "Special",
  GitStatusConflicted = "DiagnosticError",
  GitStatusUnstaged = "Changed",
  GitStatusUntracked = "Special",
  GitStatusFile = "Normal",
  GitStatusDeleted = "Removed",
  GitStatusGraph = "Comment",
  GitStatusGraphIncoming = "DiagnosticWarn",
  GitStatusHash = "Identifier",
  GitStatusHashIncoming = "DiagnosticWarn",
  GitStatusSubject = "Normal",
  GitStatusDiffDelete = "Removed",
  GitStatusDiffHunk = "Function",
  GitStatusDiffHeader = "Comment",
  GitStatusDiffContext = "Normal",
}

-- Groups with fixed colors instead of a colorscheme source.
M.colors = {
  GitStatusBorder = { fg = "#808080", ctermfg = 244 },
  GitStatusDeco = { fg = "#8a8a8a", ctermfg = 245 },
  -- Key binding hints: the key in orange, its label and the separators in a dimmed grey.
  GitStatusHintKey = { fg = "#ff8700", ctermfg = 208 },
  GitStatusHint = { fg = "#6c6c6c", ctermfg = 242 },
  GitStatusSectionStaged = green,
  GitStatusStaged = green,
  GitStatusAdded = green,
  GitStatusGraphUnpushed = green,
  GitStatusHashUnpushed = green,
  GitStatusDiffAdd = green,
  -- Background of whole graph rows; background only, so the row keeps its text colors.
  -- Search matches in the graph: a copy of Search, background included.
  GitStatusSearch = function()
    return vim.api.nvim_get_hl(0, { name = "Search", link = false })
  end,
  GitStatusIncomingLine = function()
    return vim.o.background == "light" and { bg = "#f5dfa8", ctermbg = 223 } or { bg = "#5c4a1f", ctermbg = 58 }
  end,
}

-- Graph branch colors (as many as graph.COLORS), { dark background, light background } as { gui, cterm }.
-- GitStatusGraphLane<n> draws a branch's lines and commits, GitStatusGraphRef<n> its ref names on that color.
-- No green: it marks unpushed commits.
-- stylua: ignore
local LANES = {
  { { "#5fafd7", 74 },  { "#005f87", 24 } },  -- blue
  { { "#d787af", 175 }, { "#af005f", 125 } }, -- pink
  { { "#d7af5f", 179 }, { "#875f00", 94 } },  -- gold
  { { "#87afaf", 109 }, { "#005f5f", 23 } },  -- teal
  { { "#af87d7", 140 }, { "#5f00af", 55 } },  -- purple
  { { "#d7875f", 173 }, { "#af5f00", 130 } }, -- salmon
}
for n, pair in ipairs(LANES) do
  local function color()
    return pair[vim.o.background == "light" and 2 or 1]
  end
  M.colors["GitStatusGraphLane" .. n] = function()
    local c = color()
    return { fg = c[1], ctermfg = c[2] }
  end
  M.colors["GitStatusGraphRef" .. n] = function()
    local c = color()
    if vim.o.background == "light" then
      return { bg = c[1], ctermbg = c[2], fg = "#ffffff", ctermfg = 231 }
    end
    return { bg = c[1], ctermbg = c[2], fg = "#1c1c1c", ctermfg = 234 }
  end
end

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
