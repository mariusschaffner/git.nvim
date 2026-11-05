local render = require("git.status.render")
local config = require("git.config")
local util = require("git.core.util")

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

  it("drops the files box on a clean working tree and gives the graph its space", function()
    local s = state({ graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "HEAD -> main", subject = "first" } } })
    local r = render.render(s, { width = 80 })
    ok(not text(r):find("Files"), "no files box")
    matches("Branches", text(r))
    matches("Graph", text(r))
    r = render.render(s, { width = 80, height = 30 })
    eq(nil, r.boxes.files)
    eq(30, #r.lines)
    eq(30 - r.boxes.graph.top, r.boxes.graph.rows)
    -- Zoomed explicitly, the files box still says the tree is clean.
    matches("Working tree clean", text(render.render(state(), { width = 80, height = 30, zoom = "files" })))
  end)

  it("shows no git command hints in the branch box, and a spinner while fetching", function()
    local s = state({ branch = { upstream = "origin/main", ahead = 2, behind = 1 }, operation = "merge" })
    local r = render.render(s, { width = 120 })
    ok(not text(r):find("%(git "), "no git command hints")
    matches("Merge in progress", text(r))
    matches("no upstream", text(render.render(state(), { width = 120 })))
    r = render.render(s, { width = 120, fetching = "|" })
    matches("Remote:.*origin/main  | fetching…", r.lines[2])
    local detached = render.render(state({ branch = { head = "(detached)", detached = true } }), { width = 120 })
    matches("detached HEAD", text(detached))
    -- (tbl_deep_extend would not replace the list with an empty one)
    local no_remote = render.render(vim.tbl_extend("force", state(), { remotes = {} }), { width = 120 })
    matches("no remote", text(no_remote))
  end)

  it("marks protected branches from config", function()
    matches("%(protected%)", text(render.render(state(), { width = 100 })))
    config.setup({ icons = false, status = { protected_branches = { "release" } } })
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

  it("maps lines to items", function()
    local f = { path = "x.lua", code = "M", section = "unstaged" }
    local r = render.render(state({ files = { unstaged = { f } } }), { width = 80 })
    local kinds = {}
    for _, it in pairs(r.items) do
      kinds[it.kind] = (kinds[it.kind] or 0) + 1
    end
    eq(1, kinds.file)
    eq(1, kinds.section)
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
    eq(nil, found[1], "file header left out")
    matches("┄┄ line 1 ┄.*┄ │$", found[2])
    matches("│     1   │ %- old ", found[3])
    matches("│       1 │ %+ new ", found[4])
    matches("│     2 2 │   ctx ", found[5])
    eq(80, util.width(found[2]), "separator fills the row exactly")
  end)

  it("tints added / removed diff rows and marks the changed words", function()
    local f = { path = "x.lua", code = "M", section = "unstaged" }
    local diff = { "@@ -1 +1 @@ function M.x()", "-local a = old()", "+local a = new()" }
    local r =
      render.render(state({ files = { unstaged = { f } } }), { width = 80, expanded = { ["unstaged:x.lua"] = diff } })
    matches("┄┄ line 1 · function M%.x%(%) ┄", text(r))
    local marks = {}
    for lnum, it in pairs(r.items) do
      if it.kind == "diff" then
        marks[it.diff_line] = {}
        for _, m in ipairs(r.marks) do
          if m.row == lnum - 1 then
            marks[it.diff_line][m.hl] = r.lines[lnum]:sub(m.col + 1, m.end_col)
          end
        end
      end
    end
    eq("old", marks[2].GitStatusDiffDeleteText)
    eq("new", marks[3].GitStatusDiffAddText)
    ok(marks[2].GitStatusDiffDeleteLine, "removed row tinted")
    ok(marks[3].GitStatusDiffAddLine, "added row tinted")
    eq(nil, marks[1].GitStatusDiffAddLine, "separator not tinted")
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
    -- ref names go on their own line above the commit; unpushed commits are marked with !
    local lnum
    for l, it in pairs(r.items) do
      if it.kind == "commit" and not it.refs then
        lnum = l
      end
    end
    matches("│  ○ ! h1 first ", r.lines[lnum])
    -- the ref names start in the hash's column
    local function col(line, text)
      return vim.fn.strdisplaywidth(line:sub(1, line:find(text, 1, true) - 1))
    end
    eq(col(r.lines[lnum], "h1 first"), col(r.lines[lnum - 1], "HEAD -> main"))
    eq("h1", r.items[lnum - 1].hash)
    eq(true, r.items[lnum - 1].refs)
    local deco_hl
    for _, m in ipairs(r.marks) do
      if m.row == lnum - 2 and m.hl == "GitStatusGraphLane1" then
        deco_hl = m
      end
    end
    ok(deco_hl, "ref names highlighted")
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
      files = { untracked = { { path = "new.txt", code = "?", section = "untracked" } } },
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

  it("gives incoming commit rows a background, unpushed ones none", function()
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
    eq({ ["in"] = "GitStatusIncomingLine" }, line_hl)
  end)

  it("shows only the files while diffs are open, only graph and commit while a commit is shown", function()
    local f = { path = "x.lua", code = "M", section = "unstaged" }
    local s = state({
      files = { unstaged = { f } },
      graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "", subject = "first" } },
    })
    local r = render.render(s, { width = 60, height = 30, expanded = { ["unstaged:x.lua"] = { "+new" } } })
    eq(nil, r.boxes.graph)
    eq(30, #r.lines)
    ok(not text(r):find("Branches"))
    eq({ top = 2, rows = 28, offset = 0, total = 3 }, r.boxes.files)

    local commit = { hash = "h1234567890", lines = { "commit h1234567890", "Author: me", "", "    msg", "+added" } }
    r = render.render(s, { width = 60, height = 30, commit = commit })
    eq(nil, r.boxes.files)
    eq(30, #r.lines)
    ok(not text(r):find("Branches"))
    -- 30/70: graph 9 lines, commit 21 lines (each incl. 2 border lines)
    eq({ top = 2, rows = 7, offset = 0, total = 1 }, r.boxes.graph)
    eq({ top = 11, rows = 19, offset = 0, total = 5 }, r.boxes.commit)
    matches("Commit h1234567", r.lines[10])
    matches("Author: me", r.lines[12])
    r = render.render(s, {
      width = 60,
      height = 30,
      commit = { hash = "h1234567890", hashes = { "h1234567890", "a0987654321" }, lines = {} },
    })
    matches("2 commits a0987654%.%.h1234567", r.lines[10])
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
    config.setup({ icons = false, status = { hints = false } })
    local r = render.render(state({ files = { unstaged = { { path = "x", code = "M", section = "unstaged" } } } }), {
      width = 120,
    })
    ok(not text(r):find(" | s stage"))
    ok(not text(r):find("git push"))
  end)

  it("shows configured keys in hints", function()
    config.setup({ icons = false, status = { keymaps = { stage = "-", discard = false } } })
    local r = render.render(state({ files = { unstaged = { { path = "x", code = "M", section = "unstaged" } } } }), {
      width = 120,
      cursor = "file:unstaged:x",
    })
    matches("| %- stage", text(r))
    ok(not text(r):find("discard"))
  end)

  it("hints the keys that apply only on the file or header under the cursor", function()
    local s = state({
      files = {
        staged = { { path = "a", code = "M", section = "staged" } },
        unstaged = { { path = "b", code = "M", section = "unstaged" } },
        untracked = { { path = "c", code = "?", section = "untracked" } },
        conflicted = { { path = "d", code = "UU", section = "conflicted" } },
      },
    })
    local function hints(cursor, expanded)
      local r = render.render(s, { width = 200, cursor = cursor, expanded = expanded })
      local rows = {}
      for i, l in ipairs(r.lines) do
        local h = l:match(" | (.-)%s*│$")
        if h and r.items[i] and r.items[i].kind ~= "stash" and r.items[i].kind ~= "branch" then
          rows[render.item_key(r.items[i])] = h
        end
      end
      return rows
    end
    eq({}, hints(nil), "no hints without a cursor line")
    eq({ ["file:staged:a"] = "u unstage · <Tab> diff · S stash · c commit" }, hints("file:staged:a"))
    eq({ ["file:unstaged:b"] = "s stage · X discard · <Tab> diff · S stash" }, hints("file:unstaged:b"))
    eq({ ["file:untracked:c"] = "s stage · X delete · <Tab> diff · S stash" }, hints("file:untracked:c"))
    eq({ ["file:conflicted:d"] = "s mark resolved · <Tab> diff" }, hints("file:conflicted:d"))
    eq({ ["section:conflicted"] = "s mark resolved · <Tab> diff · (git mergetool)" }, hints("section:conflicted"))
    eq({ ["section:staged"] = "u unstage · <Tab> diff · S stash · c commit" }, hints("section:staged"))
    -- an open diff: the diff key closes it
    eq(
      { ["file:unstaged:b"] = "s stage · X discard · <Tab> hide diff · S stash" },
      hints("file:unstaged:b", { ["unstaged:b"] = { "@@ -1 +1 @@", "-x", "+y" } })
    )
    eq({}, hints("commit:abc"), "elsewhere no file hints")
  end)

  it("hints the stash key only on the work tree file under the cursor", function()
    local s = state({
      stashes = { { ref = "stash@{0}", hash = "aaa", subject = "wip" } },
      files = {
        unstaged = { { path = "x", code = "M", section = "unstaged" }, { path = "y", code = "M", section = "unstaged" } },
        conflicted = { { path = "c", code = "UU", section = "conflicted" } },
      },
    })
    local function stash_hints(r)
      local rows = {}
      for i, l in ipairs(r.lines) do
        if l:find("S stash", 1, true) then
          rows[#rows + 1] = r.items[i] and render.item_key(r.items[i])
        end
      end
      return rows
    end
    eq({}, stash_hints(render.render(s, { width = 120 })), "not in the Stashes box nor the headers")
    eq({ "file:unstaged:y" }, stash_hints(render.render(s, { width = 120, cursor = "file:unstaged:y" })))
    eq({}, stash_hints(render.render(s, { width = 120, cursor = "file:conflicted:c" })))
  end)

  it("shows the commit time dimmed at the right edge of commit rows, cutting the subject for it", function()
    local t = os.time({ year = 2026, month = 3, day = 7, hour = 9, min = 5 })
    local subject = string.rep("long subject ", 10)
    local s = state({ graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "", subject = subject, time = t } } })
    local r = render.render(s, { width = 60, height = 30 })
    local lnum
    for l, it in pairs(r.items) do
      if it.kind == "commit" then
        lnum = l
      end
    end
    local line = r.lines[lnum]
    matches(" 09:05 07%.03%.26 │$", line)
    eq(60, util.width(line))
    matches("…", line, "the subject is cut to leave room")
    local hl
    for _, m in ipairs(r.marks) do
      if m.row == lnum - 1 and line:sub(m.col + 1, m.end_col) == "09:05 07.03.26" then
        hl = m.hl
      end
    end
    eq("GitStatusDim", hl)
    -- no time known (e.g. older states): no date
    s.graph[1].time = nil
    r = render.render(s, { width = 60, height = 30 })
    ok(not text(r):find("07%.03%.26"))
  end)

  it("shows the visible range on an overflowing box's border, except the graph's", function()
    local graph, unstaged = {}, {}
    for i = 1, 40 do
      graph[i] = { hash = "h" .. i, abbrev = "h" .. i, parents = { "h" .. (i + 1) }, deco = "", subject = "c" .. i }
      unstaged[i] = { path = "f" .. i, code = "M", section = "unstaged" }
    end
    local r = render.render(state({ graph = graph, files = { unstaged = unstaged } }), { width = 60, height = 30 })
    local files_bottom = r.lines[r.boxes.files.top + r.boxes.files.rows]
    local graph_bottom = r.lines[r.boxes.graph.top + r.boxes.graph.rows]
    matches(" 1%-%d+/41 ", files_bottom)
    ok(not graph_bottom:find("%d/%d"), "no range on the graph: " .. graph_bottom)
  end)

  it("hints fetch on the Remote row, with keys highlighted apart from their labels", function()
    local s = state({ branch = { upstream = "origin/main" } })
    ok(not render.render(s, { width = 120 }).lines[2]:find("f fetch"), "only with the cursor on the row")
    local r = render.render(s, { width = 120, cursor = "branch:remote" })
    eq({ kind = "branch", row = "remote" }, r.items[2])
    eq({ kind = "branch", row = "head" }, r.items[3])
    matches("origin/main | f fetch", r.lines[2])
    local hls = {}
    for _, m in ipairs(r.marks) do
      if m.row == 1 then
        hls[r.lines[2]:sub(m.col + 1, m.end_col)] = m.hl
      end
    end
    eq("GitStatusHintKey", hls.f)
    eq("GitStatusHint", hls[" fetch"])
    eq("GitStatusHint", hls[" | "])
    -- the spinner takes its place while fetching; no hint without a remote
    ok(not render.render(s, { width = 120, cursor = "branch:remote", fetching = "|" }).lines[2]:find("f fetch"))
    local no_remote =
      render.render(vim.tbl_extend("force", state(), { remotes = {} }), { width = 120, cursor = "branch:remote" })
    ok(not no_remote.lines[2]:find("fetch"))
  end)

  it("replaces the files box with a commit message box while composing", function()
    local f = { path = "x.lua", code = "M", section = "staged" }
    local s = state({
      files = { staged = { f } },
      graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "", subject = "first" } },
    })
    local r = render.render(s, { width = 60, height = 20, compose = true, commit = { hash = "h1", lines = {} } })
    eq(20, #r.lines)
    eq(nil, r.boxes.files)
    eq(nil, r.boxes.commit)
    ok(r.boxes.graph, "graph stays")
    eq({ top = 6, rows = 6, offset = 0, total = 0 }, r.boxes.compose)
    matches("Commit message %(1 staged file%)", r.lines[5])
    matches("<C%-s> commit · q cancel", r.lines[12])
    ok(not text(r):find("x%.lua"))

    -- without a fixed height the box gets a fixed number of rows
    r = render.render(s, { width = 60, compose = true })
    eq(render.COMPOSE_ROWS, r.boxes.compose.rows)
    matches("Commit message", r.lines[r.boxes.compose.top - 1])
  end)

  it("records the line range of every box", function()
    local s = state({
      files = { unstaged = { { path = "x", code = "M", section = "unstaged" } } },
      graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "", subject = "first" } },
    })
    local r = render.render(s, { width = 60, height = 20 })
    local names = {}
    for i, reg in ipairs(r.regions) do
      names[i] = reg.name
      matches("^╭", r.lines[reg.first])
      matches("^╰", r.lines[reg.last])
    end
    eq({ "branches", "files", "graph" }, names)
    eq(20, r.regions[3].last)
  end)

  it("shows a zoomed box alone over the full height", function()
    local s = state({
      files = { unstaged = { { path = "x", code = "M", section = "unstaged" } } },
      graph = { { hash = "h1", abbrev = "h1", parents = {}, deco = "", subject = "first" } },
    })
    local r = render.render(s, { width = 60, height = 20, zoom = "graph" })
    eq(20, #r.lines)
    eq({ "graph" }, vim.tbl_keys(r.boxes))
    eq({ top = 2, rows = 18, offset = 0, total = 1 }, r.boxes.graph)
    r = render.render(s, { width = 60, height = 20, zoom = "files" })
    eq({ "files" }, vim.tbl_keys(r.boxes))
    ok(not text(r):find("Branches"))
    -- commit details win over the zoom
    r = render.render(s, { width = 60, height = 20, zoom = "files", commit = { hash = "h1", lines = {} } })
    ok(r.boxes.commit and r.boxes.graph)
  end)

  it("starts all graph text in one column, whatever the lanes", function()
    local s = state({
      graph = {
        { hash = "m", abbrev = "m", parents = { "a", "b" }, deco = "HEAD -> main", subject = "merge" },
        { hash = "b", abbrev = "b", parents = { "a" }, deco = "feature", subject = "side" },
        { hash = "a", abbrev = "a", parents = {}, deco = "", subject = "root" },
      },
      unpushed = { m = true },
    })
    local r = render.render(s, { width = 60 })
    local cols = {}
    for l, it in pairs(r.items) do
      if it.kind == "commit" then
        local line = r.lines[l]
        local text = it.refs and ((it.hash == "m") and "HEAD" or "feature") or (it.hash .. " ")
        local _, start = line:find("^│[^%w]*")
        cols[#cols + 1] = vim.fn.strdisplaywidth(line:sub(1, start))
        ok(line:sub(start + 1):find("^" .. text), line)
      end
    end
    eq(5, #cols)
    for _, c in ipairs(cols) do
      eq(cols[1], c)
    end
  end)

  it("highlights search matches in the graph, smartcase", function()
    local s = state({
      graph = { { hash = "abc123", abbrev = "abc123", parents = {}, deco = "tag: Fix-1", subject = "Fix the fix" } },
    })
    local function matched(search)
      local r = render.render(s, { width = 80, search = search })
      local out = {}
      for _, m in ipairs(r.marks) do
        if m.hl == "GitStatusSearch" then
          out[#out + 1] = r.lines[m.row + 1]:sub(m.col + 1, m.end_col)
        end
      end
      return out
    end
    eq({ "Fix", "Fix", "fix" }, matched("fix"))
    eq({ "Fix", "Fix" }, matched("Fix"))
    eq({ "abc" }, matched("abc"))
    eq({}, matched(nil))
    ok(render.find("Hello", "hello"))
    eq(nil, render.find("hello", "Hello"))
  end)
end)
