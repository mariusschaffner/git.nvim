local H = {}

--- Run git synchronously in `cwd`; errors on failure unless `allow_fail`.
---@return string stdout, integer code
function H.git(cwd, args, allow_fail)
  local cmd = { "git", "-c", "init.defaultBranch=main", "-c", "core.autocrlf=false", "-c", "commit.gpgsign=false" }
  vim.list_extend(cmd, args)
  local r = vim.system(cmd, { cwd = cwd, text = true }):wait()
  if r.code ~= 0 and not allow_fail then
    error(("git %s failed (%d): %s"):format(table.concat(args, " "), r.code, r.stderr), 2)
  end
  return r.stdout or "", r.code
end

--- Create an empty repository in a fresh temp dir.
---@return string dir
function H.repo()
  local dir = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(dir, "p")
  H.git(dir, { "init", "--quiet" })
  return dir
end

--- Write a file (parents created). `content` is a string or list of lines.
function H.write(dir, path, content)
  local full = dir .. "/" .. path
  vim.fn.mkdir(vim.fs.dirname(full), "p")
  local f = assert(io.open(full, "wb"))
  f:write(type(content) == "table" and (table.concat(content, "\n") .. "\n") or content)
  f:close()
end

function H.commit(dir, msg)
  H.git(dir, { "add", "-A" })
  H.git(dir, { "commit", "--quiet", "--allow-empty", "-m", msg })
end

--- Block until `fn(done)` calls done(...); returns the values passed to done.
function H.await(fn, timeout)
  local result
  fn(function(...)
    result = { n = select("#", ...), ... }
  end)
  ok(
    vim.wait(timeout or 10000, function()
      return result ~= nil
    end, 10),
    "timed out waiting for async callback"
  )
  return unpack(result, 1, result.n)
end

---@return GitRepo
function H.find(dir)
  local repo, err = H.await(function(done)
    require("git.core.repo").find(dir, done)
  end)
  return ok(repo, err)
end

---@return GitState
function H.collect(dir)
  local repo = H.find(dir)
  local state, err = H.await(function(done)
    require("git.status.collect").collect(repo, done)
  end)
  return ok(state, err)
end

--- Paths of the files in a section.
function H.paths(state, section)
  return vim.tbl_map(function(f)
    return f.path
  end, state.files[section])
end

function H.rm(dir)
  vim.fn.delete(dir, "rf")
end

return H
