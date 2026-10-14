local H = require("helpers")
local ui = require("git.ui")
local actions = require("git.actions")

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
      return view.generation > gen and not require("git.runner").busy() and view.state ~= nil
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
    require("git.config").setup({ auto_refresh = false })
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
    actions.open(view, "edit")
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

  it("jumps between sections", function()
    H.write(dir, "tracked.txt", { "two" })
    H.write(dir, "new.txt", "x")
    local view = open(dir, "float")
    vim.api.nvim_win_set_cursor(view.win, { 1, 0 })
    local seen = {}
    for _ = 1, #view.rendered.sections do
      actions.jump_section(view, 1)
      seen[#seen + 1] = vim.api.nvim_win_get_cursor(view.win)[1]
    end
    eq(vim.list_slice(view.rendered.sections, 2), vim.list_slice(seen, 1, #view.rendered.sections - 1))
    actions.jump_section(view, -1)
    ok(vim.api.nvim_win_get_cursor(view.win)[1] < seen[#seen])
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
    require("git.config").setup({ auto_refresh = false, keymaps = { stage = "S", discard = false } })
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
    require("git.config").setup({ auto_refresh = false, window = { border = "none" } })
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

  it("auto-refreshes when the index changes", function()
    require("git.config").setup({ auto_refresh = true, refresh_debounce = 20 })
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
end)
