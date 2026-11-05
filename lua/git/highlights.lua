local M = {}

-- Every group copies a standard group by default, so it follows the user's colorscheme, but never
-- italic (the plugin renders no italic text) and without background, so text never paints over the
-- row backgrounds below it (e.g. GitStatusSubject copies Normal, whose bg would hide the unpushed row).
-- Override any group with `vim.api.nvim_set_hl(0, "GitStatus...", {...})`.

-- A muted green for everything added (staged, +N, unpushed, diff lines): Added is too bright in many colorschemes.
local function green()
  return vim.o.background == "light" and { fg = "#5f8700", ctermfg = 64 } or { fg = "#87af5f", ctermfg = 107 }
end

--- A background for the dark / light background, each as { gui, cterm }.
local function shade(dark, light)
  local c = vim.o.background == "light" and light or dark
  return { bg = c[1], ctermbg = c[2] }
end

-- A soft amber for unstaged changes: Changed is a bright cyan in many colorschemes.
local function amber()
  return vim.o.background == "light" and { fg = "#9e6a03", ctermfg = 136 } or { fg = "#e5c07b", ctermfg = 180 }
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
  GitStatusSectionUntracked = "Special",
  GitStatusConflicted = "DiagnosticError",
  GitStatusUntracked = "Special",
  GitStatusFile = "Normal",
  GitStatusDeleted = "Removed",
  GitStatusGraph = "Comment",
  GitStatusGraphIncoming = "DiagnosticWarn",
  -- A diverged branch: incoming commits, and the blocked push marker between them and the unpushed ones.
  GitStatusGraphDivergedIncoming = "DiagnosticError",
  GitStatusGraphBlocked = "DiagnosticError",
  GitStatusHash = "Identifier",
  GitStatusHashIncoming = "DiagnosticWarn",
  GitStatusSubject = "Normal",
  GitStatusDiffDelete = "Removed",
  GitStatusDiffLineNr = "LineNr",
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
  -- Unpushed commits of a diverged branch (they cannot be pushed before pulling).
  GitStatusGraphDivergedUnpushed = { fg = "#ff8700", ctermfg = 208 },
  GitStatusSectionStaged = green,
  GitStatusStaged = green,
  GitStatusAdded = green,
  GitStatusGraphUnpushed = green,
  GitStatusHashUnpushed = green,
  GitStatusDiffAdd = green,
  GitStatusSectionUnstaged = amber,
  GitStatusUnstaged = amber,
  -- Inline diffs: hunk separators, whole-row tints of added / removed lines, and their changed part stronger
  -- (with the text color, which the stronger background replaces).
  GitStatusDiffHunk = { fg = "#808080", ctermfg = 244 },
  GitStatusDiffAddLine = function()
    return shade({ "#2a3a22", 22 }, { "#e3f0d6", 194 })
  end,
  GitStatusDiffDeleteLine = function()
    return shade({ "#3f2626", 52 }, { "#f5dcdc", 224 })
  end,
  GitStatusDiffAddText = function()
    return vim.tbl_extend("force", green(), shade({ "#3d5a2c", 58 }, { "#c5e1a5", 150 }))
  end,
  GitStatusDiffDeleteText = function()
    local fg = vim.api.nvim_get_hl(0, { name = "Removed", link = false })
    return vim.tbl_extend(
      "force",
      { fg = fg.fg, ctermfg = fg.ctermfg },
      shade({ "#6b2f2f", 88 }, { "#f0b4b4", 217 })
    )
  end,
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
-- GitStatusGraphLane<n> draws a branch's lines, commits and ref names. No green: it marks unpushed commits.
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
  M.colors["GitStatusGraphLane" .. n] = function()
    local c = pair[vim.o.background == "light" and 2 or 1]
    return { fg = c[1], ctermfg = c[2] }
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
