local util = require("git.util")
local graph = require("git.graph")

local M = {}

---@alias GitSeg { [1]: string, [2]: string? } text, highlight group

---@class GitItem
---@field kind "section"|"file"|"diff"|"stash"|"commit"
---@field section GitSection?
---@field file GitFile?
---@field stash GitStash?
---@field hash string?
---@field diff_line integer? Index into the expanded diff lines (diff items only)

---@class GitRendered
---@field lines string[]
---@field marks { row: integer, col: integer, end_col: integer, hl: string, priority: integer? }[] 0-based row, byte columns
---@field items table<integer, GitItem> 1-based line -> item
---@field sections integer[] 1-based lines of box titles and file section headers
---@field boxes table<string, GitBox> Scrollable boxes by name ("files", "graph"); only with a fixed height
---@field scroll table<string, integer> Final scroll offsets of the scrollable boxes

---@class GitBox
---@field top integer 1-based line of the first visible content row
---@field rows integer Number of visible content rows
---@field offset integer Content rows scrolled out above
---@field total integer Number of content rows

---@class GitRenderOpts
---@field width integer
---@field expanded table<string, string[]>? diff key -> diff lines
---@field height integer? Fixed total height: the files and graph boxes split the space left by the others
---@field scroll table<string, integer>? Scroll offsets of the files/graph boxes (fixed height only)
---@field focus string? item_key to scroll into view (fixed height only)

local SECTION_LABEL = {
  conflicted = "Conflicted",
  staged = "Staged changes",
  unstaged = "Unstaged changes",
  untracked = "Untracked",
}

local OPERATION = {
  merge = { "Merge", "(git merge --continue | --abort)" },
  rebase = { "Rebase", "(git rebase --continue | --skip | --abort)" },
  ["cherry-pick"] = { "Cherry-pick", "(git cherry-pick --continue | --abort)" },
  revert = { "Revert", "(git revert --continue | --abort)" },
  bisect = { "Bisect", "(git bisect good | bad | reset)" },
}

local DIM = "GitStatusDim"

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
  if not config.options.hints then
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
  return setmetatable({ width = math.max(width, 20), lines = {}, marks = {}, items = {}, sections = {} }, Builder)
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
  local prefix = "┌── "
  local t = util.truncate(title, math.max(w - 7, 1))
  local used = util.width(prefix) + util.width(t) + 1
  local fill = math.max(w - used - 1, 0)
  local text = prefix .. t .. " " .. string.rep("─", fill) .. "┐"
  local p, tl = #prefix, #t
  local lnum = self:_push(text, {
    { 0, p, "GitStatusBorder" },
    { p, p + tl, "GitStatusBoxTitle" },
    { p + tl, #text, "GitStatusBorder" },
  })
  self.sections[#self.sections + 1] = lnum
end

---@param label string? Shown at the right end of the border (e.g. a scroll position)
function Builder:bottom(label)
  label = label and util.truncate(label, math.max(self.width - 4, 0)) or ""
  local fill = string.rep("─", math.max(self.width - 3 - util.width(label), 0))
  local text = "└" .. fill .. label .. "─┘"
  local a, b = #"└" + #fill, #"└" + #fill + #label
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
---@param content { segs: GitSeg[], item: GitItem?, section: boolean?, line_hl: string? }[]
---@param rows integer? Fixed number of content rows; content is windowed by `offset` and padded
---@param offset integer?
---@return integer? top 1-based line of the first content row
function Builder:box(title, content, rows, offset)
  if #content == 0 and not rows then
    return
  end
  self:top(title)
  local top = #self.lines + 1
  rows = rows or #content
  offset = offset or 0
  for i = offset + 1, offset + rows do
    local c = content[i] or { segs = {} }
    local lnum = self:line(c.segs, c.item, c.line_hl)
    if c.section then
      self.sections[#self.sections + 1] = lnum
    end
  end
  local label
  if #content > rows then
    label = (" %d-%d/%d "):format(offset + 1, math.min(offset + rows, #content), #content)
  end
  self:bottom(label)
  return top
end

---@param state GitState
local function branches(state)
  local config = require("git.config").options
  local ic = require("git.config").icons()
  local out = {}
  local function row(segs, item)
    out[#out + 1] = { segs = segs, item = item }
  end
  local b = state.branch
  local remote_label = { " " .. ic.remote .. "Remote: ", "GitStatusLabel" }
  if b.upstream and b.gone then
    row(add({
      remote_label,
      { b.upstream, "GitStatusUpstream" },
      { " (gone)", "GitStatusWarning" },
    }, hint({}, "(git branch --unset-upstream)")))
  elseif not b.upstream then
    local segs = { remote_label }
    if b.detached then
      add(segs, { "detached HEAD", DIM })
    elseif #state.remotes == 0 then
      add(segs, { "no remote", DIM })
    else
      add(segs, { "no upstream", DIM })
      local remote = state.remote or (vim.tbl_contains(state.remotes, "origin") and "origin") or state.remotes[1]
      add(segs, hint({}, ("(git push -u %s %s)"):format(remote, b.head)))
    end
    row(segs)
  elseif b.behind > 0 then
    row(add({
      remote_label,
      { "[" .. ic.behind .. b.behind .. "]", "GitStatusBehind" },
      { " | " .. b.upstream, "GitStatusUpstream" },
    }, hint({}, "(git pull)")))
  else
    row(add({
      remote_label,
      { "[" .. ic.behind .. "0]", DIM },
      { " | " .. b.upstream, "GitStatusUpstream" },
    }, hint({}, "(git fetch)")))
  end

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
    add(head, { "  " .. ic.warning .. op[1] .. " in progress", "GitStatusWarning" })
    add(head, hint({}, op[2]))
  elseif b.ahead > 0 then
    add(head, hint({}, ("(git push | git reset --soft HEAD~%d)"):format(b.ahead)))
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
  local config = require("git.config").options
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
    staged = hint({ { "unstage", "unstage" }, { "toggle_diff", "diff" } }, "(git commit)"),
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
        section = true,
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
          local max = config.diff.max_lines
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
  for _, r in ipairs(graph.layout(state.graph)) do
    local segs = vim.list_extend({ { " " } }, r.segments)
    local item, line_hl
    local c = r.commit
    if c then
      local hash_hl = "GitStatusHash"
      if state.unpushed[c.hash] then
        hash_hl, line_hl = "GitStatusHashUnpushed", "GitStatusUnpushedLine"
      elseif state.incoming[c.hash] then
        hash_hl, line_hl = "GitStatusHashIncoming", "GitStatusIncomingLine"
      end
      add(segs, { " " .. c.abbrev, hash_hl })
      if c.deco ~= "" then
        add(segs, { " (" .. c.deco .. ")", "GitStatusDeco" })
      end
      add(segs, { " " .. c.subject, "GitStatusSubject" })
      item = { kind = "commit", hash = c.hash }
    end
    out[#out + 1] = { segs = segs, item = item, line_hl = line_hl }
  end
  return out
end

--- Render the full status view.
---@param state GitState
---@param opts GitRenderOpts
---@return GitRendered
function M.render(state, opts)
  local b = Builder.new(opts.width)
  local file_rows, graph_rows = files(state, opts), commit_graph(state)
  b:box("Branches", branches(state))
  b:box("Tags", tags(state))
  b:box("Stashes", stashes(state))
  if not opts.height then
    b:box("Files", file_rows)
    b:box("Graph", graph_rows)
    return { lines = b.lines, marks = b.marks, items = b.items, sections = b.sections, boxes = {}, scroll = {} }
  end

  -- Fixed height: files and graph split what is left after the boxes above (each box has 2 border lines).
  local avail = opts.height - #b.lines
  local heights = { files = math.floor(avail / 2) }
  heights.graph = avail - heights.files
  local boxes, scroll = {}, {}
  for _, spec in ipairs({ { "files", "Files", file_rows }, { "graph", "Graph", graph_rows } }) do
    local name, content = spec[1], spec[3]
    local rows = math.max(heights[name] - 2, 1)
    local offset = (opts.scroll or {})[name] or 0
    if opts.focus then
      for i, c in ipairs(content) do
        if M.item_key(c.item) == opts.focus then
          offset = math.min(math.max(offset, i - rows), i - 1)
          break
        end
      end
    end
    offset = math.max(math.min(offset, #content - rows), 0)
    local top = b:box(spec[2], content, rows, offset)
    boxes[name] = { top = top, rows = rows, offset = offset, total = #content }
    scroll[name] = offset
  end
  return { lines = b.lines, marks = b.marks, items = b.items, sections = b.sections, boxes = boxes, scroll = scroll }
end

return M
