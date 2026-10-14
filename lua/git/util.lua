local M = {}

local uv = vim.uv or vim.loop

--- Replace characters that cannot be shown on a single buffer line.
--- Tabs become spaces, other control characters become caret notation (^M, ^J, ...).
---@param s string
---@return string
function M.sanitize(s)
  if not s:find("[%c]") then
    return s
  end
  s = s:gsub("\t", "    ")
  return (
    s:gsub("%c", function(c)
      local b = c:byte()
      return "^" .. string.char(b == 127 and 63 or b + 64)
    end)
  )
end

---@param s string
---@return integer
function M.width(s)
  return vim.fn.strdisplaywidth(s)
end

--- Truncate `s` to at most `max` display cells, ending with an ellipsis when cut.
---@param s string
---@param max integer
---@return string text, integer width
function M.truncate(s, max)
  local w = M.width(s)
  if w <= max then
    return s, w
  end
  if max <= 0 then
    return "", 0
  end
  local budget = max > 1 and max - 1 or max
  local out, used = {}, 0
  local n = vim.fn.strchars(s)
  for i = 0, n - 1 do
    local ch = vim.fn.strcharpart(s, i, 1)
    local cw = M.width(ch)
    if used + cw > budget then
      break
    end
    out[#out + 1] = ch
    used = used + cw
  end
  if max > 1 then
    out[#out + 1] = "…"
    used = used + 1
  end
  return table.concat(out), used
end

--- Split `s` on every occurrence of the single-byte separator `sep`. Keeps empty fields.
---@param s string
---@param sep string
---@return string[]
function M.split(s, sep)
  local out, start = {}, 1
  while true do
    local i = s:find(sep, start, true)
    if not i then
      out[#out + 1] = s:sub(start)
      return out
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
end

--- Split `s` on spaces into at most `n` fields; the last field keeps the remainder (paths may contain spaces).
---@param s string
---@param n integer
---@return string[]
function M.split_n(s, n)
  local out, start = {}, 1
  while #out < n - 1 do
    local i = s:find(" ", start, true)
    if not i then
      break
    end
    out[#out + 1] = s:sub(start, i - 1)
    start = i + 1
  end
  out[#out + 1] = s:sub(start)
  return out
end

--- Split git output into non-empty lines (handles CRLF).
---@param s string?
---@return string[]
function M.lines(s)
  local out = {}
  for line in (s or ""):gmatch("[^\r\n]+") do
    out[#out + 1] = line
  end
  return out
end

--- Debounce `fn` by `ms` milliseconds. Returns the wrapped function and a cancel function.
---@param ms integer
---@param fn function
---@return function call, function cancel
function M.debounce(ms, fn)
  local timer = uv.new_timer()
  local function call(...)
    if timer:is_closing() then
      return
    end
    local args = { n = select("#", ...), ... }
    timer:stop()
    timer:start(ms, 0, function()
      vim.schedule(function()
        fn(unpack(args, 1, args.n))
      end)
    end)
  end
  local function cancel()
    if not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end
  return call, cancel
end

--- Run async tasks in parallel. Each task is `function(done)`; `cb` is called once all have called `done`.
---@param tasks (fun(done: fun()))[]
---@param cb fun()
function M.all(tasks, cb)
  local pending = #tasks
  if pending == 0 then
    cb()
    return
  end
  for _, task in ipairs(tasks) do
    local finished = false
    task(function()
      if finished then
        return
      end
      finished = true
      pending = pending - 1
      if pending == 0 then
        cb()
      end
    end)
  end
end

--- Split a path list into chunks that keep a command line well below OS limits (Windows: ~32k chars).
---@param paths string[]
---@param max_chars integer?
---@return string[][]
function M.chunk(paths, max_chars)
  max_chars = max_chars or 8000
  local chunks, cur, len = {}, {}, 0
  for _, p in ipairs(paths) do
    if #cur > 0 and len + #p + 3 > max_chars then
      chunks[#chunks + 1] = cur
      cur, len = {}, 0
    end
    cur[#cur + 1] = p
    len = len + #p + 3
  end
  if #cur > 0 then
    chunks[#chunks + 1] = cur
  end
  return chunks
end

---@param msg string
---@param level integer?
function M.notify(msg, level)
  vim.notify(msg, level or vim.log.levels.INFO, { title = "git.nvim" })
end

return M
