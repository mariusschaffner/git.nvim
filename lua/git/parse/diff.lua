local M = {}

---@class GitDiffRow
---@field kind "hunk"|"add"|"del"|"ctx"|"note"
---@field idx integer Index of the line in the raw diff
---@field text string Without the leading +/-/space (hunks: empty)
---@field old integer? Line number in the old file (ctx, del)
---@field new integer? Line number in the new file (ctx, add; hunks: the first line, as `old` is for the old file)
---@field func string? Hunks: the function context git shows after the @@
---@field change { [1]: integer, [2]: integer }? add/del paired by the word diff: byte range of the changed part

---@class GitDiffRows
---@field rows GitDiffRow[]
---@field width integer Digits of the largest line number

-- File header lines: the file is shown already, so they are left out.
local HIDDEN = { "^diff ", "^index ", "^%-%-%- ", "^%+%+%+ " }

-- Pairs whose changed part covers more of the longer line than this are not highlighted: a line that was rewritten
-- would light up almost entirely, which tells nothing.
local MAX_CHANGE = 0.7

--- Byte offset of the start of the UTF-8 character containing byte `i` of `s`.
local function char_start(s, i)
  while i > 1 and bit.band(s:byte(i) or 0, 0xC0) == 0x80 do
    i = i - 1
  end
  return i
end

--- The part of `a` and of `b` between their common prefix and suffix, as byte ranges; nil when the lines are equal.
---@param a string
---@param b string
---@return { [1]: integer, [2]: integer }?, { [1]: integer, [2]: integer }?
function M.changed(a, b)
  if a == b then
    return nil
  end
  local p = 0
  local max = math.min(#a, #b)
  while p < max and a:byte(p + 1) == b:byte(p + 1) do
    p = p + 1
  end
  -- Do not split a character: back up to where it starts.
  p = char_start(a, p + 1) - 1
  local s = 0
  while s < max - p and a:byte(#a - s) == b:byte(#b - s) do
    s = s + 1
  end
  -- The suffix must start on a character boundary too.
  while s > 0 and bit.band(a:byte(#a - s + 1), 0xC0) == 0x80 do
    s = s - 1
  end
  return { p + 1, #a - s }, { p + 1, #b - s }
end

--- Give paired removed / added lines their changed byte ranges (a run of removed lines followed by a run of added
--- ones is paired line by line).
---@param dels GitDiffRow[]
---@param adds GitDiffRow[]
local function pair(dels, adds)
  for i = 1, math.min(#dels, #adds) do
    local d, a = dels[i], adds[i]
    local cd, ca = M.changed(d.text, a.text)
    if cd then
      local longest = math.max(#d.text, #a.text)
      local span = math.max(cd[2] - cd[1] + 1, ca[2] - ca[1] + 1)
      if longest > 0 and span / longest <= MAX_CHANGE then
        d.change = cd[2] >= cd[1] and cd or nil
        a.change = ca[2] >= ca[1] and ca or nil
      end
    end
  end
end

--- Rows to show for a `git diff` of one file: file headers left out, line numbers counted per hunk, and the changed
--- part of modified lines found.
---@param lines string[]
---@return GitDiffRows
function M.rows(lines)
  local rows = {}
  local old, new, top = 0, 0, 0
  local in_hunk = false
  local dels, adds = {}, {}
  local function flush()
    pair(dels, adds)
    dels, adds = {}, {}
  end
  for idx, line in ipairs(lines) do
    local c = line:sub(1, 1)
    local hidden = line == ""
    if not in_hunk then
      for _, pat in ipairs(HIDDEN) do
        hidden = hidden or line:match(pat) ~= nil
      end
    end
    local a, b, func = line:match("^@@+ %-(%d+)[,%d]* %+(%d+)[,%d]* @@+ ?(.*)$")
    if a then
      flush()
      in_hunk = true
      old, new = tonumber(a), tonumber(b)
      rows[#rows + 1] = { kind = "hunk", idx = idx, text = "", old = old, new = new, func = func ~= "" and func or nil }
    elseif line:match("^diff ") then
      -- The next file's header (a combined diff of several files).
      flush()
      in_hunk = false
    elseif hidden then
      -- skip
    elseif in_hunk and c == "-" then
      if #adds > 0 then
        flush()
      end
      local row = { kind = "del", idx = idx, text = line:sub(2), old = old }
      old = old + 1
      rows[#rows + 1] = row
      dels[#dels + 1] = row
    elseif in_hunk and c == "+" then
      local row = { kind = "add", idx = idx, text = line:sub(2), new = new }
      new = new + 1
      rows[#rows + 1] = row
      adds[#adds + 1] = row
    elseif in_hunk and c == " " then
      flush()
      rows[#rows + 1] = { kind = "ctx", idx = idx, text = line:sub(2), old = old, new = new }
      old, new = old + 1, new + 1
    else
      -- new file mode, rename from, Binary files … differ, \ No newline at end of file, …
      flush()
      rows[#rows + 1] = { kind = "note", idx = idx, text = line }
    end
    top = math.max(top, old, new)
  end
  flush()
  return { rows = rows, width = #tostring(math.max(top - 1, 1)) }
end

return M
