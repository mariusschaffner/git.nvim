local config = require("git.config")
local collect = require("git.status.collect")
local queries = require("git.core.queries")
local render = require("git.status.render")
local util = require("git.core.util")

local M = {}

local ns = vim.api.nvim_create_namespace("git.nvim")
M.ns = ns

---@class GitView
---@field repo GitRepo
---@field kind GitWindowKind
---@field buf integer
---@field win integer
---@field prev_win integer
---@field state GitState?
---@field rendered GitRendered?
---@field expanded table<string, string[]>
---@field scroll table<string, integer> Scroll offsets of the files/graph/commit boxes
---@field commit GitCommitDetails? Commit(s) shown in the details box
---@field editor { buf: integer, win: integer?, lines: string[]? }? Commit message editor, overlaid on the "compose" box
---@field draft string[]? Commit message kept from a cancelled editor
---@field generation integer
---@field augroup integer
---@field closed boolean
---@field fetching_tags boolean
---@field watcher { stop: fun() }?
---@field schedule_refresh fun()
---@field cancel_refresh fun()
local View = {}
View.__index = View
M.View = View

---@type GitView?
M.current = nil

local function float_config(repo)
  local w = config.options.status.window
  local cols = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight - 1
  local function size(v, total)
    local n = v <= 1 and math.floor(total * v) or math.floor(v)
    return math.min(n, total)
  end
  local width = math.max(math.min(size(w.width, cols), cols - 2), 20)
  local height = math.max(math.min(size(w.height, lines), lines - 2), 5)
  -- A title needs a border; nvim errors on title + border "none".
  local has_border = w.border ~= "none" and w.border ~= ""
  return {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(math.floor((lines - height) / 2) - 1, 0),
    col = math.max(math.floor((cols - width) / 2) - 1, 0),
    style = "minimal",
    border = w.border,
    title = has_border and (" " .. vim.fs.basename(repo.root) .. " ") or nil,
    title_pos = has_border and "center" or nil,
    zindex = 50,
  }
end

local WIN_OPTS = {
  number = false,
  relativenumber = false,
  signcolumn = "no",
  foldcolumn = "0",
  foldenable = false,
  wrap = false,
  list = false,
  spell = false,
  cursorline = true,
  colorcolumn = "",
  statuscolumn = "",
  scrolloff = 0,
  winhighlight = "FloatTitle:GitStatusFloatTitle",
  winfixbuf = true,
}

local function set_win_opts(win)
  for name, value in pairs(WIN_OPTS) do
    -- winfixbuf only exists on 0.10+, but other future-missing options should not break opening either.
    pcall(vim.api.nvim_set_option_value, name, value, { win = win, scope = "local" })
  end
end

---@param repo GitRepo
---@param kind GitWindowKind
---@return GitView
function View.new(repo, kind)
  local self = setmetatable({
    repo = repo,
    kind = kind,
    prev_win = vim.api.nvim_get_current_win(),
    expanded = {},
    scroll = {},
    generation = 0,
    closed = false,
    fetching_tags = false,
  }, View)

  local buf = vim.api.nvim_create_buf(false, true)
  self.buf = buf
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].undolevels = -1
  pcall(vim.api.nvim_buf_set_name, buf, "gitstatus://" .. repo.root)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { " Loading…" })
  vim.bo[buf].modifiable = false

  if kind == "float" then
    self.win = vim.api.nvim_open_win(buf, true, float_config(repo))
  elseif kind == "tab" then
    vim.cmd("tab sbuffer " .. buf)
    self.win = vim.api.nvim_get_current_win()
  else
    self.win = vim.api.nvim_open_win(buf, true, { split = kind == "vsplit" and "right" or "below", win = 0 })
  end
  set_win_opts(self.win)

  self.schedule_refresh, self.cancel_refresh = util.debounce(config.options.status.refresh_debounce, function()
    self:refresh()
  end)

  require("git.status.actions").attach(self)
  self:_motions()
  self:_autocmds()
  if config.options.status.auto_refresh then
    self.watcher = require("git.core.watch").start(repo.gitdir, self.schedule_refresh)
  end

  -- Set last, so FileType autocmds see a fully set-up buffer (e.g. to add keymaps).
  vim.bo[buf].filetype = "gitstatus"
  return self
end

function View:_autocmds()
  self.augroup = vim.api.nvim_create_augroup("git.nvim.view." .. self.buf, { clear = true })
  local au = function(event, opts)
    opts.group = self.augroup
    vim.api.nvim_create_autocmd(event, opts)
  end
  au("BufWipeout", {
    buffer = self.buf,
    callback = function()
      self:_cleanup()
    end,
  })
  au("WinClosed", {
    pattern = tostring(self.win),
    callback = function()
      -- The buffer is wiped with its last window (bufhidden=wipe); also clean up if it got displayed elsewhere.
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(self.buf) and #vim.fn.win_findbuf(self.buf) == 0 then
          pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
        end
      end)
    end,
  })
  au("VimResized", {
    callback = function()
      if self.kind == "float" and self:valid() then
        vim.api.nvim_win_set_config(self.win, float_config(self.repo))
      end
      self:redraw()
    end,
  })
  -- The buffer always fits the window; only the boxes scroll, never the window itself.
  au("WinScrolled", {
    pattern = tostring(self.win),
    callback = function()
      if self:valid() and vim.api.nvim_buf_line_count(self.buf) <= vim.api.nvim_win_get_height(self.win) then
        vim.api.nvim_win_call(self.win, function()
          if vim.fn.line("w0") ~= 1 then
            vim.fn.winrestview({ topline = 1 })
          end
        end)
      end
    end,
  })
  au("WinResized", {
    callback = function()
      if vim.tbl_contains(vim.v.event.windows or {}, self.win) then
        self:redraw()
      end
    end,
  })
  if config.options.status.auto_refresh then
    au({ "BufWritePost", "FocusGained", "ShellCmdPost", "TermLeave" }, {
      callback = function()
        self.schedule_refresh()
      end,
    })
    au("BufEnter", {
      buffer = self.buf,
      callback = function()
        self.schedule_refresh()
      end,
    })
  end
end

function View:_cleanup()
  if self.closed then
    return
  end
  self.closed = true
  self.generation = self.generation + 1
  self.cancel_refresh()
  self:_close_editor()
  if self.watcher then
    self.watcher.stop()
  end
  pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
  if M.current == self then
    M.current = nil
  end
end

function View:valid()
  return not self.closed and vim.api.nvim_buf_is_valid(self.buf) and vim.api.nvim_win_is_valid(self.win)
end

function View:close()
  if self.closed then
    return
  end
  if vim.api.nvim_win_is_valid(self.win) then
    local ok = pcall(vim.api.nvim_win_close, self.win, true)
    if not ok then
      -- Last window: replace the buffer instead of closing the window.
      pcall(vim.api.nvim_set_option_value, "winfixbuf", false, { win = self.win })
      pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
    end
  end
  if vim.api.nvim_buf_is_valid(self.buf) then
    pcall(vim.api.nvim_buf_delete, self.buf, { force = true })
  end
  self:_cleanup()
end

function View:focus()
  if self:valid() then
    vim.api.nvim_set_current_win(self.win)
  end
end

--- Item under the cursor (or on `lnum`).
---@param lnum integer?
---@return GitItem?
function View:item(lnum)
  if not self.rendered then
    return nil
  end
  lnum = lnum or vim.api.nvim_win_get_cursor(self.win)[1]
  return self.rendered.items[lnum]
end

--- Distinct items on lines l1..l2.
---@return GitItem[]
function View:items(l1, l2)
  local out, seen = {}, {}
  if not self.rendered then
    return out
  end
  for l = math.min(l1, l2), math.max(l1, l2) do
    local it = self.rendered.items[l]
    local key = it and render.item_key(it)
    if it and not seen[key] then
      seen[key] = true
      out[#out + 1] = it
    end
  end
  return out
end

--- Re-render the current state into the buffer (no git calls).
---@param opts { keep_row: boolean?, key: string? }? keep_row: leave the cursor on its screen row instead of following
--- its entry; key: item_key of the entry to put the cursor on instead
function View:redraw(opts)
  if not self:valid() or not self.state then
    return
  end
  opts = opts or {}
  local width = vim.api.nvim_win_get_width(self.win)
  local old_items = self.rendered and self.rendered.items or {}
  local cursor = vim.api.nvim_win_get_cursor(self.win)
  local first_render = self.rendered == nil
  local key = opts.key or (not opts.keep_row and render.item_key(old_items[cursor[1]]) or nil)

  local r = render.render(self.state, {
    width = width,
    height = vim.api.nvim_win_get_height(self.win),
    expanded = self.expanded,
    commit = self.commit,
    compose = self.editor ~= nil,
    scroll = self.scroll,
    focus = key,
  })
  self.rendered = r
  self.scroll = r.scroll

  local buf = self.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(r.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl, priority = m.priority })
  end

  -- Keep the cursor on the same entry; on first render jump to the first file.
  local target
  for lnum, it in pairs(r.items) do
    local k = render.item_key(it)
    if (key and k == key) or (first_render and it.kind == "file") then
      if not target or lnum < target then
        target = lnum
      end
    end
  end
  target = target or math.min(cursor[1], #r.lines)
  pcall(vim.api.nvim_win_set_cursor, self.win, { target, target == cursor[1] and cursor[2] or 0 })
  vim.api.nvim_win_call(self.win, function()
    vim.fn.winrestview({ topline = 1 })
  end)
  self:_place_editor()
end

--- Open (or reposition) the editor window over the content rows of the "compose" box.
function View:_place_editor()
  local ed = self.editor
  local box = ed and self.rendered and self.rendered.boxes.compose
  if not box then
    return
  end
  local cfg = {
    relative = "win",
    win = self.win,
    row = box.top - 1,
    col = 2,
    width = math.max(vim.api.nvim_win_get_width(self.win) - 4, 1),
    height = box.rows,
  }
  if ed.win and vim.api.nvim_win_is_valid(ed.win) then
    vim.api.nvim_win_set_config(ed.win, cfg)
    return
  end
  cfg.style = "minimal"
  cfg.border = "none"
  cfg.zindex = 51 -- above the view's float
  ed.win = vim.api.nvim_open_win(ed.buf, false, cfg)
  vim.wo[ed.win].wrap = true
  if self.kind ~= "float" then
    vim.wo[ed.win].winhighlight = "NormalFloat:Normal"
  end
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    pattern = tostring(ed.win),
    once = true,
    callback = function()
      -- Closed by the user (e.g. :q): cancel, keeping the draft. The buffer is wiped right after.
      if vim.api.nvim_buf_is_valid(ed.buf) then
        ed.lines = vim.api.nvim_buf_get_lines(ed.buf, 0, -1, false)
      end
      vim.schedule(function()
        if self.editor == ed then
          self:stop_commit()
        end
      end)
    end,
  })
end

function View:_close_editor()
  local ed = self.editor
  self.editor = nil
  if not ed then
    return
  end
  if ed.win and vim.api.nvim_win_is_valid(ed.win) then
    pcall(vim.api.nvim_win_close, ed.win, true)
  end
  if vim.api.nvim_buf_is_valid(ed.buf) then
    pcall(vim.api.nvim_buf_delete, ed.buf, { force = true })
  end
end

--- Turn the files box into a commit message editor. `:w` or commit_submit commits the staged changes.
function View:start_commit()
  if self.editor then
    if self.editor.win and vim.api.nvim_win_is_valid(self.editor.win) then
      vim.api.nvim_set_current_win(self.editor.win)
    end
    return
  end
  if not self.state or #self.state.files.staged == 0 then
    util.notify("Nothing staged to commit")
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  pcall(vim.api.nvim_buf_set_name, buf, "gitcommit://" .. self.repo.root)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, self.draft or { "" })
  vim.bo[buf].modified = false
  self.editor = { buf = buf }
  self.commit = nil

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    group = self.augroup,
    buffer = buf,
    callback = function()
      self:submit_commit()
    end,
  })
  local function map(modes, action, fn)
    for _, lhs in ipairs(config.keys(action)) do
      vim.keymap.set(modes, lhs, fn, { buffer = buf, nowait = true, silent = true, desc = "git.nvim: " .. action })
    end
  end
  map({ "n", "i" }, "commit_submit", function()
    vim.cmd("stopinsert")
    self:submit_commit()
  end)
  map("n", "commit_abort", function()
    self:stop_commit()
  end)
  map("n", "help", function()
    require("git.status.actions").help(self, "compose")
  end)

  self:redraw()
  if not (self.editor and self.editor.win) then
    self:_close_editor()
    return
  end
  vim.api.nvim_set_current_win(self.editor.win)
  vim.bo[buf].filetype = "gitcommit"
  if not self.draft then
    vim.cmd("startinsert")
  end
end

--- Leave the commit message editor. The message is kept as a draft unless `discard`.
---@param discard boolean?
function View:stop_commit(discard)
  local ed = self.editor
  if not ed then
    return
  end
  if discard then
    self.draft = nil
  else
    local lines = vim.api.nvim_buf_is_valid(ed.buf) and vim.api.nvim_buf_get_lines(ed.buf, 0, -1, false) or ed.lines
    self.draft = lines and vim.trim(table.concat(lines, "\n")) ~= "" and lines or nil
  end
  self:_close_editor()
  if self:valid() then
    vim.cmd("stopinsert")
    self:focus()
    self:redraw()
  end
end

--- Commit the staged changes with the editor's message.
---@param cb fun(ok: boolean)?
function View:submit_commit(cb)
  local ed = self.editor
  if not ed or not vim.api.nvim_buf_is_valid(ed.buf) then
    return
  end
  local msg = table.concat(vim.api.nvim_buf_get_lines(ed.buf, 0, -1, false), "\n")
  if vim.trim(msg) == "" then
    util.notify("Empty commit message", vim.log.levels.WARN)
    if cb then
      cb(false)
    end
    return
  end
  vim.bo[ed.buf].modified = false
  local runner = require("git.core.runner")
  runner.mutate(
    { "commit", "--quiet", "--cleanup=whitespace", "--file=-" },
    { cwd = self.repo.root, stdin = msg .. "\n" },
    function(res)
      local ok = res.code == 0
      if not ok then
        util.notify(runner.error_message(res), vim.log.levels.ERROR)
      elseif self.editor == ed then
        self:stop_commit(true)
      else
        -- The editor was closed meanwhile (e.g. :wq); its message is committed, not a draft.
        self.draft = nil
      end
      self:refresh()
      if cb then
        cb(ok)
      end
    end
  )
end

--- Show a commit's details in a box below the graph (in place of the files); again on the same commit hides it.
---@param hash string
---@param cb fun()?
function View:toggle_commit(hash, cb)
  self:toggle_commits({ hash }, cb)
end

--- Like toggle_commit, for several commits shown combined (headers, then one diff over all of them).
---@param hashes string[] Newest first, as in the graph
---@param cb fun()?
function View:toggle_commits(hashes, cb)
  local hash = hashes[1]
  if self.commit and vim.deep_equal(self.commit.hashes, hashes) then
    self:hide_commit()
    if cb then
      cb()
    end
    return
  end
  local function done(lines, err)
    if self.closed then
      return
    end
    if not lines then
      util.notify(err or "git show failed", vim.log.levels.ERROR)
      return
    end
    self.commit = { hash = hash, hashes = hashes, lines = lines }
    self.scroll.commit = 0
    self:redraw()
    -- Start in the details, so scrolling moves through them right away.
    local box = self.rendered and self.rendered.boxes.commit
    if box and self:valid() then
      vim.api.nvim_win_set_cursor(self.win, { box.top, 0 })
    end
    if cb then
      cb()
    end
  end
  if #hashes == 1 then
    queries.commit_details(self.repo, hash, done)
  else
    queries.commits_details(self.repo, hashes, done)
  end
end

function View:hide_commit()
  local hash = self.commit and self.commit.hash
  self.commit = nil
  -- Back on the commit whose details were shown.
  self:redraw({ key = hash and ("commit:" .. hash) })
end

--- Name and layout of the scrollable box showing line `lnum`.
---@param lnum integer
---@return string?, GitBox?
function View:box_at(lnum)
  for name, b in pairs(self.rendered and self.rendered.boxes or {}) do
    if lnum >= b.top and lnum < b.top + b.rows then
      return name, b
    end
  end
end

--- Scroll a box by `delta` content rows; the cursor stays on its screen row.
---@param name string
---@param delta integer
---@return boolean scrolled
function View:scroll_box(name, delta)
  local b = self.rendered and self.rendered.boxes[name]
  if not b then
    return false
  end
  local offset = math.max(math.min(b.offset + delta, b.total - b.rows), 0)
  if offset == b.offset then
    return false
  end
  self.scroll[name] = offset
  self:redraw({ keep_row = true })
  return true
end

--- Box to scroll for scroll keys: the one under the cursor, else the graph.
function View:_scroll_target()
  local name = self:box_at(vim.api.nvim_win_get_cursor(self.win)[1])
  return name or "graph"
end

--- j/k scroll a box when moving past its visible edge; scroll keys and the mouse wheel scroll boxes, not the window.
function View:_motions()
  local function map(lhs, fn)
    vim.keymap.set("n", lhs, fn, { buffer = self.buf, nowait = true, silent = true, desc = "git.nvim: scroll" })
  end
  local function move(dir, key)
    return function()
      for _ = 1, vim.v.count1 do
        local lnum = vim.api.nvim_win_get_cursor(self.win)[1]
        local name, b = self:box_at(lnum)
        local edge = b and lnum == (dir > 0 and b.top + b.rows - 1 or b.top)
        if not (edge and self:scroll_box(name, dir)) then
          local graph = self.rendered.boxes.graph
          if edge and dir < 0 and name == "commit" and graph then
            -- Up out of the commit details: to the top of the graph, to move down through it from there.
            self.scroll.graph = 0
            self:redraw({ keep_row = true })
            vim.api.nvim_win_set_cursor(self.win, { self.rendered.boxes.graph.top, 0 })
          else
            vim.cmd("normal! " .. key)
          end
        end
      end
    end
  end
  map("j", move(1, "j"))
  map("<Down>", move(1, "j"))
  map("k", move(-1, "k"))
  map("<Up>", move(-1, "k"))

  local function rows()
    local b = self.rendered and self.rendered.boxes[self:_scroll_target()]
    return b and b.rows or 1
  end
  local scrolls = {
    ["<C-e>"] = function()
      return 1
    end,
    ["<C-y>"] = function()
      return -1
    end,
    ["<C-d>"] = function()
      return math.max(math.floor(rows() / 2), 1)
    end,
    ["<C-u>"] = function()
      return -math.max(math.floor(rows() / 2), 1)
    end,
    ["<C-f>"] = rows,
    ["<C-b>"] = function()
      return -rows()
    end,
    ["<PageDown>"] = rows,
    ["<PageUp>"] = function()
      return -rows()
    end,
  }
  for lhs, amount in pairs(scrolls) do
    map(lhs, function()
      self:scroll_box(self:_scroll_target(), amount() * vim.v.count1)
    end)
  end

  for lhs, dir in pairs({ ["<ScrollWheelDown>"] = 1, ["<ScrollWheelUp>"] = -1 }) do
    map(lhs, function()
      local pos = vim.fn.getmousepos()
      if pos.winid ~= self.win then
        -- Over another window: keep the default wheel behavior there.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(lhs, true, false, true), "n", false)
        return
      end
      self:scroll_box(self:box_at(pos.line) or "graph", 3 * dir)
    end)
  end
end

--- Fetch fresh state from git and redraw. Results of superseded refreshes are discarded.
---@param cb fun()?
function View:refresh(cb)
  if self.closed then
    return
  end
  self.generation = self.generation + 1
  local gen = self.generation
  collect.collect(self.repo, function(state, err)
    if gen ~= self.generation or self.closed then
      return
    end
    if not state then
      util.notify(err or "git status failed", vim.log.levels.ERROR)
      return
    end
    self:_refresh_diffs(state, function()
      if gen ~= self.generation or self.closed then
        return
      end
      self.state = state
      self:redraw()
      self:_maybe_fetch_tags(state)
      if cb then
        cb()
      end
    end)
  end)
end

--- Re-fetch the expanded diffs for files that still exist; forget the others.
function View:_refresh_diffs(state, cb)
  local present = {}
  for _, list in pairs(state.files) do
    for _, f in ipairs(list) do
      present[render.diff_key(f)] = f
    end
  end
  local tasks = {}
  local expanded = {}
  for key in pairs(self.expanded) do
    local f = present[key]
    if f then
      tasks[#tasks + 1] = function(done)
        queries.file_diff(self.repo, f, function(lines)
          expanded[key] = lines or { "(diff unavailable)" }
          done()
        end)
      end
    end
  end
  util.all(tasks, function()
    self.expanded = expanded
    cb()
  end)
end

function View:_maybe_fetch_tags(state)
  if self.fetching_tags then
    return
  end
  local needs = collect.resolve_unpushed_tags(state)
  local remote = collect.tag_remote(state)
  if not needs or not remote then
    return
  end
  self.fetching_tags = true
  collect.fetch_remote_tags(self.repo, remote, function()
    self.fetching_tags = false
    if self.closed or self.state ~= state then
      return
    end
    collect.resolve_unpushed_tags(state)
    self:redraw()
  end)
end

--- Toggle the inline diff of a file.
---@param file GitFile
---@param expand boolean? Force expand (true) or collapse (false)
---@param cb fun()?
function View:toggle_diff(file, expand, cb)
  local key = render.diff_key(file)
  if expand == nil then
    expand = self.expanded[key] == nil
  end
  if not expand then
    self.expanded[key] = nil
    self:redraw()
    if cb then
      cb()
    end
    return
  end
  queries.file_diff(self.repo, file, function(lines, err)
    if self.closed then
      return
    end
    if not lines then
      util.notify(err or "diff failed", vim.log.levels.ERROR)
      return
    end
    self.expanded[key] = lines
    self:redraw()
    if cb then
      cb()
    end
  end)
end

---@class GitOpenOpts
---@field kind GitWindowKind?
---@field cwd string? Directory to resolve the repository from (default: current file's dir or cwd)

--- Open (or focus) the status view.
---@param opts GitOpenOpts?
---@param cb fun(view: GitView?)?
function M.open(opts, cb)
  opts = opts or {}
  local kind = opts.kind or config.options.status.window.kind
  require("git.highlights").ensure()

  local cur = M.current
  local start = opts.cwd
  if not start then
    -- Opening from inside the view: stay on its repo.
    if cur and not cur.closed and vim.api.nvim_get_current_buf() == cur.buf then
      start = cur.repo.root
    else
      start = require("git.core.repo").start_dir(0)
    end
  end

  require("git.core.repo").find(start, function(repo, err)
    if not repo then
      util.notify(err or "Not a git repository", vim.log.levels.WARN)
      if cb then
        cb(nil)
      end
      return
    end
    cur = M.current
    if cur and not cur.closed then
      if cur.repo.root == repo.root and cur.kind == kind and cur:valid() then
        cur:focus()
        cur:refresh(function()
          if cb then
            cb(cur)
          end
        end)
        return
      end
      cur:close()
    end
    local view = View.new(repo, kind)
    M.current = view
    view:refresh(function()
      if cb then
        cb(view)
      end
    end)
  end)
end

function M.close()
  if M.current then
    M.current:close()
  end
end

---@param opts GitOpenOpts?
function M.toggle(opts)
  if M.current and M.current:valid() then
    M.current:close()
  else
    M.open(opts)
  end
end

function M.refresh()
  if M.current and M.current:valid() then
    M.current:refresh()
  end
end

return M
