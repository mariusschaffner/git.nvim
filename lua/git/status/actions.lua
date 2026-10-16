local config = require("git.config")
local runner = require("git.core.runner")
local util = require("git.core.util")

local M = {}

---@param view GitView
---@param items GitItem[]
---@return GitFile[]
local function files_of(view, items)
  local out, seen = {}, {}
  local function push(f)
    local key = f.section .. "\0" .. f.path
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = f
    end
  end
  for _, it in ipairs(items) do
    if (it.kind == "file" or it.kind == "diff") and it.file then
      push(it.file)
    elseif it.kind == "section" and view.state then
      for _, f in ipairs(view.state.files[it.section] or {}) do
        push(f)
      end
    end
  end
  return out
end

local function by_section(files)
  local groups = { conflicted = {}, staged = {}, unstaged = {}, untracked = {} }
  for _, f in ipairs(files) do
    table.insert(groups[f.section], f)
  end
  return groups
end

--- Run `prefix -- <paths>` (chunked) as serialized mutations; refresh once all are done.
---@param view GitView
---@param jobs { args: string[], paths: string[] }[]
local function run_jobs(view, jobs)
  local pending = 0
  local failed = false
  local function finish()
    pending = pending - 1
    if pending == 0 then
      view:refresh()
    end
  end
  for _, job in ipairs(jobs) do
    for _, chunk in ipairs(util.chunk(job.paths)) do
      pending = pending + 1
      local args = vim.list_extend(vim.list_extend({}, job.args), { "--" })
      vim.list_extend(args, chunk)
      runner.mutate(args, { cwd = view.repo.root, literal = true }, function(res)
        if res.code ~= 0 and not failed then
          failed = true
          util.notify(runner.error_message(res), vim.log.levels.ERROR)
        end
        finish()
      end)
    end
  end
  return pending > 0
end

local function paths(files, with_orig)
  local out = {}
  for _, f in ipairs(files) do
    if with_orig and f.orig then
      out[#out + 1] = f.orig
    end
    out[#out + 1] = f.path
  end
  return out
end

---@param view GitView
---@param items GitItem[]
function M.stage(view, items)
  local g = by_section(files_of(view, items))
  local todo = vim.list_extend(vim.list_extend(vim.list_extend({}, g.unstaged), g.untracked), g.conflicted)
  if #todo == 0 then
    util.notify("Nothing to stage here")
    return
  end
  run_jobs(view, { { args = { "add" }, paths = paths(todo) } })
end

---@param view GitView
---@param items GitItem[]
function M.unstage(view, items)
  local staged = by_section(files_of(view, items)).staged
  if #staged == 0 then
    util.notify("Nothing to unstage here")
    return
  end
  local args = view.state and view.state.branch.unborn and { "rm", "--cached", "-r", "--quiet" }
    or { "restore", "--staged" }
  run_jobs(view, { { args = args, paths = paths(staged, true) } })
end

---@param view GitView
---@param items GitItem[]
function M.discard(view, items)
  local g = by_section(files_of(view, items))
  local tracked, untracked = g.unstaged, g.untracked
  if #tracked + #untracked == 0 then
    if #g.staged > 0 then
      util.notify("Unstage the changes before discarding them", vim.log.levels.WARN)
    elseif #g.conflicted > 0 then
      util.notify("Resolve conflicts first (e.g. git checkout --ours/--theirs)", vim.log.levels.WARN)
    else
      util.notify("Nothing to discard here")
    end
    return
  end

  local names = {}
  for _, f in ipairs(vim.list_extend(vim.list_extend({}, tracked), untracked)) do
    if #names == 5 then
      names[#names + 1] = "…"
      break
    end
    names[#names + 1] = "  " .. f.path
  end
  local what = {}
  if #tracked > 0 then
    what[#what + 1] = ("discard changes in %d file(s)"):format(#tracked)
  end
  if #untracked > 0 then
    what[#what + 1] = ("delete %d untracked file(s)"):format(#untracked)
  end
  local msg = ("This will %s. It cannot be undone.\n%s"):format(table.concat(what, " and "), table.concat(names, "\n"))
  if vim.fn.confirm(msg, "&Discard\n&Cancel", 2, "Warning") ~= 1 then
    return
  end

  local jobs = {}
  if #tracked > 0 then
    jobs[#jobs + 1] = { args = { "restore", "--worktree" }, paths = paths(tracked) }
  end
  if #untracked > 0 then
    jobs[#jobs + 1] = { args = { "clean", "--force", "-d", "--quiet" }, paths = paths(untracked) }
  end
  run_jobs(view, jobs)
end

--- Line in the new file that a diff line corresponds to (nil for header lines).
---@param diff string[]
---@param idx integer
---@return integer?
function M.diff_target_line(diff, idx)
  local offset = 0
  for i = idx, 1, -1 do
    local line = diff[i]
    local start = line:match("^@@+ [^@]*%+(%d+)")
    if start then
      return math.max(tonumber(start) + offset, 1)
    end
    local c = line:sub(1, 1)
    if i ~= idx and c ~= "-" and c ~= "\\" then
      offset = offset + 1
    end
    if line:match("^diff ") then
      return nil
    end
  end
  return nil
end

--- Move to the window files should be opened in. Closes the float first.
---@param view GitView
---@param cmd "edit"|"split"|"vsplit"|"tabedit"
---@return string cmd The command to run in the target window
local function goto_target(view, cmd)
  local prev = view.prev_win
  if view.kind == "float" then
    view:close()
  end
  if prev and vim.api.nvim_win_is_valid(prev) and prev ~= view.win then
    vim.api.nvim_set_current_win(prev)
  elseif cmd == "edit" and vim.api.nvim_get_current_win() == view.win then
    -- The view window is pinned to its buffer (winfixbuf); open next to it instead.
    return "vsplit"
  end
  return cmd
end

---@param view GitView
---@param cmd "edit"|"split"|"vsplit"|"tabedit"
---@param item GitItem?
function M.open(view, cmd, item)
  item = item or view:item()
  if not item then
    return
  end
  if item.kind == "commit" then
    if cmd == "edit" then
      view:toggle_commit(item.hash)
    else
      M.show(view, { "show", "--stat", "--patch", "--format=fuller", item.hash }, "git://show/" .. item.hash, cmd)
    end
    return
  elseif item.kind == "stash" then
    M.show(view, { "stash", "show", "--stat", "--patch", item.stash.ref }, "git://stash/" .. item.stash.ref, cmd)
    return
  elseif item.kind == "section" then
    return
  end

  local f = item.file
  local path = view.repo.root .. "/" .. f.path
  local uv = vim.uv or vim.loop
  if not uv.fs_stat(path) then
    util.notify(("%s does not exist in the work tree"):format(f.path), vim.log.levels.WARN)
    return
  end
  local lnum
  if item.kind == "diff" and item.diff_line then
    local diff = view.expanded[require("git.status.render").diff_key(f)]
    lnum = diff and M.diff_target_line(diff, item.diff_line)
  end
  local run = goto_target(view, cmd)
  vim.cmd((lnum and (run .. " +" .. lnum .. " ") or (run .. " ")) .. vim.fn.fnameescape(path))
end

--- Show git output in a read-only scratch buffer.
---@param view GitView
---@param args string[]
---@param name string
---@param cmd "edit"|"split"|"vsplit"|"tabedit"
function M.show(view, args, name, cmd)
  runner.run(args, { cwd = view.repo.root }, function(res)
    if res.code ~= 0 then
      util.notify(runner.error_message(res), vim.log.levels.ERROR)
      return
    end
    local lines = vim.split((res.stdout:gsub("\r\n", "\n")), "\n", { plain = true })
    if lines[#lines] == "" then
      lines[#lines] = nil
    end
    for i, l in ipairs(lines) do
      lines[i] = l:gsub("[\r\n]", "")
    end
    local run = goto_target(view, cmd)
    local open = ({ edit = "enew", split = "new", vsplit = "vnew", tabedit = "tabnew" })[run] or "new"
    vim.cmd(open)
    local buf = vim.api.nvim_get_current_buf()
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].swapfile = false
    pcall(vim.api.nvim_buf_set_name, buf, name)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "git"
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, silent = true })
  end)
end

---@param view GitView
---@param op "pop"|"apply"|"drop"
function M.stash(view, op)
  local item = view:item()
  if not item or item.kind ~= "stash" then
    util.notify("Move the cursor to a stash entry first")
    return
  end
  local ref = item.stash.ref
  if
    op == "drop"
    and vim.fn.confirm(("Drop %s?\n  %s"):format(ref, item.stash.subject), "&Drop\n&Cancel", 2, "Warning") ~= 1
  then
    return
  end
  runner.mutate({ "stash", op, "--quiet", ref }, { cwd = view.repo.root }, function(res)
    if res.code ~= 0 then
      util.notify(runner.error_message(res), vim.log.levels.ERROR)
    end
    view:refresh()
  end)
end

---@param view GitView
function M.commit(view)
  view:start_commit()
end

--- Revert the commit under the cursor (`git revert`), after confirmation. Merges are reverted against
--- their first parent.
---@param view GitView
function M.revert(view)
  local item = view:item()
  if not item or item.kind ~= "commit" then
    util.notify("Move the cursor to a commit in the graph first")
    return
  end
  local commit
  for _, c in ipairs(view.state and view.state.graph or {}) do
    if c.hash == item.hash then
      commit = c
      break
    end
  end
  local merge = commit and #commit.parents > 1
  local name = commit and commit.abbrev or item.hash:sub(1, 8)
  local msg = ("Revert %s?\n  %s"):format(name, commit and commit.subject or "")
  if merge then
    msg = msg .. "\nThis is a merge commit: it is reverted against its first parent."
  end
  if vim.fn.confirm(msg, "&Revert\n&Cancel", 2, "Question") ~= 1 then
    return
  end
  local args = { "revert", "--no-edit" }
  if merge then
    vim.list_extend(args, { "-m", "1" })
  end
  args[#args + 1] = item.hash
  runner.mutate(args, { cwd = view.repo.root }, function(res)
    if res.code ~= 0 then
      util.notify(runner.error_message(res), vim.log.levels.ERROR)
    end
    view:refresh()
  end)
end

---@param view GitView
---@param items GitItem[]
function M.toggle_diff(view, items)
  local fs = files_of(view, items)
  if #fs == 0 then
    return
  end
  local diff_key = require("git.status.render").diff_key
  if #fs == 1 then
    view:toggle_diff(fs[1])
    return
  end
  -- Several files (section header / visual range): expand all unless all are expanded already.
  local all_open = true
  for _, f in ipairs(fs) do
    if not view.expanded[diff_key(f)] then
      all_open = false
      break
    end
  end
  for _, f in ipairs(fs) do
    view:toggle_diff(f, not all_open)
  end
end

---@param view GitView
---@param dir 1|-1
function M.jump_section(view, dir)
  if not view.rendered then
    return
  end
  local cur = vim.api.nvim_win_get_cursor(view.win)[1]
  local target
  for _, lnum in ipairs(view.rendered.sections) do
    if dir > 0 and lnum > cur and (not target or lnum < target) then
      target = lnum
    elseif dir < 0 and lnum < cur and (not target or lnum > target) then
      target = lnum
    end
  end
  if target then
    vim.api.nvim_win_set_cursor(view.win, { target, 0 })
  end
end

M.descriptions = {
  stage = "Stage file / section / selection (marks conflicts resolved)",
  unstage = "Unstage file / section / selection",
  discard = "Discard unstaged changes / delete untracked files",
  toggle_diff = "Toggle inline diff",
  open = "Open file or stash / toggle commit details",
  open_split = "Open in a horizontal split",
  open_vsplit = "Open in a vertical split",
  open_tab = "Open in a new tab",
  stash_pop = "Pop stash under cursor",
  stash_apply = "Apply stash under cursor",
  stash_drop = "Drop stash under cursor",
  commit = "Commit staged changes (edit the message in place)",
  revert = "Revert commit under cursor (asks first)",
  commit_submit = "Commit message editor: commit",
  commit_abort = "Commit message editor: cancel (keeps the draft)",
  next_section = "Next section",
  prev_section = "Previous section",
  refresh = "Refresh",
  close = "Close (commit editor / details first)",
  help = "Show this help",
}

M.order = {
  "stage",
  "unstage",
  "discard",
  "toggle_diff",
  "open",
  "open_split",
  "open_vsplit",
  "open_tab",
  "stash_pop",
  "stash_apply",
  "stash_drop",
  "commit",
  "revert",
  "next_section",
  "prev_section",
  "refresh",
  "help",
  "close",
  "commit_submit",
  "commit_abort",
}

-- Actions listed in the help per box (see `GitRendered.regions`); `M.general` follows in every box.
M.contexts = {
  branches = {},
  tags = {},
  stashes = { "stash_pop", "stash_apply", "stash_drop", "open", "open_split", "open_vsplit", "open_tab" },
  files = {
    "stage",
    "unstage",
    "discard",
    "toggle_diff",
    "commit",
    "open",
    "open_split",
    "open_vsplit",
    "open_tab",
  },
  graph = { "open", "open_split", "open_vsplit", "open_tab", "revert" },
  commit = {},
  compose = { "commit_submit", "commit_abort" },
}
M.general = { "next_section", "prev_section", "refresh", "help", "close" }

-- Descriptions that read better than `M.descriptions` in a given box.
M.context_descriptions = {
  stashes = {
    open = "Show stash (git stash show -p)",
    open_split = "Show stash in a horizontal split",
    open_vsplit = "Show stash in a vertical split",
    open_tab = "Show stash in a new tab",
  },
  files = { open = "Open file (on a diff line: at that line)" },
  graph = {
    open = "Toggle commit details",
    open_split = "Show commit in a horizontal split",
    open_vsplit = "Show commit in a vertical split",
    open_tab = "Show commit in a new tab",
  },
  commit = { close = "Close commit details" },
  compose = { commit_submit = "Commit (also :w)", commit_abort = "Cancel (keeps the draft)" },
}

local BOX_TITLE = {
  branches = "Branches",
  tags = "Tags",
  stashes = "Stashes",
  files = "Files",
  graph = "Graph",
  commit = "Commit",
  compose = "Commit message",
}

--- Name of the box at `lnum` in the view.
---@param view GitView
---@param lnum integer
---@return string?
function M.box_at(view, lnum)
  for _, r in ipairs(view.rendered and view.rendered.regions or {}) do
    if lnum >= r.first and lnum <= r.last then
      return r.name
    end
  end
end

--- Help lines for a box (all keymaps when `box` is nil): { lhs, description }[].
---@param box string?
---@return { [1]: string, [2]: string }[]
function M.help_entries(box)
  local actions = M.order
  if box and M.contexts[box] then
    -- The commit message editor is its own buffer: only its keys and help apply there.
    local rest = box == "compose" and { "help" } or M.general
    actions = vim.list_extend(vim.list_extend({}, M.contexts[box]), rest)
  end
  local overrides = box and M.context_descriptions[box] or {}
  local out = {}
  for _, action in ipairs(actions) do
    local keys = config.keys(action)
    if #keys > 0 then
      out[#out + 1] = { table.concat(keys, " "), overrides[action] or M.descriptions[action] }
    end
  end
  return out
end

--- Show the keymaps relevant to the box under the cursor (or `box`) in a bordered float.
---@param view GitView
---@param box string? Defaults to the box under the cursor in the view
function M.help(view, box)
  local from = vim.api.nvim_get_current_win()
  if not box and from == view.win then
    box = M.box_at(view, vim.api.nvim_win_get_cursor(view.win)[1])
  end
  local lines = {}
  local width = 0
  for _, e in ipairs(M.help_entries(box)) do
    local line = (" %-12s %s "):format(e[1], e[2])
    lines[#lines + 1] = line
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  local title = " " .. (box and (BOX_TITLE[box] .. " ") or "git.nvim ") .. "keymaps "
  width = math.max(width, vim.fn.strdisplaywidth(title) + 2)
  -- The view itself may be borderless; the popup always gets a border.
  local border = config.options.status.window.border
  if border == "none" or border == "" then
    border = "rounded"
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = #lines,
    row = math.max(math.floor((vim.o.lines - #lines) / 2) - 2, 0),
    col = math.max(math.floor((vim.o.columns - width) / 2) - 1, 0),
    style = "minimal",
    border = border,
    title = title,
    title_pos = "center",
    zindex = 60,
  })
  vim.wo[win].winhighlight = "FloatTitle:GitStatusFloatTitle,FloatBorder:GitStatusBorder"
  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, function()
      pcall(vim.api.nvim_win_close, win, true)
      if vim.api.nvim_win_is_valid(from) then
        vim.api.nvim_set_current_win(from)
      end
    end, { buffer = buf, nowait = true, silent = true })
  end
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_close, win, true)
    end,
  })
  return win
end

--- Items under the cursor in normal mode, or in the selected line range in visual mode (then exits visual mode).
local function target_items(view)
  local mode = vim.api.nvim_get_mode().mode
  if mode:match("^[vV\22]") then
    local l1, l2 = vim.fn.line("v"), vim.fn.line(".")
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    return view:items(l1, l2)
  end
  local it = view:item()
  return it and { it } or {}
end

--- Install buffer-local keymaps on the view's buffer.
---@param view GitView
function M.attach(view)
  local handlers = {
    stage = {
      { "n", "x" },
      function()
        M.stage(view, target_items(view))
      end,
    },
    unstage = {
      { "n", "x" },
      function()
        M.unstage(view, target_items(view))
      end,
    },
    discard = {
      { "n", "x" },
      function()
        M.discard(view, target_items(view))
      end,
    },
    toggle_diff = {
      { "n", "x" },
      function()
        M.toggle_diff(view, target_items(view))
      end,
    },
    open = {
      "n",
      function()
        M.open(view, "edit")
      end,
    },
    open_split = {
      "n",
      function()
        M.open(view, "split")
      end,
    },
    open_vsplit = {
      "n",
      function()
        M.open(view, "vsplit")
      end,
    },
    open_tab = {
      "n",
      function()
        M.open(view, "tabedit")
      end,
    },
    stash_pop = {
      "n",
      function()
        M.stash(view, "pop")
      end,
    },
    stash_apply = {
      "n",
      function()
        M.stash(view, "apply")
      end,
    },
    stash_drop = {
      "n",
      function()
        M.stash(view, "drop")
      end,
    },
    commit = {
      "n",
      function()
        M.commit(view)
      end,
    },
    revert = {
      "n",
      function()
        M.revert(view)
      end,
    },
    next_section = {
      { "n", "x" },
      function()
        M.jump_section(view, 1)
      end,
    },
    prev_section = {
      { "n", "x" },
      function()
        M.jump_section(view, -1)
      end,
    },
    refresh = {
      "n",
      function()
        view:refresh()
      end,
    },
    close = {
      "n",
      function()
        if view.editor then
          view:stop_commit()
        elseif view.commit then
          view:hide_commit()
        else
          view:close()
        end
      end,
    },
    help = {
      "n",
      function()
        M.help(view)
      end,
    },
  }
  for action, h in pairs(handlers) do
    for _, lhs in ipairs(config.keys(action)) do
      -- <Esc> closing a split/tab would be surprising; only floats close on it.
      if not (action == "close" and lhs:lower() == "<esc>" and view.kind ~= "float") then
        vim.keymap.set(h[1], lhs, h[2], {
          buffer = view.buf,
          nowait = true,
          silent = true,
          desc = "git.nvim: " .. M.descriptions[action],
        })
      end
    end
  end
end

return M
