local render = require("git.render")
local config = require("git.config")
local util = require("git.util")

local function state(over)
  local s = {
    repo = { root = "/r", gitdir = "/r/.git" },
    branch = {
      head = "main",
      oid = "abcdef1234",
      detached = false,
      unborn = false,
      ahead = 0,
      behind = 0,
      gone = false,
    },
    remotes = { "origin" },
    tags = { local_at_head = {}, unpushed = {} },
    stashes = {},
    files = { conflicted = {}, staged = {}, unstaged = {}, untracked = {} },
    incoming = {},
    unpushed = {},
    graph = {},
  }
  return vim.tbl_deep_extend("force", s, over or {})
end

local function text(r)
  return table.concat(r.lines, "\n")
end

describe("render", function()
  before_each(function()
    config.setup({ icons = false })
  end)

  it("draws every line exactly as wide as the window", function()
    local r = render.render(
      state({
        files = {
          staged = {
            {
              path = "a very long path " .. string.rep("x", 200),
              code = "M",
              section = "staged",
              added = 1,
              deleted = 2,
            },
          },
          untracked = { { path = "wide 漢字 ünï.txt", code = "?", section = "untracked" } },
        },
      }),
      { width = 60 }
    )
    for i, l in ipairs(r.lines) do
      eq(60, util.width(l), "line " .. i .. ": " .. l)
    end
    matches("…", text(r))
  end)

  it("shows a clean working tree instead of bailing out", function()
    local r = render.render(state(), { width = 80 })
    matches("Working tree clean", text(r))
    matches("Branches", text(r))
  end)

  it("suggests the push command only for real branches with a remote", function()
    matches("git push %-u origin main", text(render.render(state(), { width = 120 })))
    local detached = render.render(state({ branch = { head = "(detached)", detached = true } }), { width = 120 })
    ok(not text(detached):find("push %-u"))
    matches("detached HEAD", text(detached))
    -- (tbl_deep_extend would not replace the list with an empty one)
    local no_remote = render.render(vim.tbl_extend("force", state(), { remotes = {} }), { width = 120 })
    matches("no remote", text(no_remote))
  end)

  it("marks protected branches from config", function()
    matches("%(protected%)", text(render.render(state(), { width = 100 })))
    config.setup({ icons = false, protected_branches = { "release" } })
    ok(not text(render.render(state(), { width = 100 })):find("protected"))
  end)

  it("shows renames, diff stats and binary files", function()
    local r = render.render(
      state({
        files = {
          staged = {
            { path = "new.txt", orig = "old.txt", code = "R", section = "staged", added = 0, deleted = 0 },
            { path = "img.png", code = "M", section = "staged", binary = true, added = 0, deleted = 0 },
          },
          unstaged = { { path = "x.lua", code = "M", section = "unstaged", added = 4, deleted = 2 } },
        },
      }),
      { width = 100 }
    )
    matches("old%.txt → new%.txt", text(r))
    matches("img%.png %(binary%)", text(r))
    matches("x%.lua %(%+4 | %-2%)", text(r))
  end)

  it("maps lines to items and records sections", function()
    local f = { path = "x.lua", code = "M", section = "unstaged" }
    local r = render.render(state({ files = { unstaged = { f } } }), { width = 80 })
    local kinds = {}
    for _, it in pairs(r.items) do
      kinds[it.kind] = (kinds[it.kind] or 0) + 1
    end
    eq(1, kinds.file)
    eq(1, kinds.section)
    -- 3 box titles (Branches, Files, Graph is empty -> omitted) + 1 file section header
    eq(3, #r.sections)
  end)

  it("renders expanded diffs below the file with per-line items", function()
    local f = { path = "x.lua", code = "M", section = "unstaged" }
    local diff = { "diff --git a/x.lua b/x.lua", "@@ -1,2 +1,2 @@", "-old", "+new", " ctx" }
    local r =
      render.render(state({ files = { unstaged = { f } } }), { width = 80, expanded = { ["unstaged:x.lua"] = diff } })
    local found = {}
    for lnum, it in pairs(r.items) do
      if it.kind == "diff" then
        found[it.diff_line] = r.lines[lnum]
      end
    end
    matches("%+new", found[4])
    matches("%-old", found[3])
  end)

  it("sanitizes control characters in file names", function()
    local r =
      render.render(state({ files = { untracked = { { path = "a\nb\tc", code = "?", section = "untracked" } } } }), {
        width = 80,
      })
    for _, l in ipairs(r.lines) do
      ok(not l:find("[\n\t]"))
    end
    matches("a%^Jb    c", text(r))
  end)

  it("renders the commit graph with unpushed hashes", function()
    local s = state({
      graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "HEAD -> main", subject = "first" } },
      unpushed = { h1 = true },
    })
    local r = render.render(s, { width = 80 })
    matches("○ h1 %(HEAD %-> main%) first", text(r))
    local hl
    for _, m in ipairs(r.marks) do
      if m.hl == "GitStatusHashUnpushed" then
        hl = m
      end
    end
    ok(hl, "unpushed hash highlighted")
  end)

  it("keeps the branch box to the Remote and HEAD rows, with tags in their own box", function()
    local s = state({
      branch = { behind = 2, upstream = "origin/main", ahead = 1 },
      tags = { nearest = "v1-2-gabc", unpushed = { "v2" } },
      operation = "rebase",
    })
    local r = render.render(s, { width = 200 })
    matches("HEAD:.*Rebase in progress", r.lines[3])
    matches("Tags", r.lines[5])
    matches("Nearest tag: v1%-2%-gabc", r.lines[6])
    matches("Unpushed:    v2", r.lines[7])
    matches("Files", r.lines[9])
    -- no tag box without a tag
    ok(not text(render.render(state(), { width = 200 })):find("Tags"))
  end)

  it("gives unpushed and incoming commit rows a background", function()
    local s = state({
      graph = {
        { hash = "in", abbrev = "in", parents = { "base" }, deco = "origin/main", subject = "theirs" },
        { hash = "out", abbrev = "out", parents = { "base" }, deco = "HEAD -> main", subject = "mine" },
        { hash = "base", abbrev = "base", parents = {}, deco = "", subject = "base" },
      },
      unpushed = { out = true },
      incoming = { ["in"] = true },
    })
    local r = render.render(s, { width = 80 })
    local line_hl = {}
    for _, m in ipairs(r.marks) do
      if m.hl:match("Line$") then
        local it = r.items[m.row + 1]
        line_hl[it.hash] = m.hl
        eq(#"│ ", m.col)
        eq(#r.lines[m.row + 1] - #" │", m.end_col)
      end
    end
    eq({ ["in"] = "GitStatusIncomingLine", out = "GitStatusUnpushedLine" }, line_hl)
  end)

  it("splits a fixed height evenly between files and graph and scrolls them", function()
    local files = {}
    for i = 1, 20 do
      files[i] = { path = "f" .. i, code = "?", section = "untracked" }
    end
    local s = state({
      files = { untracked = files },
      graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "", subject = "first" } },
    })
    local r = render.render(s, { width = 60, height = 20, scroll = { files = 3 } })
    eq(20, #r.lines)
    -- 4 branch lines, then 8 + 8 lines for files and graph
    eq({ top = 6, rows = 6, offset = 3, total = 21 }, r.boxes.files)
    eq({ top = 14, rows = 6, offset = 0, total = 1 }, r.boxes.graph)
    matches("4%-9/21", r.lines[12])
    -- focusing an item scrolls it into view
    r = render.render(s, { width = 60, height = 20, focus = "file:untracked:f20" })
    eq(15, r.scroll.files)
    eq("f20", r.items[11].file.path)
  end)

  it("omits hints when disabled", function()
    config.setup({ icons = false, hints = false })
    local r = render.render(state({ files = { unstaged = { { path = "x", code = "M", section = "unstaged" } } } }), {
      width = 120,
    })
    ok(not text(r):find(" | s stage"))
    ok(not text(r):find("git push"))
  end)

  it("shows configured keys in hints", function()
    config.setup({ icons = false, keymaps = { stage = "-", discard = false } })
    local r = render.render(state({ files = { unstaged = { { path = "x", code = "M", section = "unstaged" } } } }), {
      width = 120,
    })
    matches("| %- stage", text(r))
    ok(not text(r):find("discard"))
  end)
end)

describe("config", function()
  it("rejects invalid options and keeps the previous config", function()
    config.setup({})
    local notified
    local orig = vim.notify
    vim.notify = function(msg)
      notified = msg
    end
    local res = config.setup({ window = { kind = "popup" } })
    vim.notify = orig
    eq(false, res)
    matches("window%.kind", notified)
    eq("float", config.options.window.kind)
  end)

  it("rejects unknown keymap actions", function()
    local orig = vim.notify
    vim.notify = function() end
    eq(false, config.setup({ keymaps = { nope = "x" } }))
    vim.notify = orig
  end)

  it("replaces lists instead of merging them", function()
    config.setup({ protected_branches = { "trunk" } })
    eq({ "trunk" }, config.options.protected_branches)
    config.setup({ keymaps = { close = "Q" } })
    eq({ "Q" }, config.keys("close"))
    config.setup({})
  end)
end)
