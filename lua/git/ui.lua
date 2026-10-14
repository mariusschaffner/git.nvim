local config = require("git.config")
local collect = require("git.collect")
local render = require("git.render")
local util = require("git.util")

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
  local w = config.options.window
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

  self.schedule_refresh, self.cancel_refresh = util.debounce(config.options.refresh_debounce, function()
    self:refresh()
  end)

  require("git.actions").attach(self)
  self:_autocmds()
  if config.options.auto_refresh then
    self.watcher = require("git.watch").start(repo.gitdir, self.schedule_refresh)
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
  au("WinResized", {
    callback = function()
      if vim.tbl_contains(vim.v.event.windows or {}, self.win) then
        self:redraw()
      end
    end,
  })
  if config.options.auto_refresh then
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
function View:redraw()
  if not self:valid() or not self.state then
    return
  end
  local width = vim.api.nvim_win_get_width(self.win)
  local old_items = self.rendered and self.rendered.items or {}
  local cursor = vim.api.nvim_win_get_cursor(self.win)
  local first_render = self.rendered == nil
  local key = render.item_key(old_items[cursor[1]])

  local r = render.render(self.state, { width = width, expanded = self.expanded })
  self.rendered = r

  local buf = self.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, r.lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, m in ipairs(r.marks) do
    pcall(vim.api.nvim_buf_set_extmark, buf, ns, m.row, m.col, { end_col = m.end_col, hl_group = m.hl })
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
        collect.file_diff(self.repo, f, function(lines)
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
  collect.file_diff(self.repo, file, function(lines, err)
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
  local kind = opts.kind or config.options.window.kind
  require("git.highlights").ensure()

  local cur = M.current
  local start = opts.cwd
  if not start then
    -- Opening from inside the view: stay on its repo.
    if cur and not cur.closed and vim.api.nvim_get_current_buf() == cur.buf then
      start = cur.repo.root
    else
      start = require("git.repo").start_dir(0)
    end
  end

  require("git.repo").find(start, function(repo, err)
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
