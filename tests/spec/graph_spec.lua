local graph = require("git.graph")

local function c(hash, ...)
  return { hash = hash, abbrev = hash, parents = { ... }, deco = "", subject = hash }
end

--- Render rows to plain strings: lane glyphs plus "<hash>" on commit rows.
local function draw(commits)
  local out = {}
  for _, row in ipairs(graph.layout(commits)) do
    local s = table.concat(vim.tbl_map(function(seg)
      return seg[1]
    end, row.segments))
    s = s:gsub("%s+$", "")
    if row.commit then
      s = s .. " " .. row.commit.hash
    end
    out[#out + 1] = s
  end
  return out
end

describe("graph.layout", function()
  it("draws a linear history in one lane", function()
    eq({ "○ c", "○ b", "○ a" }, draw({ c("c", "b"), c("b", "a"), c("a") }))
  end)

  it("forks and rejoins for a merge", function()
    -- m merges b into a; b branched off a
    eq({
      "● m",
      "├─╮",
      "│ ○ b",
      "├─╯",
      "○ a",
    }, draw({ c("m", "a", "b"), c("b", "a"), c("a") }))
  end)

  it("uses tee junctions for octopus merges", function()
    eq({
      "● m",
      "├─┬─╮",
      "│ │ ○ c",
      "│ ○ b",
      "○ a",
    }, draw({ c("m", "a", "b", "c"), c("c"), c("b"), c("a") }))
  end)

  it("closes several lanes into a shared ancestor", function()
    eq({
      "● m",
      "├─┬─╮",
      "│ │ ○ c",
      "│ ○ │ b",
      "│ ├─╯",
      "○ │ a",
      "├─╯",
    }, draw({ c("m", "a", "b", "c"), c("c", "x"), c("b", "x"), c("a", "x") }))
  end)

  it("draws crossings where a bridge passes an active lane", function()
    -- lanes: [a-line, b-line, c-line]; c closes into lane 1, passing lane 2
    local rows = draw({ c("m", "a", "b", "c"), c("c", "a"), c("b", "a"), c("a") })
    eq("● m", rows[1])
    eq("├─┬─╮", rows[2])
    eq("│ │ ○ c", rows[3])
    eq("├─┼─╯", rows[4])
  end)

  it("keeps the mainline in the left lane when a side branch owns the parent", function()
    -- topo order puts the side commit s first; its parent a is then claimed by lane 2
    eq({
      "● m",
      "├─╮",
      "│ ○ s",
      "○ │ b",
      "├─╯",
      "○ a",
    }, draw({ c("m", "b", "s"), c("s", "a"), c("b", "a"), c("a") }))
  end)

  it("keeps lanes for parents outside the window without crashing", function()
    local rows = draw({ c("b", "a"), c("x", "y") })
    eq({ "○ b", "│ ○ x" }, rows)
  end)

  it("handles an empty list", function()
    eq({}, graph.layout({}))
  end)
end)
