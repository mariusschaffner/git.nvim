local M = {}

local uv = vim.uv or vim.loop

-- Files in the git dir whose change means the status view is out of date.
local RELEVANT = {
  index = true,
  HEAD = true,
  ORIG_HEAD = true,
  FETCH_HEAD = true,
  MERGE_HEAD = true,
  CHERRY_PICK_HEAD = true,
  REVERT_HEAD = true,
  ["packed-refs"] = true,
}

--- Watch a git dir (non-recursively) and call `cb` when index/HEAD/refs-like files change.
--- `cb` may be called from a fast event context; pass something that schedules (e.g. util.debounce).
---@param gitdir string
---@param cb fun()
---@return { stop: fun() }?
function M.start(gitdir, cb)
  local handle = uv.new_fs_event()
  if not handle then
    return nil
  end
  local ok = pcall(handle.start, handle, gitdir, {}, function(err, filename)
    if err then
      return
    end
    -- Some platforms do not report a filename; refresh to be safe.
    if not filename or RELEVANT[filename] or filename:match("^rebase%-") then
      cb()
    end
  end)
  if not ok then
    handle:close()
    return nil
  end
  return {
    stop = function()
      if not handle:is_closing() then
        handle:stop()
        handle:close()
      end
    end,
  }
end

return M
