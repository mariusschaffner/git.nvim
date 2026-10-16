--- Lane-based commit graph with smooth junctions.
---
--- Every commit owns a lane (column). After drawing a commit row, its parents are assigned to lanes:
--- the first unclaimed parent keeps the commit's lane, further parents fork into new lanes, and
--- parents already owned by another lane (a branch rejoining) close into that lane, except that a
--- lane further right is pulled into the commit's lane so the mainline stays on the left. When
--- anything moves sideways a transition row is emitted, whose glyphs are derived from which
--- directions (up/down/left/right) each cell connects to.
local M = {}

local UP, DOWN, LEFT, RIGHT = 1, 2, 4, 8

-- stylua: ignore
local GLYPH = {
  [0] = " ",
  [UP] = "│", [DOWN] = "│", [UP + DOWN] = "│",
  [LEFT] = "─", [RIGHT] = "─", [LEFT + RIGHT] = "─",
  [DOWN + RIGHT] = "╭", [DOWN + LEFT] = "╮", [UP + RIGHT] = "╰", [UP + LEFT] = "╯",
  [UP + DOWN + RIGHT] = "├", [UP + DOWN + LEFT] = "┤",
  [UP + LEFT + RIGHT] = "┴", [DOWN + LEFT + RIGHT] = "┬",
  [UP + DOWN + LEFT + RIGHT] = "┼",
}

M.COMMIT = "○"
M.MERGE = "●"
M.UNPUSHED = "!"

---@class GitGraphRow
---@field segments { [1]: string, [2]: string }[] Lane glyphs as {text, highlight group}
---@field commit GitCommit? Set on commit rows, nil on transition rows

local bor = bit.bor

local function col_pos(col)
  return col * 2 - 1
end

---@param commits GitCommit[] In topological order, newest first
---@return GitGraphRow[]
local function lanes_layout(commits)
  local rows = {}
  ---@type (string|false)[]
  local lanes = {}

  local function find(hash, skip)
    for j = 1, #lanes do
      if j ~= skip and lanes[j] == hash then
        return j
      end
    end
  end

  local function claim(hash, skip)
    for j = 1, #lanes do
      if j ~= skip and not lanes[j] then
        lanes[j] = hash
        return j
      end
    end
    lanes[#lanes + 1] = hash
    return #lanes
  end

  for _, c in ipairs(commits) do
    local idx = find(c.hash) or claim(c.hash)
    local is_merge = #c.parents > 1

    -- commit row
    local segs = {}
    for col = 1, #lanes do
      if col > 1 then
        segs[#segs + 1] = { " ", "GitStatusGraph" }
      end
      if col == idx then
        segs[#segs + 1] = is_merge and { M.MERGE, "GitStatusGraphMerge" } or { M.COMMIT, "GitStatusGraphCommit" }
      else
        segs[#segs + 1] = { lanes[col] and "│" or " ", "GitStatusGraph" }
      end
    end
    rows[#rows + 1] = { segments = segs, commit = c }

    -- assign parents to lanes; each edge is a horizontal connection drawn in the transition row
    local was_active = {}
    for col = 1, #lanes do
      was_active[col] = lanes[col] and true or false
    end
    local edges, kept = {}, false
    for _, parent in ipairs(c.parents) do
      local existing = find(parent, idx)
      if existing and existing > idx and not kept then
        -- parent is expected further right: pull it into this lane so the mainline stays left
        lanes[existing] = false
        lanes[idx] = parent
        kept = true
        edges[#edges + 1] = { existing, idx }
      elseif existing then
        edges[#edges + 1] = { idx, existing }
      elseif not kept then
        lanes[idx] = parent
        kept = true
      else
        edges[#edges + 1] = { idx, claim(parent, idx) }
      end
    end
    if not kept then
      lanes[idx] = false
    end

    -- transition row
    if #edges > 0 then
      local width = #lanes * 2 - 1
      local cells = {}
      for pos = 1, width do
        cells[pos] = 0
      end
      -- vertical strokes: up when the lane was active above, down when it continues below
      for col = 1, #lanes do
        cells[col_pos(col)] = bor(was_active[col] and UP or 0, lanes[col] and DOWN or 0)
      end
      for _, e in ipairs(edges) do
        local a, b = col_pos(e[1]), col_pos(e[2])
        local lo, hi = math.min(a, b), math.max(a, b)
        cells[lo] = bor(cells[lo], RIGHT)
        cells[hi] = bor(cells[hi], LEFT)
        for pos = lo + 1, hi - 1 do
          cells[pos] = bor(cells[pos], LEFT + RIGHT)
        end
      end

      local tsegs = {}
      for pos = 1, width do
        tsegs[pos] = { GLYPH[cells[pos]] or "┼", "GitStatusGraph" }
      end
      rows[#rows + 1] = { segments = tsegs }
    end

    while #lanes > 0 and not lanes[#lanes] do
      lanes[#lanes] = nil
    end
  end

  return rows
end

--- Number of leading commits that are unpushed and form a straight line onto the next (pushed) commit.
---@param commits GitCommit[]
---@param unpushed table<string, true>
---@return integer
local function unpushed_run(commits, unpushed)
  local n = 0
  while commits[n + 1] and unpushed[commits[n + 1].hash] do
    n = n + 1
  end
  if n == 0 or n == #commits then
    return 0
  end
  for i = 1, n do
    local parents = commits[i].parents
    if #parents ~= 1 or parents[1] ~= commits[i + 1].hash then
      return 0
    end
  end
  return n
end

---@class GitGraphOpts
---@field unpushed table<string, true>? Unpushed commits: when they are the straight tip of the history, they
--- are drawn on a side lane that joins the pushed history at the upstream commit

---@param commits GitCommit[] In topological order, newest first
---@param opts GitGraphOpts?
---@return GitGraphRow[]
function M.layout(commits, opts)
  local n = unpushed_run(commits, opts and opts.unpushed or {})
  if n == 0 then
    return lanes_layout(commits)
  end
  local rows = {}
  for i = 1, n do
    rows[i] = {
      segments = { { " ", "GitStatusGraph" }, { " ", "GitStatusGraph" }, { M.UNPUSHED, "GitStatusGraphUnpushed" } },
      commit = commits[i],
    }
  end
  rows[#rows + 1] = { segments = { { "├", "GitStatusGraph" }, { "─", "GitStatusGraph" }, { "╯", "GitStatusGraph" } } }
  return vim.list_extend(rows, lanes_layout(vim.list_slice(commits, n + 1)))
end

--- Lane glyphs for an extra line below a commit row (e.g. for its ref names): the other lanes pass
--- straight through, the commit's own lane continues down unless it is a root commit.
---@param row GitGraphRow A commit row
---@return { [1]: string, [2]: string }[]
function M.continuation(row)
  local out = {}
  for i, seg in ipairs(row.segments) do
    local t = seg[1]
    if t == M.COMMIT or t == M.MERGE or t == M.UNPUSHED then
      t = #row.commit.parents > 0 and "│" or " "
    end
    out[i] = { t, "GitStatusGraph" }
  end
  return out
end

return M
