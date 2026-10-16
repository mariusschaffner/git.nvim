local H = require("helpers")
local ui = require("git.status.ui")
local actions = require("git.status.actions")

local function open(dir, kind)
  local view = H.await(function(done)
    ui.open({ cwd = dir, kind = kind }, done)
  end)
  return ok(view, "view opened")
end

--- Run a mutation and wait for the view to show the refreshed state.
local function settle(view, fn)
  local gen = view.generation
  fn()
  ok(
    vim.wait(10000, function()
      return view.generation > gen and not require("git.core.runner").busy() and view.state ~= nil
    end, 10),
    "refresh started"
  )
  -- wait for the refresh started by the mutation to land
  local target = view.generation
  local landed = false
  view:refresh(function()
    landed = true
  end)
  ok(vim.wait(10000, function()
    return landed or view.generation > target + 1
  end, 10))
end

local function find_line(view, pred)
  for lnum, it in pairs(view.rendered.items) do
    if pred(it) then
      return lnum, it
    end
  end
end

local function file_item(view, section, path)
  return select(
    2,
    find_line(view, function(it)
      return it.kind == "file" and it.section == section and it.file.path == path
    end)
  )
end

describe("ui", function()
  local dir
  before_each(function()
    -- Tall enough that the files and graph boxes show all entries without scrolling.
    vim.o.lines = 80
    require("git.config").setup({ status = { auto_refresh = false } })
    dir = H.repo()
    H.write(dir, "tracked.txt", { "one" })
    H.commit(dir, "init")
  end)
  after_each(function()
    ui.close()
    vim.cmd("silent! only")
    H.rm(dir)
  end)

  it("opens a float with a buffer showing the status", function()
    H.write(dir, "tracked.txt", { "two" })
    local view = open(dir, "float")
    eq("gitstatus", vim.bo[view.buf].filetype)
    eq(false, vim.bo[view.buf].modifiable)
    eq(view.win, vim.api.nvim_get_current_win())
    ok(vim.api.nvim_win_get_config(view.win).relative ~= "")
    local lines = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    matches("Unstaged changes %(1%)", lines)
    matches("tracked%.txt", lines)
    -- cursor starts on the first file
    local it = view:item()
    eq("file", it and it.kind)
  end)

  it("opens as split, vsplit and tab", function()
    for _, kind in ipairs({ "split", "vsplit", "tab" }) do
      local view = open(dir, kind)
      eq("", vim.api.nvim_win_get_config(view.win).relative, kind)
      eq(kind, view.kind)
      view:close()
      eq(false, vim.api.nvim_buf_is_valid(view.buf), kind .. " buffer wiped")
    end
  end)

  it("reuses the open view and switches kind on request", function()
    local v1 = open(dir, "float")
    local v2 = open(dir, "float")
    eq(v1, v2)
    local v3 = open(dir, "split")
    ok(v3 ~= v1)
    eq(true, v1.closed)
  end)

  it("stages, unstages and keeps the cursor on the entry", function()
    H.write(dir, "tracked.txt", { "two" })
    H.write(dir, "new file.txt", "x")
    local view = open(dir, "float")

    settle(view, function()
      actions.stage(view, { file_item(view, "unstaged", "tracked.txt") })
    end)
    ok(file_item(view, "staged", "tracked.txt"), "tracked.txt staged")
    eq(nil, file_item(view, "unstaged", "tracked.txt"))

    local _, untracked_section = find_line(view, function(it)
      return it.kind == "section" and it.section == "untracked"
    end)
    settle(view, function()
      actions.stage(view, { untracked_section })
    end)
    ok(file_item(view, "staged", "new file.txt"), "section staged")

    local lnum = find_line(view, function(it)
      return it.kind == "file" and it.file.path == "new file.txt"
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    settle(view, function()
      actions.unstage(view, { view:item() })
    end)
    eq(
      { "tracked.txt" },
      vim.tbl_map(function(f)
        return f.path
      end, view.state.files.staged)
    )
    -- cursor followed nothing (entry moved section) but stays in range
    ok(view:item() ~= nil or vim.api.nvim_win_get_cursor(view.win)[1] <= #view.rendered.lines)
  end)

  it("unstages on an unborn branch", function()
    local fresh = H.repo()
    H.write(fresh, "a.txt", "a")
    H.git(fresh, { "add", "a.txt" })
    local view = open(fresh, "float")
    settle(view, function()
      actions.unstage(view, { file_item(view, "staged", "a.txt") })
    end)
    ok(file_item(view, "untracked", "a.txt"))
    view:close()
    H.rm(fresh)
  end)

  it("treats glob characters in paths literally", function()
    -- "[ab].txt" is a glob matching a.txt (and a legal file name on Windows, unlike "*")
    H.write(dir, "[ab].txt", "1")
    H.write(dir, "a.txt", "2")
    local view = open(dir, "float")
    settle(view, function()
      actions.stage(view, { file_item(view, "untracked", "[ab].txt") })
    end)
    ok(file_item(view, "staged", "[ab].txt"))
    ok(file_item(view, "untracked", "a.txt"), "a.txt must not be staged by the glob")
  end)

  it("discards only after confirmation", function()
    H.write(dir, "tracked.txt", { "changed" })
    H.write(dir, "junk.txt", "x")
    local view = open(dir, "float")
    local orig = vim.fn.confirm
    local answer = 2
    vim.fn.confirm = function()
      return answer
    end

    actions.discard(view, { file_item(view, "unstaged", "tracked.txt") })
    eq({ "changed" }, vim.fn.readfile(dir .. "/tracked.txt"))

    answer = 1
    settle(view, function()
      actions.discard(view, { file_item(view, "unstaged", "tracked.txt"), file_item(view, "untracked", "junk.txt") })
    end)
    vim.fn.confirm = orig
    eq({ "one" }, vim.fn.readfile(dir .. "/tracked.txt"))
    eq(0, vim.fn.filereadable(dir .. "/junk.txt"))
  end)

  it("refuses to discard staged changes", function()
    H.write(dir, "tracked.txt", { "staged" })
    H.git(dir, { "add", "tracked.txt" })
    local view = open(dir, "float")
    local msg
    local orig = vim.notify
    vim.notify = function(m)
      msg = m
    end
    actions.discard(view, { file_item(view, "staged", "tracked.txt") })
    vim.notify = orig
    matches("Unstage", msg)
    eq({ "staged" }, vim.fn.readfile(dir .. "/tracked.txt"))
  end)

  it("toggles inline diffs and keeps them across refreshes", function()
    H.write(dir, "tracked.txt", { "two" })
    local view = open(dir, "float")
    local f = file_item(view, "unstaged", "tracked.txt").file
    H.await(function(done)
      view:toggle_diff(f, nil, done)
    end)
    local text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    matches("%+two", text)
    H.write(dir, "tracked.txt", { "three" })
    H.await(function(done)
      view:refresh(done)
    end)
    text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    matches("%+three", text)
    H.await(function(done)
      view:toggle_diff(f, nil, done)
    end)
    text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    ok(not text:find("%+three"))
  end)

  it("opens files at the line of a diff hunk", function()
    H.write(dir, "tracked.txt", { "one", "2", "3", "4", "5", "6", "7", "8", "9", "10" })
    H.commit(dir, "more lines")
    H.write(dir, "tracked.txt", { "one", "2", "3", "4", "5", "6", "7", "eight", "9", "10" })
    local view = open(dir, "float")
    local f = file_item(view, "unstaged", "tracked.txt").file
    H.await(function(done)
      view:toggle_diff(f, true, done)
    end)
    local lnum = find_line(view, function(it)
      return it.kind == "diff" and view.expanded["unstaged:tracked.txt"][it.diff_line] == "+eight"
    end)
    ok(lnum, "diff line rendered")
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    actions.open(view)
    eq(true, view.closed, "float closes when opening a file")
    local uv = vim.uv or vim.loop
    eq(uv.fs_realpath(dir .. "/tracked.txt"), uv.fs_realpath(vim.api.nvim_buf_get_name(0)))
    eq(8, vim.api.nvim_win_get_cursor(0)[1])
    vim.cmd("silent! bwipeout!")
  end)

  it("pops and drops stashes", function()
    H.write(dir, "tracked.txt", { "stashed" })
    H.git(dir, { "stash", "push", "--quiet" })
    H.write(dir, "tracked.txt", { "stashed 2" })
    H.git(dir, { "stash", "push", "--quiet" })
    local view = open(dir, "float")
    eq(2, #view.state.stashes)

    local orig = vim.fn.confirm
    vim.fn.confirm = function()
      return 1
    end
    local lnum = find_line(view, function(it)
      return it.kind == "stash" and it.stash.ref == "stash@{1}"
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    settle(view, function()
      actions.stash(view, "drop")
    end)
    vim.fn.confirm = orig
    eq(1, #view.state.stashes)

    lnum = find_line(view, function(it)
      return it.kind == "stash"
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    settle(view, function()
      actions.stash(view, "pop")
    end)
    eq(0, #view.state.stashes)
    eq({ "stashed 2" }, vim.fn.readfile(dir .. "/tracked.txt"))
  end)

  it("redraws to the new width on resize", function()
    local view = open(dir, "split")
    vim.cmd("vsplit")
    vim.api.nvim_set_current_win(view.win)
    vim.api.nvim_win_set_width(view.win, 40)
    view:redraw()
    local line = vim.api.nvim_buf_get_lines(view.buf, 0, 1, false)[1]
    eq(40, vim.fn.strdisplaywidth(line))
  end)

  it("installs buffer-local keymaps from config", function()
    require("git.config").setup({ status = { auto_refresh = false, keymaps = { stage = "S", discard = false } } })
    local view = open(dir, "split")
    local maps = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
      maps[m.lhs] = true
    end
    ok(maps["S"], "custom stage key")
    ok(not maps["X"], "discard disabled")
    ok(not maps["<Esc>"], "<Esc> is not mapped in splits")
    ok(maps["q"])
  end)

  it("drives actions through the real keymaps, including visual mode", function()
    H.write(dir, "tracked.txt", { "two" })
    H.write(dir, "b.txt", "b")
    H.write(dir, "c.txt", "c")
    local view = open(dir, "float")
    local function press(keys)
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(keys, true, false, true), "x", false)
    end
    local l1 = find_line(view, function(it)
      return it.kind == "file" and it.file.path == "b.txt"
    end)
    local l2 = find_line(view, function(it)
      return it.kind == "file" and it.file.path == "c.txt"
    end)
    vim.api.nvim_win_set_cursor(view.win, { math.min(l1, l2), 0 })
    settle(view, function()
      press("V" .. math.abs(l2 - l1) .. "js")
    end)
    eq("n", vim.api.nvim_get_mode().mode)
    ok(file_item(view, "staged", "b.txt") and file_item(view, "staged", "c.txt"), "visual range staged")
    eq(nil, file_item(view, "staged", "tracked.txt"))

    local lnum = find_line(view, function(it)
      return it.kind == "file" and it.file.path == "tracked.txt"
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    press("<Tab>")
    ok(
      vim.wait(5000, function()
        return view.expanded["unstaged:tracked.txt"] ~= nil
      end, 10),
      "diff toggled by <Tab>"
    )
    press("q")
    eq(true, view.closed)
  end)

  it("opens a borderless float", function()
    require("git.config").setup({ status = { auto_refresh = false, window = { border = "none" } } })
    local view = open(dir, "float")
    eq("float", view.kind)
  end)

  it("cleans up when the window is closed by the user", function()
    local view = open(dir, "float")
    vim.api.nvim_win_close(view.win, true)
    ok(vim.wait(1000, function()
      return view.closed
    end))
    eq(nil, ui.current)
  end)

  it("shows commit details in a box and closes them with q first", function()
    H.commit(dir, "second")
    local view = open(dir, "float")
    local init = view.state.graph[2].hash
    local lnum = find_line(view, function(it)
      return it.kind == "commit" and it.hash == init
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
    ok(vim.wait(5000, function()
      return view.rendered.boxes.commit ~= nil
    end, 10), "commit box shown")
    eq(nil, view.rendered.boxes.files)
    eq(view.win, vim.api.nvim_get_current_win())
    matches("init", table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n"))
    -- the cursor starts in the details box
    local box = view.rendered.boxes.commit
    eq(box.top, vim.api.nvim_win_get_cursor(view.win)[1])
    -- k on its first line goes to the first line of the graph
    vim.api.nvim_feedkeys("k", "x", false)
    eq(view.rendered.boxes.graph.top, vim.api.nvim_win_get_cursor(view.win)[1])
    eq(view.state.graph[1].hash, view:item().hash)
    vim.api.nvim_feedkeys("2j", "x", false)
    eq(init, view:item().hash)
    vim.api.nvim_feedkeys("q", "x", false)
    eq(nil, view.rendered.boxes.commit)
    ok(view.rendered.boxes.files, "files box back")
    eq(init, view:item().hash, "cursor back on the commit")
    ok(view:valid(), "view still open")
  end)

  it("fits the window and scrolls inside the boxes instead", function()
    for i = 1, 30 do
      H.write(dir, ("f%02d.txt"):format(i), "x")
    end
    vim.o.lines = 30
    local view = open(dir, "float")
    local height = vim.api.nvim_win_get_height(view.win)
    eq(height, vim.api.nvim_buf_line_count(view.buf))
    local files = view.rendered.boxes.files
    local graph = view.rendered.boxes.graph
    ok(files.total > files.rows, "files overflow their box")
    -- branch box: title, Remote, HEAD, bottom
    eq(5, files.top - 1)
    ok(math.abs((files.rows + 2) - (graph.rows + 2)) <= 1, "files and graph share the rest evenly")

    -- j on the last visible row scrolls the box, the window stays put
    local last = files.top + files.rows - 1
    vim.api.nvim_win_set_cursor(view.win, { last, 0 })
    local below = view.rendered.items[last]
    vim.api.nvim_feedkeys("j", "x", false)
    eq(1, view.rendered.boxes.files.offset)
    eq(last, vim.api.nvim_win_get_cursor(view.win)[1])
    local key = require("git.status.render").item_key
    eq(key(below), key(view.rendered.items[last - 1]))
    eq(1, vim.fn.line("w0", view.win))

    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-e>", true, false, true), "x", false)
    eq(2, view.rendered.boxes.files.offset)
    eq(1, vim.fn.line("w0", view.win))
  end)

  it("auto-refreshes when the index changes", function()
    require("git.config").setup({ status = { auto_refresh = true, refresh_debounce = 20 } })
    local view = open(dir, "float")
    H.write(dir, "tracked.txt", { "watched" })
    H.git(dir, { "add", "tracked.txt" })
    ok(
      vim.wait(5000, function()
        return file_item(view, "staged", "tracked.txt") ~= nil
      end, 20),
      "view refreshed by the git dir watcher"
    )
  end)

  it("commits the staged changes from the inline message editor", function()
    H.write(dir, "tracked.txt", { "two" })
    H.git(dir, { "add", "tracked.txt" })
    local view = open(dir, "float")
    vim.api.nvim_feedkeys("cc", "x", false)
    vim.cmd("stopinsert")
    local ed = ok(view.editor, "editor open")
    eq(ed.win, vim.api.nvim_get_current_win())
    eq("gitcommit", vim.bo[ed.buf].filetype)
    eq(nil, view.rendered.boxes.files)
    local box = view.rendered.boxes.compose
    local pos = vim.api.nvim_win_get_position(ed.win)
    local base = vim.api.nvim_win_get_position(view.win)
    eq({ base[1] + box.top - 1, base[2] + 2 }, pos)
    eq(box.rows, vim.api.nvim_win_get_height(ed.win))

    -- cancelling keeps the draft
    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "draft subject" })
    vim.api.nvim_feedkeys("q", "x", false)
    eq(nil, view.editor)
    ok(view:valid(), "view still open")
    eq(view.win, vim.api.nvim_get_current_win())
    ok(view.rendered.boxes.files, "files box back")

    vim.api.nvim_feedkeys("cc", "x", false)
    ed = ok(view.editor)
    eq({ "draft subject" }, vim.api.nvim_buf_get_lines(ed.buf, 0, -1, false))
    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "Add two", "", "#body line kept" })
    settle(view, function()
      vim.cmd("write")
    end)
    eq(nil, view.editor)
    eq(nil, view.draft)
    eq("Add two\n\n#body line kept\n", (H.git(dir, { "log", "-1", "--format=%B" }):gsub("\n+$", "\n")))
    eq(nil, file_item(view, "staged", "tracked.txt"))
  end)

  it("refuses to commit without staged changes or with an empty message", function()
    local util = require("git.core.util")
    local notify, messages = util.notify, {}
    util.notify = function(msg)
      messages[#messages + 1] = msg
    end
    local view = open(dir, "float")
    view:start_commit()
    eq(nil, view.editor)
    H.write(dir, "tracked.txt", { "two" })
    H.git(dir, { "add", "tracked.txt" })
    H.await(function(done)
      view:refresh(done)
    end)
    view:start_commit()
    ok(view.editor)
    eq(
      false,
      H.await(function(done)
        view:submit_commit(done)
      end)
    )
    ok(view.editor, "editor stays open")
    view:close()
    util.notify = notify
    eq(nil, view.editor)
    eq({ "Nothing staged to commit", "Empty commit message" }, messages)
  end)

  it("reverts the commit under the cursor after confirmation", function()
    H.write(dir, "tracked.txt", { "two" })
    H.commit(dir, "change")
    local view = open(dir, "float")
    local lnum = find_line(view, function(it)
      return it.kind == "commit" and view.state.graph[1].hash == it.hash
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    local orig = vim.fn.confirm
    local answer = 2
    vim.fn.confirm = function()
      return answer
    end
    actions.revert(view)
    eq({ "two" }, vim.fn.readfile(dir .. "/tracked.txt"))
    answer = 1
    settle(view, function()
      vim.api.nvim_feedkeys("r", "x", false)
    end)
    vim.fn.confirm = orig
    eq({ "one" }, vim.fn.readfile(dir .. "/tracked.txt"))
    matches('^Revert "change"', view.state.graph[1].subject)
  end)

  it("shows a bordered help with the keymaps of the box under the cursor", function()
    H.write(dir, "tracked.txt", { "two" })
    local view = open(dir, "float")
    local function help_at(pred)
      vim.api.nvim_win_set_cursor(view.win, { (find_line(view, pred)), 0 })
      vim.api.nvim_feedkeys("?", "x", false)
      local win = vim.api.nvim_get_current_win()
      ok(win ~= view.win, "help opened")
      local cfg = vim.api.nvim_win_get_config(win)
      local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
      vim.api.nvim_feedkeys("q", "x", false)
      eq(view.win, vim.api.nvim_get_current_win())
      return text, cfg
    end

    local text, cfg = help_at(function(it)
      return it.kind == "file"
    end)
    eq("╭", cfg.border[1])
    matches("Files keymaps", cfg.title[1][1])
    matches("Stage", text)
    matches("Help", text)
    ok(not text:find("Close"), "close is not listed")
    ok(not text:find("Revert"), "no graph keys in files help")
    ok(not text:find("stash"), "no stash keys in files help")

    text = help_at(function(it)
      return it.kind == "commit"
    end)
    matches("Revert", text)
    matches("Toggle details", text)
    ok(not text:find("Stage"), "no file keys in graph help")
  end)

  it("shows several commits selected in visual mode combined", function()
    H.write(dir, "a.txt", "a")
    H.commit(dir, "add a")
    H.write(dir, "b.txt", "b")
    H.commit(dir, "add b")
    local view = open(dir, "float")
    local function line_of(subject)
      for _, c in ipairs(view.state.graph) do
        if c.subject == subject then
          return (find_line(view, function(it)
            return it.kind == "commit" and it.hash == c.hash
          end))
        end
      end
    end
    local top, bottom = line_of("add b"), line_of("add a")
    vim.api.nvim_win_set_cursor(view.win, { top, 0 })
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(("V%dG<CR>"):format(bottom), true, false, true), "x", false)
    ok(vim.wait(5000, function()
      return view.rendered.boxes.commit ~= nil
    end, 10), "combined commit box shown")
    eq("n", vim.api.nvim_get_mode().mode)
    eq(2, #view.commit.hashes)
    eq(view.state.graph[1].hash, view.commit.hash)
    local text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), " ")
    matches("2 commits", text)
    matches("add a", text)
    matches("add b", text)
    matches("b/a%.txt", text)
    matches("b/b%.txt", text)
    ok(not text:find("b/tracked%.txt"), "only the selected commits' changes")
  end)

  it("combines commits down to the root commit", function()
    H.write(dir, "a.txt", "a")
    H.commit(dir, "add a")
    local view = open(dir, "float")
    local hashes = { view.state.graph[1].hash, view.state.graph[2].hash }
    H.await(function(done)
      view:toggle_commits(hashes, done)
    end)
    local text = table.concat(view.commit.lines, " ")
    matches("b/tracked%.txt", text)
    matches("b/a%.txt", text)
  end)

  it("amends the last commit with the staged changes via c a", function()
    H.write(dir, "tracked.txt", { "two" })
    H.git(dir, { "add", "tracked.txt" })
    local view = open(dir, "float")
    local before = H.git(dir, { "rev-list", "--count", "HEAD" })
    vim.api.nvim_feedkeys("ca", "x", false)
    local ed = ok(vim.wait(5000, function()
      return view.editor ~= nil
    end, 10) and view.editor, "amend editor open")
    eq("amend", ed.mode)
    eq({ "init" }, vim.api.nvim_buf_get_lines(ed.buf, 0, -1, false))
    matches("Amend .* %(%+1 staged file%)", table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), " "))
    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "init, amended" })
    settle(view, function()
      vim.cmd("write")
    end)
    eq(before, H.git(dir, { "rev-list", "--count", "HEAD" }))
    eq("init, amended", vim.trim(H.git(dir, { "log", "-1", "--format=%s" })))
    eq("two", vim.trim(H.git(dir, { "show", "HEAD:tracked.txt" })))
    eq(nil, file_item(view, "staged", "tracked.txt"))
  end)

  it("rewords an unpushed commit with R, keeping later commits and staged changes", function()
    H.write(dir, "a.txt", "a")
    H.commit(dir, "add a")
    H.write(dir, "b.txt", "b")
    H.commit(dir, "add b")
    H.write(dir, "tracked.txt", { "staged" })
    H.git(dir, { "add", "tracked.txt" })
    local view = open(dir, "float")
    -- without an upstream or remote every commit counts as unpushed
    local target
    for _, c in ipairs(view.state.graph) do
      if c.subject == "add a" then
        target = c.hash
      end
    end
    ok(view.state.unpushed[target], "commit is unpushed")
    local lnum = find_line(view, function(it)
      return it.kind == "commit" and it.hash == target and not it.refs
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    vim.api.nvim_feedkeys("R", "x", false)
    local ed = ok(vim.wait(5000, function()
      return view.editor ~= nil
    end, 10) and view.editor, "reword editor open")
    eq("reword", ed.mode)
    eq({ "add a" }, vim.api.nvim_buf_get_lines(ed.buf, 0, -1, false))
    vim.api.nvim_buf_set_lines(ed.buf, 0, -1, false, { "add a (reworded)" })
    settle(view, function()
      vim.cmd("write")
    end)
    eq(nil, view.editor)
    eq({ "add b", "add a (reworded)", "init" }, vim.split(vim.trim(H.git(dir, { "log", "--format=%s" })), "\n"))
    ok(file_item(view, "staged", "tracked.txt"), "staged changes kept")
    eq("b", vim.trim(H.git(dir, { "show", "HEAD:b.txt" })))

    -- the last commit is amended without taking the staged changes
    vim.api.nvim_win_set_cursor(view.win, {
      (find_line(view, function(it)
        return it.kind == "commit" and it.hash == view.state.graph[1].hash and not it.refs
      end)),
      0,
    })
    vim.api.nvim_feedkeys("R", "x", false)
    ok(vim.wait(5000, function()
      return view.editor ~= nil
    end, 10))
    vim.api.nvim_buf_set_lines(view.editor.buf, 0, -1, false, { "add b (reworded)" })
    settle(view, function()
      vim.cmd("write")
    end)
    eq("add b (reworded)", vim.trim(H.git(dir, { "log", "-1", "--format=%s" })))
    ok(file_item(view, "staged", "tracked.txt"), "still staged")
  end)

  it("refuses to reword pushed commits", function()
    local remote = H.repo()
    H.git(remote, { "config", "receive.denyCurrentBranch", "ignore" })
    H.git(dir, { "remote", "add", "origin", remote })
    H.git(dir, { "push", "--quiet", "-u", "origin", "main" })
    local view = open(dir, "float")
    local lnum = find_line(view, function(it)
      return it.kind == "commit" and not it.refs
    end)
    vim.api.nvim_win_set_cursor(view.win, { lnum, 0 })
    actions.reword(view)
    eq(nil, view.editor)
    H.rm(remote)
  end)

  it("fetches with f, shows a spinner meanwhile, and draws the incoming commits", function()
    local remote = H.repo()
    H.git(remote, { "config", "receive.denyCurrentBranch", "ignore" })
    H.git(dir, { "remote", "add", "origin", remote })
    H.git(dir, { "push", "--quiet", "-u", "origin", "main" })
    -- someone else pushes a commit
    local other = H.repo()
    H.git(other, { "pull", "--quiet", remote, "main" })
    H.write(other, "theirs.txt", "x")
    H.commit(other, "their change")
    H.git(other, { "push", "--quiet", remote, "HEAD:main" })

    local view = open(dir, "float")
    eq(0, view.state.branch.behind)
    vim.api.nvim_feedkeys("f", "x", false)
    ok(view.fetch_timer, "spinner running")
    matches("fetching", view.rendered.lines[2])
    ok(vim.wait(10000, function()
      return view.fetch_timer == nil and view.state.branch.behind == 1
    end, 10), "fetched")
    ok(not view.rendered.lines[2]:find("fetching"), "spinner gone")
    eq("their change", view.state.graph[1].subject)
    ok(view.state.incoming[view.state.graph[1].hash])
    local text = table.concat(vim.api.nvim_buf_get_lines(view.buf, 0, -1, false), "\n")
    matches("○ ! %x+ their change", text)
    matches("├─╯", text)
    H.rm(remote)
    H.rm(other)
  end)

  it("zooms the Files or Graph box with z and back with z or q", function()
    H.write(dir, "tracked.txt", { "two" })
    local view = open(dir, "float")
    vim.api.nvim_win_set_cursor(view.win, { (find_line(view, function(it)
      return it.kind == "commit" and not it.refs
    end)), 0 })
    vim.api.nvim_feedkeys("z", "x", false)
    eq("graph", view.zoom)
    eq(nil, view.rendered.boxes.files)
    eq(vim.api.nvim_win_get_height(view.win) - 2, view.rendered.boxes.graph.rows)
    eq("commit", view:item().kind, "cursor stays on the commit")
    vim.api.nvim_feedkeys("q", "x", false)
    eq(nil, view.zoom)
    ok(view:valid(), "q unzoomed instead of closing")
    ok(view.rendered.boxes.files)

    vim.api.nvim_win_set_cursor(view.win, { (find_line(view, function(it)
      return it.kind == "file"
    end)), 0 })
    vim.api.nvim_feedkeys("z", "x", false)
    eq("files", view.zoom)
    eq(nil, view.rendered.boxes.graph)
    vim.api.nvim_feedkeys("z", "x", false)
    eq(nil, view.zoom)
  end)

  it("loads the history page by page while the graph is zoomed", function()
    require("git.config").setup({ status = { auto_refresh = false, graph = { max_commits = 5, zoom_page = 30 } } })
    vim.o.lines = 24 -- a page is taller than the zoomed graph
    for i = 1, 69 do
      H.git(dir, { "commit", "--quiet", "--allow-empty", "-m", "c" .. i })
    end
    local view = open(dir, "float")
    eq(5, #view.state.graph)
    vim.api.nvim_win_set_cursor(view.win, { (find_line(view, function(it)
      return it.kind == "commit" and not it.refs
    end)), 0 })
    local function settled(n)
      return vim.wait(10000, function()
        return #view.state.graph == n and not view.loading_more
      end, 10)
    end
    vim.api.nvim_feedkeys("z", "x", false)
    ok(settled(30), "first page")
    -- scrolling to the end loads the next pages, until the history ends (70 commits)
    view:scroll_box("graph", 1000)
    ok(settled(60), "second page")
    view:scroll_box("graph", 1000)
    ok(settled(70), "rest")
    view:scroll_box("graph", 1000)
    vim.wait(200)
    eq(70, #view.state.graph)
    eq("init", view.state.graph[70].subject)
    -- unzoomed: back to the short graph
    vim.api.nvim_feedkeys("z", "x", false)
    ok(settled(5), "short graph again")
  end)

  it("keeps which-key triggers out of the view so single-key maps fire at once", function()
    local fake = { disable = { ft = {}, bt = {} } }
    package.loaded["which-key.config"] = fake
    local au = vim.api.nvim_create_autocmd("FileType", {
      pattern = "gitstatus",
      callback = function(args)
        -- what which-key does for its spelling preset
        vim.keymap.set("n", "z=", "<Nop>", { buffer = args.buf, nowait = true, desc = "which-key-trigger spelling" })
      end,
    })
    local view = open(dir, "float")
    vim.wait(50)
    vim.api.nvim_del_autocmd(au)
    package.loaded["which-key.config"] = nil
    eq({ "gitstatus" }, fake.disable.ft)
    local lhs = {}
    for _, m in ipairs(vim.api.nvim_buf_get_keymap(view.buf, "n")) do
      if m.lhs:sub(1, 1) == "z" then
        lhs[#lhs + 1] = m.lhs
      end
    end
    eq({ "z" }, lhs)
  end)

  it("shows the commit menu as a centered popup like the help", function()
    H.write(dir, "tracked.txt", { "two" })
    H.git(dir, { "add", "tracked.txt" })
    local view = open(dir, "float")
    local popup = actions.popup
    local shown
    actions.popup = function(entries, title, opts)
      local win = popup(entries, title, opts)
      local cfg = vim.api.nvim_win_get_config(win)
      shown = {
        title = title,
        lines = vim.api.nvim_buf_get_lines(vim.api.nvim_win_get_buf(win), 0, -1, false),
        relative = cfg.relative,
        col = cfg.col,
        width = cfg.width,
        border = cfg.border[1],
      }
      return win
    end
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("c<Esc>", true, false, true), "x", false)
    actions.popup = popup
    ok(shown, "menu shown")
    eq(" Commit ", shown.title)
    eq("editor", shown.relative)
    eq("╭", shown.border)
    ok(math.abs(shown.col - (vim.o.columns - shown.width) / 2) <= 2, "centered")
    matches("^ c  .*Commit staged changes $", shown.lines[1])
    matches("^ a  .*Amend last commit $", shown.lines[2])
    eq(nil, view.editor, "<Esc> picks nothing")
  end)
end)
