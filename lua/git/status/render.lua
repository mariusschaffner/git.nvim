local util = require("git.core.util")
local graph = require("git.status.graph")

local M = {}

---@alias GitSeg { [1]: string, [2]: string? } text, highlight group

---@class GitItem
---@field kind "section"|"file"|"diff"|"stash"|"commit"
---@field section GitSection?
---@field file GitFile?
---@field stash GitStash?
---@field hash string?
---@field diff_line integer? Index into the expanded diff lines (diff items only)
---@field refs boolean? Commit items: the ref names line above the commit (the cursor prefers the commit line)

---@class GitRendered
---@field lines string[]
---@field marks { row: integer, col: integer, end_col: integer, hl: string, priority: integer? }[] 0-based row, byte columns
---@field items table<integer, GitItem> 1-based line -> item
---@field boxes table<string, GitBox> Scrollable boxes by name ("files", "graph", "commit"); only with a fixed height,
--- except "compose", which is always present while composing
---@field scroll table<string, integer> Final scroll offsets of the scrollable boxes
---@field regions { name: string, first: integer, last: integer }[] 1-based line range of every box, borders included

---@class GitBox
---@field top integer 1-based line of the first visible content row
---@field rows integer Number of visible content rows
---@field offset integer Content rows scrolled out above
---@field total integer Number of content rows

---@class GitCommitDetails
---@field hash string The (newest) commit
---@field hashes string[]? All commits shown combined, newest first
---@field lines string[]

---@class GitRenderOpts
---@field width integer
---@field expanded table<string, string[]>? diff key -> diff lines
---@field height integer? Fixed total height: the files and graph boxes split the space left by the others
---@field scroll table<string, integer>? Scroll offsets of the files/graph boxes (fixed height only)
---@field focus string? item_key to scroll into view (fixed height only)
---@field commit GitCommitDetails? Commit details to show; replaces the files box
---@field zoom ("files"|"graph")? Show only this box, over the full height (ignored while a commit or the
--- commit message editor is shown)
---@field fetching string? Spinner frame shown in the Branches box while a fetch runs
---@field compose (boolean|string)? Show an empty "Commit message" box (or one with this title) in place of the files
--- box; the UI overlays an editor

local SECTION_LABEL = {
  conflicted = "Conflicted",
  staged = "Staged changes",
  unstaged = "Unstaged changes",
  untracked = "Untracked",
}

local OPERATION = {
  merge = "Merge",
  rebase = "Rebase",
  ["cherry-pick"] = "Cherry-pick",
  revert = "Revert",
  bisect = "Bisect",
}

local DIM = "GitStatusDim"

-- Content rows of the commit message box when the view has no fixed height.
M.COMPOSE_ROWS = 6

--- Stable identity of an item, used to keep the cursor on the same entry across refreshes.
---@param item GitItem?
---@return string?
function M.item_key(item)
  if not item then
    return nil
  end
  if item.kind == "file" then
    return "file:" .. item.file.section .. ":" .. item.file.path
  elseif item.kind == "diff" then
    return "diff:" .. item.file.section .. ":" .. item.file.path .. ":" .. item.diff_line
  elseif item.kind == "section" then
    return "section:" .. item.section
  elseif item.kind == "stash" then
    return "stash:" .. item.stash.ref
  elseif item.kind == "commit" then
    return "commit:" .. item.hash
  end
end

---@param file GitFile
---@return string
function M.diff_key(file)
  return file.section .. ":" .. file.path
end

--- " | k1 label1 · k2 label2" from the configured keymaps, or nil when hints are off / no key is mapped.
---@param pairs_ { [1]: string, [2]: string }[] {action, label}
---@param extra string? A git command hint appended at the end
---@return GitSeg?
local function hint(pairs_, extra)
  local config = require("git.config")
  if not config.options.status.hints then
    return nil
  end
  local parts = {}
  for _, p in ipairs(pairs_) do
    local key = config.key(p[1])
    if key then
      parts[#parts + 1] = key .. " " .. p[2]
    end
  end
  if extra then
    parts[#parts + 1] = extra
  end
  if #parts == 0 then
    return nil
  end
  return { " | " .. table.concat(parts, " · "), DIM }
end

---@param s GitSeg?
local function add(segs, s)
  if s then
    segs[#segs + 1] = s
  end
  return segs
end

---@class GitBuilder
local Builder = {}
Builder.__index = Builder

function Builder.new(width)
  return setmetatable({ width = math.max(width, 20), lines = {}, marks = {}, items = {} }, Builder)
end

function Builder:_push(text, marks, item)
  local row = #self.lines
  self.lines[row + 1] = text
  for _, m in ipairs(marks) do
    self.marks[#self.marks + 1] = { row = row, col = m[1], end_col = m[2], hl = m[3], priority = m.priority }
  end
  if item then
    self.items[row + 1] = item
  end
  return row + 1
end

function Builder:top(title)
  local w = self.width
  local prefix = "╭── "
  local t = util.truncate(title, math.max(w - 7, 1))
  local used = util.width(prefix) + util.width(t) + 1
  local fill = math.max(w - used - 1, 0)
  local text = prefix .. t .. " " .. string.rep("─", fill) .. "╮"
  local p, tl = #prefix, #t
  self:_push(text, {
    { 0, p, "GitStatusBorder" },
    { p, p + tl, "GitStatusBoxTitle" },
    { p + tl, #text, "GitStatusBorder" },
  })
end

---@param label string? Shown at the right end of the border (e.g. a scroll position)
function Builder:bottom(label)
  label = label and util.truncate(label, math.max(self.width - 4, 0)) or ""
  local fill = string.rep("─", math.max(self.width - 3 - util.width(label), 0))
  local text = "╰" .. fill .. label .. "─╯"
  local a, b = #"╰" + #fill, #"╰" + #fill + #label
  self:_push(text, { { 0, a, "GitStatusBorder" }, { a, b, DIM }, { b, #text, "GitStatusBorder" } })
end

---@param segs GitSeg[]
---@param item GitItem?
---@param line_hl string? Background for the whole content area, below the segment highlights
function Builder:line(segs, item, line_hl)
  local content_w = math.max(self.width - 4, 1)
  local left, right = "│ ", " │"
  local parts, marks = { left }, { { 0, #left, "GitStatusBorder" } }
  local col, used = #left, 0
  for _, seg in ipairs(segs) do
    local text = util.sanitize(seg[1] or "")
    if text ~= "" then
      local remaining = content_w - used
      if remaining <= 0 then
        break
      end
      local t, w = util.truncate(text, remaining)
      parts[#parts + 1] = t
      if seg[2] then
        marks[#marks + 1] = { col, col + #t, seg[2] }
      end
      col = col + #t
      used = used + w
    end
  end
  if used < content_w then
    local pad = string.rep(" ", content_w - used)
    parts[#parts + 1] = pad
    col = col + #pad
  end
  parts[#parts + 1] = right
  marks[#marks + 1] = { col, col + #right, "GitStatusBorder" }
  if line_hl then
    marks[#marks + 1] = { #left, col, line_hl, priority = 100 }
  end
  return self:_push(table.concat(parts), marks, item)
end

---@param title string
---@param content { segs: GitSeg[], item: GitItem?, line_hl: string? }[]
---@param rows integer? Fixed number of content rows; content is windowed by `offset` and padded
---@param offset integer?
---@param label string? Bottom border label when the content is not scrolled
---@return integer? top 1-based line of the first content row
function Builder:box(title, content, rows, offset, label)
  if #content == 0 and not rows then
    return
  end
  self:top(title)
  local top = #self.lines + 1
  rows = rows or #content
  offset = offset or 0
  for i = offset + 1, offset + rows do
    local c = content[i] or { segs = {} }
    self:line(c.segs, c.item, c.line_hl)
  end
  if #content > rows then
    label = (" %d-%d/%d "):format(offset + 1, math.min(offset + rows, #content), #content)
  end
  self:bottom(label)
  return top
end

---@param state GitState
---@param state GitState
---@param opts GitRenderOpts
local function branches(state, opts)
  local config = require("git.config").options.status
  local ic = require("git.config").icons()
  local out = {}
  local function row(segs, item)
    out[#out + 1] = { segs = segs, item = item }
  end
  local b = state.branch
  local remote_label = { " " .. ic.remote .. "Remote: ", "GitStatusLabel" }
  local remote
  if b.upstream and b.gone then
    remote = { remote_label, { b.upstream, "GitStatusUpstream" }, { " (gone)", "GitStatusWarning" } }
  elseif not b.upstream then
    remote = { remote_label }
    if b.detached then
      add(remote, { "detached HEAD", DIM })
    elseif #state.remotes == 0 then
      add(remote, { "no remote", DIM })
    else
      add(remote, { "no upstream", DIM })
    end
  else
    remote = {
      remote_label,
      { "[" .. ic.behind .. b.behind .. "]", b.behind > 0 and "GitStatusBehind" or DIM },
      { " | " .. b.upstream, "GitStatusUpstream" },
    }
  end
  if opts.fetching then
    add(remote, { "  " .. opts.fetching .. " fetching…", DIM })
  end
  row(remote)

  local name
  if b.detached then
    name = "(detached)" .. (b.oid and (" " .. b.oid:sub(1, 8)) or "")
  elseif b.unborn then
    name = b.head .. " (no commits yet)"
  else
    name = b.head
  end
  local head = {
    { " " .. ic.head .. "HEAD:   ", "GitStatusLabel" },
    { "[" .. ic.ahead .. b.ahead .. "]", b.ahead > 0 and "GitStatusAhead" or DIM },
    { " | " .. name, "GitStatusBranch" },
  }
  if not b.detached and vim.tbl_contains(config.protected_branches, b.head) then
    add(head, { ic.protected, "GitStatusProtected" })
  end
  -- The box is always just the Remote and HEAD rows, so an operation in progress goes on the HEAD row.
  local op = state.operation and OPERATION[state.operation]
  if op then
    add(head, { "  " .. ic.warning .. op .. " in progress", "GitStatusWarning" })
  end
  row(head)
  return out
end

---@param state GitState
local function tags(state)
  local ic = require("git.config").icons()
  local t = state.tags
  local out = {}
  if t.at_head then
    out[1] = { segs = { { " " .. ic.tag .. "On tag:      ", "GitStatusTagLabel" }, { t.at_head, "GitStatusTag" } } }
  elseif t.nearest then
    out[1] = { segs = { { " " .. ic.tag .. "Nearest tag: ", "GitStatusTagLabel" }, { t.nearest, "GitStatusTagNearest" } } }
  end
  if #out > 0 and #t.unpushed > 0 then
    out[2] = {
      segs = {
        { " " .. ic.unpushed_tag .. "Unpushed:    ", "GitStatusTagLabel" },
        { table.concat(t.unpushed, ", "), "GitStatusTagUnpushed" },
      },
    }
  end
  return out
end

---@param state GitState
local function stashes(state)
  local config = require("git.config").options.status
  local ic = require("git.config").icons()
  local out = {}
  if #state.stashes == 0 then
    return out
  end
  out[1] = {
    segs = add({
      { " " .. ic.stash .. "Stashes: ", "GitStatusLabel" },
      { "[" .. #state.stashes .. "]", "GitStatusStash" },
    }, hint({ { "stash_pop", "pop" }, { "stash_apply", "apply" }, { "stash_drop", "drop" }, { "open", "show" } })),
  }
  for i, s in ipairs(state.stashes) do
    if i > config.stash.max then
      out[#out + 1] = { segs = { { ("   … %d more"):format(#state.stashes - config.stash.max), DIM } } }
      break
    end
    out[#out + 1] =
      { segs = { { "   " .. s.ref .. " " .. s.subject, "GitStatusStash" } }, item = { kind = "stash", stash = s } }
  end
  return out
end

local function diffstat(f, hl)
  if f.binary then
    return { { " (binary)", hl } }
  end
  if not f.added then
    return {}
  end
  return {
    { " (", hl },
    { "+" .. f.added, "GitStatusAdded" },
    { " | ", hl },
    { "-" .. f.deleted, "GitStatusDeleted" },
    { ")", hl },
  }
end

local function diff_line_hl(line)
  local c = line:sub(1, 1)
  if line:match("^diff ") or line:match("^index ") or line:match("^%+%+%+ ") or line:match("^%-%-%- ") then
    return "GitStatusDiffHeader"
  elseif line:match("^@@") then
    return "GitStatusDiffHunk"
  elseif c == "+" then
    return "GitStatusDiffAdd"
  elseif c == "-" then
    return "GitStatusDiffDelete"
  end
  return "GitStatusDiffContext"
end

---@param state GitState
---@param opts GitRenderOpts
local function files(state, opts)
  local config = require("git.config").options
  local ic = require("git.config").icons()
  local out = {}
  local fs = state.files
  local total = #fs.conflicted + #fs.staged + #fs.unstaged + #fs.untracked
  if total == 0 then
    out[1] = { segs = { { " " .. ic.clean .. "Working tree clean", DIM } } }
    return out
  end

  local section_hints = {
    conflicted = hint({ { "stage", "mark resolved" }, { "toggle_diff", "diff" } }, "(git mergetool)"),
    staged = hint({ { "unstage", "unstage" }, { "toggle_diff", "diff" }, { "commit", "commit" } }),
    unstaged = hint({ { "stage", "stage" }, { "discard", "discard" }, { "toggle_diff", "diff" } }),
    untracked = hint({ { "stage", "stage" }, { "discard", "delete" }, { "toggle_diff", "diff" } }),
  }
  local item_hl = {
    conflicted = "GitStatusConflicted",
    staged = "GitStatusStaged",
    unstaged = "GitStatusUnstaged",
    untracked = "GitStatusUntracked",
  }
  local header_hl = {
    conflicted = "GitStatusSectionConflicted",
    staged = "GitStatusSectionStaged",
    unstaged = "GitStatusSectionUnstaged",
    untracked = "GitStatusSectionUntracked",
  }

  for _, section in ipairs({ "conflicted", "staged", "unstaged", "untracked" }) do
    local list = fs[section]
    if #list > 0 then
      if #out > 0 then
        out[#out + 1] = { segs = {} }
      end
      out[#out + 1] = {
        segs = add(
          { { " " .. ic[section] .. SECTION_LABEL[section] .. " (" .. #list .. ")", header_hl[section] } },
          section_hints[section]
        ),
        item = { kind = "section", section = section },
      }
      local hl = item_hl[section]
      for _, f in ipairs(list) do
        local segs
        if section == "conflicted" then
          segs = { { "   " .. f.code .. " ", hl }, { f.path, "GitStatusFile" } }
        elseif section == "untracked" then
          segs = { { "  " .. ic.bullet .. ic.new_file, hl }, { f.path, "GitStatusFile" }, { " (new)", hl } }
        else
          local icon = ic.status[f.code] or (f.code .. (config.icons and "  " or " "))
          segs = {
            { "  " .. ic.bullet .. icon, hl },
            { f.orig and (f.orig .. " → " .. f.path) or f.path, "GitStatusFile" },
          }
          vim.list_extend(segs, diffstat(f, hl))
        end
        if f.submodule then
          add(segs, { " (submodule)", DIM })
        end
        local item = { kind = "file", section = section, file = f }
        out[#out + 1] = { segs = segs, item = item }

        local diff = opts.expanded and opts.expanded[M.diff_key(f)]
        if diff then
          local max = config.status.diff.max_lines
          local function ditem(i)
            return { kind = "diff", section = section, file = f, diff_line = i }
          end
          for i, dl in ipairs(diff) do
            if i > max then
              out[#out + 1] = { segs = { { ("      … %d more lines"):format(#diff - max), DIM } }, item = ditem(i) }
              break
            end
            out[#out + 1] = { segs = { { "      " }, { dl, diff_line_hl(dl) } }, item = ditem(i) }
          end
          if #diff == 0 then
            out[#out + 1] = { segs = { { "      (no diff)", DIM } }, item = ditem(0) }
          end
        end
      end
    end
  end
  return out
end

---@param state GitState
local function commit_graph(state)
  local out = {}
  if #state.graph == 0 then
    if state.branch.unborn then
      out[1] = { segs = { { " No commits yet", DIM } } }
    end
    return out
  end
  local rows = graph.layout(state.graph, { unpushed = state.unpushed, incoming = state.incoming })
  -- All text starts in one column: lane glyphs are padded to the widest row, followed by a marker column
  -- (" !" for unpushed / incoming commits) when any commit has a marker.
  local lanes_width, markers = 0, false
  for _, r in ipairs(rows) do
    local w = 0
    for _, seg in ipairs(r.segments) do
      w = w + util.width(seg[1])
    end
    lanes_width = math.max(lanes_width, w)
    if r.commit and (state.unpushed[r.commit.hash] or state.incoming[r.commit.hash]) then
      markers = true
    end
  end
  ---@param lane_segs GitSeg[]
  ---@param marker GitSeg?
  local function prefix(lane_segs, marker)
    local segs = vim.list_extend({ { " " } }, lane_segs)
    local w = 0
    for _, seg in ipairs(lane_segs) do
      w = w + util.width(seg[1])
    end
    if w < lanes_width then
      segs[#segs + 1] = { string.rep(" ", lanes_width - w) }
    end
    if markers then
      segs[#segs + 1] = marker or { "  " }
    end
    return segs
  end

  for _, r in ipairs(rows) do
    local c = r.commit
    if not c then
      out[#out + 1] = { segs = prefix(r.segments) }
    else
      local hash_hl, line_hl, marker = "GitStatusHash", nil, nil
      if state.unpushed[c.hash] then
        hash_hl, marker = "GitStatusHashUnpushed", { " !", "GitStatusGraphUnpushed" }
      elseif state.incoming[c.hash] then
        hash_hl, line_hl = "GitStatusHashIncoming", "GitStatusIncomingLine"
        marker = { " !", "GitStatusGraphIncoming" }
      end
      local item = { kind = "commit", hash = c.hash }
      if c.deco ~= "" then
        -- Ref names on their own line above the commit, in the text column.
        local deco = prefix(graph.above(r))
        add(deco, { " " .. c.deco, "GitStatusDeco" })
        out[#out + 1] = { segs = deco, item = vim.tbl_extend("force", item, { refs = true }), line_hl = line_hl }
      end
      local segs = prefix(r.segments, marker)
      add(segs, { " " .. c.abbrev, hash_hl })
      add(segs, { " " .. c.subject, "GitStatusSubject" })
      out[#out + 1] = { segs = segs, item = item, line_hl = line_hl }
    end
  end
  return out
end

---@param commit { hash: string, lines: string[] }
local function commit_details(commit)
  local out = {}
  for _, l in ipairs(commit.lines) do
    local hl
    if l:match("^commit ") then
      hl = "GitStatusHash"
    elseif l:match("^%w+:") then
      hl = "GitStatusLabel"
    else
      hl = diff_line_hl(l)
    end
    out[#out + 1] = { segs = { { " " }, { l, hl } } }
  end
  return out
end

--- " k1 commit · k2 cancel " for the commit message box's bottom border.
---@return string?
local function compose_label()
  local config = require("git.config")
  if not config.options.status.hints then
    return nil
  end
  local parts = {}
  for _, p in ipairs({ { "commit_submit", "commit" }, { "commit_abort", "cancel" } }) do
    local key = config.key(p[1])
    if key then
      parts[#parts + 1] = key .. " " .. p[2]
    end
  end
  return #parts > 0 and (" " .. table.concat(parts, " · ") .. " ") or nil
end

---@param commit GitCommitDetails
local function commit_title(commit)
  local hashes = commit.hashes or { commit.hash }
  if #hashes == 1 then
    return "Commit " .. commit.hash:sub(1, 8)
  end
  return ("%d commits %s..%s"):format(#hashes, hashes[#hashes]:sub(1, 8), hashes[1]:sub(1, 8))
end

--- Render the full status view.
---@param state GitState
---@param opts GitRenderOpts
---@return GitRendered
function M.render(state, opts)
  local b = Builder.new(opts.width)
  -- Commit details show only the graph and the commit; open diffs show only the files.
  -- Otherwise the fixed boxes come first and files and graph share the rest.
  -- While composing a commit message, its box takes the place of the files box. A zoomed box is shown alone.
  local commit = not opts.compose and opts.commit or nil
  local zoom = not commit and not opts.compose and opts.zoom or nil
  local overview = not commit and not zoom and not next(opts.expanded or {})
  local regions = {}
  --- b:box, recording the box's line range under `name`.
  local function box(name, ...)
    local first = #b.lines + 1
    local top = b:box(...)
    if #b.lines >= first then
      regions[#regions + 1] = { name = name, first = first, last = #b.lines }
    end
    return top
  end
  if overview then
    box("branches", "Branches", branches(state, opts))
    box("tags", "Tags", tags(state))
    box("stashes", "Stashes", stashes(state))
  end

  -- The scrollable boxes, as { name, title, rows, height } (height incl. the 2 border lines).
  local avail = (opts.height or 0) - #b.lines
  local layout
  if commit then
    local g = math.floor(avail * 0.3)
    layout = {
      { "graph", "Graph", commit_graph(state), g },
      { "commit", commit_title(commit), commit_details(commit), avail - g },
    }
  elseif zoom == "graph" then
    layout = { { "graph", "Graph", commit_graph(state), avail } }
  else
    local first = { "files", "Files", files(state, opts) }
    if opts.compose then
      local n = #state.files.staged
      local title = type(opts.compose) == "string" and opts.compose
        or ("Commit message (%d staged file%s)"):format(n, n == 1 and "" or "s")
      first = { "compose", title, {} }
    end
    if not overview then
      first[4] = avail
      layout = { first }
    else
      first[4] = math.floor(avail / 2)
      layout = { first, { "graph", "Graph", commit_graph(state), avail - first[4] } }
    end
  end

  local boxes, scroll = {}, {}
  if not opts.height then
    for _, spec in ipairs(layout) do
      if spec[1] == "compose" then
        local top = box("compose", spec[2], spec[3], M.COMPOSE_ROWS, 0, compose_label())
        boxes.compose = { top = top, rows = M.COMPOSE_ROWS, offset = 0, total = 0 }
      else
        box(spec[1], spec[2], spec[3])
      end
    end
    return {
      lines = b.lines,
      marks = b.marks,
      items = b.items,
      boxes = boxes,
      scroll = scroll,
      regions = regions,
    }
  end

  for _, spec in ipairs(layout) do
    local name, content = spec[1], spec[3]
    local rows = math.max(spec[4] - 2, 1)
    local offset = (opts.scroll or {})[name] or 0
    if opts.focus then
      for i, c in ipairs(content) do
        if M.item_key(c.item) == opts.focus and not c.item.refs then
          offset = math.min(math.max(offset, i - rows), i - 1)
          break
        end
      end
    end
    offset = math.max(math.min(offset, #content - rows), 0)
    local top = box(name, spec[2], content, rows, offset, name == "compose" and compose_label() or nil)
    boxes[name] = { top = top, rows = rows, offset = offset, total = #content }
    scroll[name] = offset
  end
  return {
    lines = b.lines,
    marks = b.marks,
    items = b.items,
    boxes = boxes,
    scroll = scroll,
    regions = regions,
  }
end

return M
