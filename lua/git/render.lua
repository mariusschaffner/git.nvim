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
---@field marks { row: integer, col: integer, end_col: integer, hl: string }[] 0-based row, byte columns
---@field items table<integer, GitItem> 1-based line -> item
---@field sections integer[] 1-based lines of box titles and file section headers

---@class GitRenderOpts
---@field width integer
---@field expanded table<string, string[]>? diff key -> diff lines

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
    self.marks[#self.marks + 1] = { row = row, col = m[1], end_col = m[2], hl = m[3] }
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

function Builder:bottom()
  local text = "└" .. string.rep("─", self.width - 2) .. "┘"
  self:_push(text, { { 0, #text, "GitStatusBorder" } })
end

---@param segs GitSeg[]
---@param item GitItem?
function Builder:line(segs, item)
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
  return self:_push(table.concat(parts), marks, item)
end

---@param title string
---@param content { segs: GitSeg[], item: GitItem?, section: boolean? }[]
function Builder:box(title, content)
  if #content == 0 then
    return
  end
  self:top(title)
  for _, c in ipairs(content) do
    local lnum = self:line(c.segs, c.item)
    if c.section then
      self.sections[#self.sections + 1] = lnum
    end
  end
  self:bottom()
end

---@param state GitState
local function branches(state)
  local config = require("git.config").options
  local ic = require("git.config").icons()
  local out = {}
  local function row(segs, item)
    out[#out + 1] = { segs = segs, item = item }
  end
  local b, t = state.branch, state.tags

  if t.at_head then
    row({ { " " .. ic.tag .. "On tag:", "GitStatusTagLabel" }, { " " .. t.at_head, "GitStatusTag" } })
  elseif t.nearest then
    row({ { " " .. ic.tag .. "Nearest tag:", "GitStatusTagLabel" }, { " " .. t.nearest, "GitStatusTagNearest" } })
  end
  for _, tag in ipairs(t.unpushed) do
    row({ { " " .. ic.unpushed_tag .. "Unpushed tag:", "GitStatusTagLabel" }, { " " .. tag, "GitStatusTagUnpushed" } })
  end

  local op = state.operation and OPERATION[state.operation]
  if op then
    row(add({ { " " .. ic.warning .. op[1] .. " in progress", "GitStatusWarning" } }, hint({}, op[2])))
  end

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
    for _, c in ipairs(state.remote_commits) do
      row({ { "   " .. ic.remote_commit .. c.abbrev .. " " .. c.subject, "GitStatusRemoteCommit" } }, {
        kind = "commit",
        hash = c.hash,
      })
    end
    if b.behind > #state.remote_commits and #state.remote_commits > 0 then
      row({ { ("   … %d more"):format(b.behind - #state.remote_commits), DIM } })
    end
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
  if b.ahead > 0 then
    add(head, hint({}, ("(git push | git reset --soft HEAD~%d)"):format(b.ahead)))
  end
  row(head)
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
    local item
    local c = r.commit
    if c then
      add(segs, { " " .. c.abbrev, state.unpushed[c.hash] and "GitStatusHashUnpushed" or "GitStatusHash" })
      if c.deco ~= "" then
        add(segs, { " (" .. c.deco .. ")", "GitStatusDeco" })
      end
      add(segs, { " " .. c.subject, "GitStatusSubject" })
      item = { kind = "commit", hash = c.hash }
    end
    out[#out + 1] = { segs = segs, item = item }
  end
  return out
end

--- Render the full status view.
---@param state GitState
---@param opts GitRenderOpts
---@return GitRendered
function M.render(state, opts)
  local b = Builder.new(opts.width)
  b:box("Branches", branches(state))
  b:box("Stashes", stashes(state))
  b:box("Files", files(state, opts))
  b:box("Graph", commit_graph(state))
  return { lines = b.lines, marks = b.marks, items = b.items, sections = b.sections }
end

return M
