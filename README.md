# git.nvim

An interactive git status dashboard for Neovim: branches, tags, stashes, files and a commit graph in one view. You can stage, unstage, discard and open files, expand diffs inline, commit with an inline message editor, inspect and revert commits and manage stashes, all without leaving the editor.

```
╭── Branches ────────────────────────────────────────────────────────────────╮
│  Remote: [v1] | origin/main | f fetch · P pull        (cursor on this row) │
│  HEAD:   [^2] | main (protected)                                           │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Tags ────────────────────────────────────────────────────────────────────╮
│  Nearest tag: v1.0-2-gbc8d9a4                                              │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Stashes ─────────────────────────────────────────────────────────────────╮
│  Stashes: [1] | S pop / apply / drop · <CR> show                           │
│    stash@{0} On main: experiment                                           │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Files ───────────────────────────────────────────────────────────────────╮
│  Staged changes (2)                                                        │
│   M keep.txt (+2 | -1)                                                     │
│   R old.txt → new.txt (+0 | -0)                                            │
│                                                                            │
│  Unstaged changes (1)                                                      │
│   M x.txt (+1 | -0) | s stage · X discard · <Tab> diff · S stash           │
│                                                                            │
│  Untracked (1)                                                             │
│   ?  my notes.md (new)                                                     │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Graph ───────────────────────────────────────────────────────────────────╮
│        origin/main                                                         │
│  ○   ! 181024a upstream fix                                 14:32 03.11.26 │
│  │     HEAD -> main                                                        │
│  │ ○ ! bc8d9a4 add x                                        11:05 03.11.26 │
│  │ ○ ! a1b2c3d refactor                                     09:47 03.11.26 │
│  ├─╯                                                                       │
│  │     tag: v1.0                                                           │
│  ●     149f297 Merge branch 'feature'                       17:20 28.10.26 │
│  ├─╮                                                                       │
│  │ │   feature                                                             │
│  │ ○   d72be35 feature work                                 16:58 28.10.26 │
│  ├─╯                                                                       │
│  ○     36b513e main work                                    10:14 27.10.26 │
│  ○     c682273 initial commit                               08:30 20.10.26 │
╰────────────────────────────────────────────────────────────────────────────╯
```
(shown with `icons = false`; with a Nerd Font the labels get icons. Ref names go on a grey line above their commit; unpushed and incoming commits are marked `!`, incoming ones also get an amber row background. Unpushed commits on top of the upstream, and incoming commits on top of HEAD, are drawn on a side lane to the right (`├─╯`) until they are pushed / pulled.)

The view always fits its window: Files and Graph share the space below the other boxes and scroll on their own (`j`/`k` past a box edge, `<C-d>`/`<C-u>` & co., mouse wheel). While a diff is open only the Files box is shown; `<CR>` on a commit shows only the Graph (30%) and the commit's details (70%).

## Requirements

- Neovim ≥ 0.10
- git ≥ 2.23
- optional: a [Nerd Font](https://www.nerdfonts.com/) for icons

## Installation

[lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "<you>/git.nvim",
  cmd = "GitStatus",
  keys = { { "<leader>gs", "<cmd>GitStatus<cr>", desc = "Git status" } },
  opts = {},
}
```

`setup()` is optional. The plugin defines `:GitStatus` at startup and loads its Lua modules on first use. Shared options (`icons`, `timeout`) sit at the top level, dashboard options under `status`:

```lua
require("git").setup({
  icons = false,
  status = {
    window = { kind = "split" },
    keymaps = { discard = false },
  },
})
```

## Usage

`:GitStatus [float|split|vsplit|tab|toggle|close|refresh]`

| key | action |
|---|---|
| `s` / `u` | stage / unstage the file, a whole section (on its header), or a visual selection |
| `X` | discard unstaged changes / delete untracked files (asks first) |
| `<Tab>` | toggle inline diff |
| `<CR>` | open file (on a diff line: at that line); on a stash: list its files like the Files box, `<Tab>` toggles their diffs, `q` goes back; on a commit: toggle its details box (the cursor moves into it; `k` at its top goes to the top of the graph); on commits selected in Visual mode: their details combined |
| `S` | stash menu: `s` stashes the file(s) under the cursor / selected, anywhere else all changes (untracked included; asks for a message); on a stash `p` / `a` / `d` pop / apply / drop it |
| `c c` | commit: the Files box turns into an editable commit message box; `<C-s>` or `:w` commits, `q` / `<Esc>` cancels (keeping the draft). `c` alone shows a popup with the choices |
| `c a` | amend the last commit with the staged changes, editing its message |
| `r` | on a commit in the graph: revert it (asks first) |
| `R` | on an unpushed commit in the graph: change its message |
| `f` | on the Remote row: fetch (a spinner shows in the Branches box meanwhile) |
| `P` | on the Remote row: pull the fetched commits (fast-forward; diverged: as `pull.rebase` says); hinted on the Remote row while there are some, with a spinner meanwhile |
| `p` | on the HEAD row: push menu: `u` toggles `--set-upstream <remote> HEAD` (publish a new branch), `f` toggles `--force-with-lease`, then `p` pushes; a spinner shows on the HEAD row meanwhile |
| `z` | in the Files or Graph box: show only that box over the whole window; `z` or `q` to go back |
| `/` / `n` / `N` | in the zoomed graph: search hashes, ref names and subjects, next / previous match |
| `q` / `<Esc>` | close the commit editor, details or zoom if open, else the view (`<Esc>` only for floats) |
| `?` | help: the keymaps of the box under the cursor |

All options, keymaps and highlight groups are documented in [`:help git.nvim`](doc/git.txt).

## Development

```sh
nvim --clean --headless -l tests/run.lua          # all tests
nvim --clean --headless -l tests/run.lua graph    # only specs matching "graph"
stylua --check .
```

The tests need nothing but `nvim` and `git`. They create throwaway repositories and ignore your global git config.

`extras/Show-GitStatus.ps1` is the PowerShell prompt function this plugin was ported from.
