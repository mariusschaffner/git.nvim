--- Lane-based commit graph with smooth junctions.
---
--- Every commit owns a lane (column). After drawing a commit row, its parents are assigned to lanes:
--- the first unclaimed parent keeps the commit's lane, further parents fork into new lanes, and
--- parents already owned by another lane (a branch rejoining) close into that lane, except that a
--- lane further right is pulled into the commit's lane so the mainline stays on the left. When
--- anything moves sideways a transition row is emitted, whose glyphs are derived from which
--- directions (up/down/left/right) each cell connects to.
---
--- Every lane gets a color when it starts (a branch tip or a fork) and keeps it while the branch goes
--- on; the commit nodes, strokes and junctions of that branch are drawn in it.
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

-- Number of lane colors (GitStatusGraphLane1..), used in turn.
M.COLORS = 6

---@param color integer
---@return string
function M.lane_hl(color)
  return "GitStatusGraphLane" .. color
end

---@class GitGraphRow
---@field segments { [1]: string, [2]: string }[] Lane glyphs as {text, highlight group}
---@field commit GitCommit? Set on commit rows, nil on transition rows
---@field fresh boolean? Commit rows: the commit starts a lane here (nothing above connects to it)
---@field color integer? Commit rows: color of the commit's lane

local bor = bit.bor

local function col_pos(col)
  return col * 2 - 1
end

---@param commits GitCommit[] In topological order, newest first
---@param reserved integer? A color left out (taken by the side lane)
---@return GitGraphRow[]
local function lanes_layout(commits, reserved)
  local rows = {}
  ---@type (string|false)[]
  local lanes = {}
  -- Color per lane; kept after the lane ends, for the junction that closes it.
  ---@type integer[]
  local colors = {}
  local last = 0
  local function new_color()
    repeat
      last = last % M.COLORS + 1
    until last ~= reserved
    return last
  end

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
        colors[j] = new_color()
        return j
      end
    end
    lanes[#lanes + 1] = hash
    colors[#lanes] = new_color()
    return #lanes
  end

  for _, c in ipairs(commits) do
    local found = find(c.hash)
    local idx = found or claim(c.hash)
    local is_merge = #c.parents > 1

    -- commit row
    local segs = {}
    for col = 1, #lanes do
      if col > 1 then
        segs[#segs + 1] = { " ", "GitStatusGraph" }
      end
      if col == idx then
        segs[#segs + 1] = { is_merge and M.MERGE or M.COMMIT, M.lane_hl(colors[idx]) }
      elseif lanes[col] then
        segs[#segs + 1] = { "│", M.lane_hl(colors[col]) }
      else
        segs[#segs + 1] = { " ", "GitStatusGraph" }
      end
    end
    rows[#rows + 1] = { segments = segs, commit = c, fresh = not found, color = colors[idx] }

    -- assign parents to lanes; each edge is a horizontal connection drawn in the transition row,
    -- as { from, to, color }: in the color of the lane that ends or starts there
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
        edges[#edges + 1] = { existing, idx, colors[existing] }
      elseif existing then
        -- a further parent merges in from its own lane; the first parent ends this lane in that one
        edges[#edges + 1] = { idx, existing, kept and colors[existing] or colors[idx] }
      elseif not kept then
        lanes[idx] = parent
        kept = true
      else
        local j = claim(parent, idx)
        edges[#edges + 1] = { idx, j, colors[j] }
      end
    end
    if not kept then
      lanes[idx] = false
    end

    -- transition row
    if #edges > 0 then
      local width = #lanes * 2 - 1
      local cells, cell_hl = {}, {}
      for pos = 1, width do
        cells[pos] = 0
      end
      -- vertical strokes: up when the lane was active above, down when it continues below
      for col = 1, #lanes do
        local pos = col_pos(col)
        cells[pos] = bor(was_active[col] and UP or 0, lanes[col] and DOWN or 0)
        if cells[pos] ~= 0 then
          cell_hl[pos] = M.lane_hl(colors[col])
        end
      end
      -- horizontal strokes take the edge's color, except where they cross a vertical one
      for _, e in ipairs(edges) do
        local a, b = col_pos(e[1]), col_pos(e[2])
        local lo, hi = math.min(a, b), math.max(a, b)
        cells[lo] = bor(cells[lo], RIGHT)
        cells[hi] = bor(cells[hi], LEFT)
        for pos = lo + 1, hi - 1 do
          cells[pos] = bor(cells[pos], LEFT + RIGHT)
        end
        for pos = lo, hi do
          cell_hl[pos] = cell_hl[pos] or M.lane_hl(e[3])
        end
      end

      local tsegs = {}
      for pos = 1, width do
        tsegs[pos] = { GLYPH[cells[pos]] or "┼", cell_hl[pos] or "GitStatusGraph" }
      end
      rows[#rows + 1] = { segments = tsegs }
    end

    while #lanes > 0 and not lanes[#lanes] do
      lanes[#lanes] = nil
    end
  end

  return rows
end

--- Number of leading commits that are in `set` and form a straight line onto the next commit.
---@param commits GitCommit[]
---@param set table<string, true>
---@return integer
local function tip_run(commits, set)
  local n = 0
  while commits[n + 1] and set[commits[n + 1].hash] do
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
--- are drawn on a side lane to the right that joins the pushed history at the upstream commit
---@field incoming table<string, true>? Incoming (not yet pulled) commits: drawn the same way, joining at HEAD

---@param commits GitCommit[] In topological order, newest first
---@param opts GitGraphOpts?
---@return GitGraphRow[]
function M.layout(commits, opts)
  opts = opts or {}
  local hl = "GitStatusGraphUnpushed"
  local n = tip_run(commits, opts.unpushed or {})
  if n == 0 then
    hl = "GitStatusGraphIncoming"
    n = tip_run(commits, opts.incoming or {})
  end
  if n == 0 then
    return lanes_layout(commits)
  end
  -- The side lane takes the last color; the history it joins starts with the first one.
  local side = M.lane_hl(M.COLORS)
  local rows = {}
  for i = 1, n do
    rows[i] = {
      segments = { { " ", "GitStatusGraph" }, { " ", "GitStatusGraph" }, { M.COMMIT, hl } },
      commit = commits[i],
      fresh = i == 1,
      color = M.COLORS,
    }
  end
  rows[#rows + 1] = { segments = { { "├", M.lane_hl(1) }, { "─", side }, { "╯", side } } }
  local rest = lanes_layout(vim.list_slice(commits, n + 1), M.COLORS)
  rest[1].fresh = false -- the junction above leads into it
  return vim.list_extend(rows, rest)
end

--- Lane glyphs for an extra line above a commit row (e.g. for its ref names): the other lanes pass
--- straight through, the commit's own lane comes down from above unless the commit starts it.
---@param row GitGraphRow A commit row
---@return { [1]: string, [2]: string }[]
function M.above(row)
  local out = {}
  for i, seg in ipairs(row.segments) do
    local t, hl = seg[1], seg[2]
    if t == M.COMMIT or t == M.MERGE then
      t = row.fresh and " " or "│"
      hl = row.fresh and "GitStatusGraph" or M.lane_hl(row.color)
    end
    out[i] = { t, hl }
  end
  return out
end

return M
