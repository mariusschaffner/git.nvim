local status = require("git.parse.status")
local numstat = require("git.parse.numstat")
local log = require("git.parse.log")

local Z = "\0"

describe("parse.status", function()
  it("parses branch headers", function()
    local s = status.parse(
      table.concat(
        { "# branch.oid abc123", "# branch.head main", "# branch.upstream origin/main", "# branch.ab +2 -3" },
        Z
      ) .. Z
    )
    eq({
      oid = "abc123",
      head = "main",
      detached = false,
      unborn = false,
      upstream = "origin/main",
      ahead = 2,
      behind = 3,
      gone = false,
    }, s.branch)
  end)

  it("detects a gone upstream (upstream without ahead/behind)", function()
    local s = status.parse("# branch.oid abc" .. Z .. "# branch.head feat" .. Z .. "# branch.upstream origin/feat" .. Z)
    eq(true, s.branch.gone)
  end)

  it("detects detached HEAD and unborn branches", function()
    local d = status.parse("# branch.oid abc" .. Z .. "# branch.head (detached)" .. Z)
    eq(true, d.branch.detached)
    local u = status.parse("# branch.oid (initial)" .. Z .. "# branch.head main" .. Z)
    eq(true, u.branch.unborn)
    eq(nil, u.branch.oid)
  end)

  it("splits ordinary entries into staged and unstaged, keeping spaces in paths", function()
    local s = status.parse("1 MM N... 100644 100644 100644 aaa bbb dir/my file.txt" .. Z)
    eq(1, #s.files.staged)
    eq(1, #s.files.unstaged)
    eq("dir/my file.txt", s.files.staged[1].path)
    eq("M", s.files.staged[1].code)
    eq("M", s.files.unstaged[1].code)
  end)

  it("parses renames with the original path from the next NUL field", function()
    local s = status.parse("2 R. N... 100644 100644 100644 aaa bbb R100 new name.txt" .. Z .. "old name.txt" .. Z)
    eq(1, #s.files.staged)
    eq(0, #s.files.unstaged)
    eq("new name.txt", s.files.staged[1].path)
    eq("old name.txt", s.files.staged[1].orig)
    eq("R", s.files.staged[1].code)
  end)

  it("does not confuse the entry after a rename with a new entry", function()
    local s = status.parse(
      "2 R. N... 100644 100644 100644 a b R100 b.txt" .. Z .. "? looks like untracked" .. Z .. "? real.txt" .. Z
    )
    eq("? looks like untracked", s.files.staged[1].orig)
    eq(
      { "real.txt" },
      vim.tbl_map(function(f)
        return f.path
      end, s.files.untracked)
    )
  end)

  it("parses conflicts, untracked and submodules; ignores ignored entries", function()
    local s = status.parse(table.concat({
      "u UU N... 100644 100644 100644 100644 a b c conflict file.txt",
      "? new dir/",
      "! ignored.log",
      "1 .M SC.. 160000 160000 160000 a a sub",
    }, Z) .. Z)
    eq("conflict file.txt", s.files.conflicted[1].path)
    eq("UU", s.files.conflicted[1].code)
    eq("new dir/", s.files.untracked[1].path)
    eq(true, s.files.unstaged[1].submodule)
    eq(1, #s.files.untracked)
  end)

  it("handles unicode and newline in paths", function()
    local s = status.parse("? ünï cødé.txt" .. Z .. "? line\nbreak.txt" .. Z)
    eq("ünï cødé.txt", s.files.untracked[1].path)
    eq("line\nbreak.txt", s.files.untracked[2].path)
  end)

  it("handles empty output", function()
    local s = status.parse("")
    eq(0, #s.files.staged + #s.files.unstaged + #s.files.untracked + #s.files.conflicted)
  end)
end)

describe("parse.numstat", function()
  it("parses regular, binary and renamed entries", function()
    local out = "3\t1\tsrc/a b.lua" .. Z .. "-\t-\timg.png" .. Z .. "5\t0\t" .. Z .. "old.txt" .. Z .. "new.txt" .. Z
    local m = numstat.parse(out)
    eq({ added = 3, deleted = 1, binary = false }, m["src/a b.lua"])
    eq({ added = 0, deleted = 0, binary = true }, m["img.png"])
    eq({ added = 5, deleted = 0, binary = false }, m["new.txt"])
    eq(nil, m["old.txt"])
  end)

  it("does not suffix-match paths", function()
    local m = numstat.parse("1\t1\tab.txt" .. Z)
    eq(nil, m["b.txt"])
  end)
end)

describe("parse.log", function()
  it("parses commits with parents and decorations", function()
    local out = "aaaa\31aa\31bbbb cccc\31HEAD -> main, tag: v1\31Merge it\30\nbbbb\31bb\31\31\31root commit\30\n"
    local commits = log.parse(out)
    eq(2, #commits)
    eq({ "bbbb", "cccc" }, commits[1].parents)
    eq("HEAD -> main, tag: v1", commits[1].deco)
    eq("Merge it", commits[1].subject)
    eq({}, commits[2].parents)
    eq("", commits[2].deco)
  end)

  it("parses stash entries", function()
    local s = log.parse_stashes("stash@{0}\31WIP on main: abc msg\30\nstash@{1}\31On main: other\30\n")
    eq(
      { { ref = "stash@{0}", subject = "WIP on main: abc msg" }, { ref = "stash@{1}", subject = "On main: other" } },
      s
    )
  end)
end)

describe("health", function()
  it("parses git versions", function()
    local h = require("git.health")
    eq({ 2, 55, 0 }, h.parse_git_version("git version 2.55.0.windows.3"))
    eq({ 2, 39, 2 }, h.parse_git_version("git version 2.39.2 (Apple Git-143)"))
    eq(nil, h.parse_git_version("nope"))
  end)
end)
