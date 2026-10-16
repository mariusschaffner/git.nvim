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
---@return "edit"|"vsplit" cmd How to open in the target window
local function goto_target(view)
  local prev = view.prev_win
  if view.kind == "float" then
    view:close()
  end
  if prev and vim.api.nvim_win_is_valid(prev) and prev ~= view.win then
    vim.api.nvim_set_current_win(prev)
  elseif vim.api.nvim_get_current_win() == view.win then
    -- The view window is pinned to its buffer (winfixbuf); open next to it instead.
    return "vsplit"
  end
  return "edit"
end

--- Open the file (on a diff line: at that line) or stash; toggle a commit's details.
---@param view GitView
---@param item GitItem?
function M.open(view, item)
  item = item or view:item()
  if not item then
    return
  end
  if item.kind == "commit" then
    view:toggle_commit(item.hash)
    return
  elseif item.kind == "stash" then
    M.show(view, { "stash", "show", "--stat", "--patch", item.stash.ref }, "git://stash/" .. item.stash.ref)
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
  local run = goto_target(view)
  vim.cmd((lnum and (run .. " +" .. lnum .. " ") or (run .. " ")) .. vim.fn.fnameescape(path))
end

--- <CR> on the cursor item, or on a visual selection: several commits show their details combined,
--- anything else opens the first selected item.
---@param view GitView
---@param items GitItem[]
function M.open_items(view, items)
  local hashes = {}
  for _, it in ipairs(items) do
    if it.kind == "commit" then
      hashes[#hashes + 1] = it.hash
    end
  end
  if #hashes > 1 then
    view:toggle_commits(hashes)
  elseif items[1] then
    M.open(view, items[1])
  end
end

--- Show git output in a read-only scratch buffer.
---@param view GitView
---@param args string[]
---@param name string
function M.show(view, args, name)
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
    vim.cmd(goto_target(view) == "vsplit" and "vnew" or "enew")
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

--- The commit menu: a popup lists the follow-up keys (commit / amend) and the next key picks one.
---@param view GitView
function M.commit(view)
  local entries = {}
  for _, e in ipairs({ { "commit_create", "commit", M.create }, { "commit_amend", "amend", M.amend } }) do
    local key = config.key(e[1])
    if key then
      entries[#entries + 1] = { key = key, label = e[2], fn = e[3] }
    end
  end
  local lines, width = {}, 0
  for i, e in ipairs(entries) do
    lines[i] = (" %s  %s "):format(e.key, e.label)
    width = math.max(width, vim.fn.strdisplaywidth(lines[i]))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  for i, e in ipairs(entries) do
    vim.api.nvim_buf_set_extmark(buf, vim.api.nvim_create_namespace("git.nvim.menu"), i - 1, 1, {
      end_col = 1 + #e.key,
      hl_group = "GitStatusLabel",
    })
  end
  local win = vim.api.nvim_open_win(buf, false, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = math.max(width, 10),
    height = #lines,
    style = "minimal",
    border = "rounded",
    title = " Commit ",
    title_pos = "center",
    focusable = false,
    zindex = 60,
    noautocmd = true,
  })
  vim.wo[win].winhighlight = "FloatTitle:GitStatusFloatTitle,FloatBorder:GitStatusBorder"
  vim.cmd("redraw")
  local ok, char = pcall(vim.fn.getcharstr)
  pcall(vim.api.nvim_win_close, win, true)
  if not ok then
    return
  end
  for _, e in ipairs(entries) do
    if char == vim.api.nvim_replace_termcodes(e.key, true, false, true) then
      e.fn(view)
      return
    end
  end
end

--- Commit the staged changes: the files box turns into a message editor.
---@param view GitView
function M.create(view)
  view:start_commit()
end

--- Amend the last commit with the staged changes, editing its message. Asks first when it is pushed already.
---@param view GitView
function M.amend(view)
  local state = view.state
  if not state or state.branch.unborn or not state.branch.oid then
    util.notify("No commit to amend yet")
    return
  end
  local head = state.branch.oid
  local pushed = (state.branch.upstream or #state.remotes > 0) and not state.unpushed[head]
  if
    pushed
    and vim.fn.confirm(
        ("%s is pushed already. Amending rewrites it.\nAmend anyway?"):format(head:sub(1, 8)),
        "&Amend\n&Cancel",
        2,
        "Warning"
      )
      ~= 1
  then
    return
  end
  require("git.core.queries").commit_message(view.repo, head, function(lines, err)
    if not lines then
      util.notify(err or "git log failed", vim.log.levels.ERROR)
      return
    end
    local n = #state.files.staged
    local title = n > 0 and ("Amend %s (+%d staged file%s)"):format(head:sub(1, 8), n, n == 1 and "" or "s")
      or ("Amend %s (message only)"):format(head:sub(1, 8))
    view:start_commit({ mode = "amend", lines = lines, title = title })
  end)
end

--- Change the message of the unpushed commit under the cursor.
---@param view GitView
function M.reword(view)
  local item = view:item()
  if not item or item.kind ~= "commit" then
    util.notify("Move the cursor to a commit in the graph first")
    return
  end
  if not (view.state and view.state.unpushed[item.hash]) then
    util.notify("Only unpushed commits can be reworded", vim.log.levels.WARN)
    return
  end
  require("git.core.queries").commit_message(view.repo, item.hash, function(lines, err)
    if not lines then
      util.notify(err or "git log failed", vim.log.levels.ERROR)
      return
    end
    view:start_commit({
      mode = "reword",
      hash = item.hash,
      lines = lines,
      title = ("Reword %s"):format(item.hash:sub(1, 8)),
    })
  end)
end

--- Replace the message of `hash`, an ancestor of HEAD (or HEAD itself). HEAD is amended (staged changes stay
--- staged). An older commit is recreated with the new message, the commits between it and HEAD are recreated
--- on top of it (same trees, authors and messages), and the branch is moved there with `reset --soft`: the
--- index and work tree are never touched.
---@param view GitView
---@param hash string
---@param msg string
---@param cb fun(res: GitResult)
function M.set_message(view, hash, msg, cb)
  local cwd = view.repo.root
  local head = view.state and view.state.branch.oid
  if hash == head then
    local args = { "commit", "--amend", "--only", "--quiet", "--cleanup=whitespace", "--file=-" }
    runner.mutate(args, { cwd = cwd, stdin = msg }, cb)
    return
  end
  -- The commit itself, then its descendants up to HEAD, parents before children.
  local format = "--format=%H%x00%an%x00%ae%x00%ad%x00%T%x00%P%x00%B%x1e"
  local function commits(range, done)
    local args = { "log", "--date=raw", format, "--reverse", "--topo-order" }
    vim.list_extend(args, range)
    vim.list_extend(args, { "--" })
    runner.run(args, { cwd = cwd }, function(res)
      if res.code ~= 0 then
        return cb(res)
      end
      local out = {}
      for _, rec in ipairs(vim.split(res.stdout, "\30", { plain = true })) do
        rec = rec:gsub("^[\r\n]+", "")
        if rec ~= "" then
          local f = vim.split(rec, "\0", { plain = true })
          out[#out + 1] = {
            hash = f[1],
            env = { GIT_AUTHOR_NAME = f[2], GIT_AUTHOR_EMAIL = f[3], GIT_AUTHOR_DATE = f[4] },
            tree = f[5],
            parents = vim.split(f[6], " ", { trimempty = true }),
            msg = table.concat(f, "\0", 7),
          }
        end
      end
      done(out)
    end)
  end
  commits({ "-1", hash }, function(target)
    commits({ "--ancestry-path", hash .. "..HEAD" }, function(above)
      target[1].msg = msg
      local todo = vim.list_extend(target, above)
      local new = {} -- old hash -> recreated hash
      local function step(i)
        local c = todo[i]
        if not c then
          return runner.mutate({ "reset", "--soft", "--quiet", new[todo[#todo].hash] }, { cwd = cwd }, cb)
        end
        local args = { "commit-tree", c.tree }
        for _, parent in ipairs(c.parents) do
          vim.list_extend(args, { "-p", new[parent] or parent })
        end
        vim.list_extend(args, { "-F", "-" })
        runner.mutate(args, { cwd = cwd, stdin = c.msg, env = c.env }, function(res)
          if res.code ~= 0 then
            return cb(res)
          end
          new[c.hash] = vim.trim(res.stdout)
          step(i + 1)
        end)
      end
      step(1)
    end)
  end)
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

M.descriptions = {
  stage = "Stage",
  unstage = "Unstage",
  discard = "Discard",
  toggle_diff = "Toggle diff",
  open = "Open",
  stash_pop = "Pop stash",
  stash_apply = "Apply stash",
  stash_drop = "Drop stash",
  commit = "Commit / amend",
  revert = "Revert commit",
  reword = "Reword unpushed commit",
  fetch = "Fetch",
  commit_submit = "Commit",
  commit_abort = "Cancel",
  close = "Close",
  help = "Help",
}

-- Actions listed in the help, in this order (`close` is left out: it is obvious).
M.order = {
  "stage",
  "unstage",
  "discard",
  "toggle_diff",
  "commit",
  "open",
  "stash_pop",
  "stash_apply",
  "stash_drop",
  "revert",
  "reword",
  "fetch",
  "commit_submit",
  "commit_abort",
  "help",
}

-- Actions listed in the help per box (see `GitRendered.regions`), followed by `help`.
M.contexts = {
  branches = { "fetch" },
  tags = {},
  stashes = { "stash_pop", "stash_apply", "stash_drop", "open" },
  files = { "stage", "unstage", "discard", "toggle_diff", "commit", "open" },
  graph = { "open", "revert", "reword" },
  commit = {},
  compose = { "commit_submit", "commit_abort" },
}

-- Descriptions that read better than `M.descriptions` in a given box.
M.context_descriptions = {
  stashes = { open = "Show stash" },
  files = { open = "Open file" },
  graph = { open = "Toggle details (visual: combined)" },
  compose = { commit_submit = "Commit (or :w)" },
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
    actions = vim.list_extend(vim.list_extend({}, M.contexts[box]), { "help" })
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
      { "n", "x" },
      function()
        M.open_items(view, target_items(view))
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
    reword = {
      "n",
      function()
        M.reword(view)
      end,
    },
    fetch = {
      "n",
      function()
        view:fetch()
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
