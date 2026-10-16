# git.nvim

An interactive git status dashboard for Neovim: branches, tags, stashes, files and a commit graph in one view. You can stage, unstage, discard and open files, expand diffs inline, commit with an inline message editor, inspect and revert commits and manage stashes, all without leaving the editor.

```
╭── Branches ────────────────────────────────────────────────────────────────╮
│  Remote: [v1] | origin/main | (git pull)                                   │
│  HEAD:   [^2] | main (protected) | (git push | git reset --soft HEAD~2)    │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Tags ────────────────────────────────────────────────────────────────────╮
│  Nearest tag: v1.0-2-gbc8d9a4                                              │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Stashes ─────────────────────────────────────────────────────────────────╮
│  Stashes: [1] | P pop · A apply · D drop · <CR> show                       │
│    stash@{0} On main: experiment                                           │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Files ───────────────────────────────────────────────────────────────────╮
│  Staged changes (2) | u unstage · <Tab> diff · c commit                    │
│   M keep.txt (+2 | -1)                                                     │
│   R old.txt → new.txt (+0 | -0)                                            │
│                                                                            │
│  Unstaged changes (1) | s stage · X discard · <Tab> diff                   │
│   M x.txt (+1 | -0)                                                        │
│                                                                            │
│  Untracked (1) | s stage · X delete · <Tab> diff                           │
│   ?  my notes.md (new)                                                     │
╰────────────────────────────────────────────────────────────────────────────╯
╭── Graph ───────────────────────────────────────────────────────────────────╮
│  ○ 181024a (origin/main) upstream fix                                      │
│  │ ○ bc8d9a4 add x                                                         │
│  │ │ HEAD -> main                                                          │
│  │ ○ a1b2c3d refactor                                                      │
│  ├─╯                                                                       │
│  ● 149f297 Merge branch 'feature'                                          │
│  │ tag: v1.0                                                               │
│  ├─╮                                                                       │
│  │ ○ d72be35 feature work                                                  │
│  │ │ feature                                                               │
│  ○ │ 36b513e main work                                                     │
│  ├─╯                                                                       │
│  ○ c682273 initial commit                                                  │
╰────────────────────────────────────────────────────────────────────────────╯
```
(shown with `icons = false`; with a Nerd Font the labels get icons. Ref names go on a grey line below their commit; unpushed and incoming commits get a green / amber row background. Unpushed commits on top of the upstream are drawn as `!` on a side lane that joins the upstream commit, until they are pushed.)

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
| `<Tab>` / `=` | toggle inline diff |
| `<CR>` | open file (on a diff line: at that line) or stash; on a commit: toggle its details box (the cursor moves into it; `k` at its top goes to the top of the graph); on commits selected in Visual mode: their details combined |
| `o` / `v` / `t` | open in split / vsplit / tab (commits as `git show`) |
| `P` / `A` / `D` | pop / apply / drop stash |
| `c` | commit: the Files box turns into an editable commit message box; `<C-s>` or `:w` commits, `q` / `<Esc>` cancels (keeping the draft) |
| `r` | on a commit in the graph: revert it (asks first) |
| `q` / `<Esc>` | close the commit editor or details if open, else the view (`<Esc>` only for floats) |
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
