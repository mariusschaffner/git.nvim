# git.nvim

An interactive git status dashboard for Neovim: branches, stashes, files and a commit graph in one view. You can stage, unstage, discard and open files, expand diffs inline and manage stashes, all without leaving the editor.

```
┌── Branches ────────────────────────────────────────────────────────────────┐
│  Nearest tag: v1.0-1-gbc8d9a4                                              │
│  Remote: [v1] | origin/main | (git pull)                                   │
│    <- 181024a upstream fix                                                 │
│  HEAD:   [^4] | main (protected) | (git push | git reset --soft HEAD~4)    │
└────────────────────────────────────────────────────────────────────────────┘
┌── Stashes ─────────────────────────────────────────────────────────────────┐
│  Stashes: [1] | P pop · A apply · D drop · <CR> show                       │
│    stash@{0} On main: experiment                                           │
└────────────────────────────────────────────────────────────────────────────┘
┌── Files ───────────────────────────────────────────────────────────────────┐
│  Staged changes (2) | u unstage · <Tab> diff · (git commit)                │
│   M keep.txt (+2 | -1)                                                     │
│   R old.txt → new.txt (+0 | -0)                                            │
│                                                                            │
│  Unstaged changes (2) | s stage · X discard · <Tab> diff                   │
│   M keep.txt (+1 | -0)                                                     │
│   M x.txt (+1 | -0)                                                        │
│                                                                            │
│  Untracked (1) | s stage · X delete · <Tab> diff                           │
│   ?  my notes.md (new)                                                     │
└────────────────────────────────────────────────────────────────────────────┘
┌── Graph ───────────────────────────────────────────────────────────────────┐
│  ○ bc8d9a4 (HEAD -> main) add x                                            │
│  ● 149f297 (tag: v1.0) Merge branch 'feature'                              │
│  ├─╮                                                                       │
│  │ ○ d72be35 (feature) feature work                                        │
│  ○ │ 36b513e main work                                                     │
│  ├─╯                                                                       │
│  ○ c682273 initial commit                                                  │
└────────────────────────────────────────────────────────────────────────────┘
```
(shown with `icons = false`; with a Nerd Font the labels get icons)

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

`setup()` is optional. The plugin defines `:GitStatus` at startup and loads its Lua modules on first use.

## Usage

`:GitStatus [float|split|vsplit|tab|toggle|close|refresh]`

| key | action |
|---|---|
| `s` / `u` | stage / unstage the file, a whole section (on its header), or a visual selection |
| `X` | discard unstaged changes / delete untracked files (asks first) |
| `<Tab>` / `=` | toggle inline diff |
| `<CR>` | open file (on a diff line: at that line), commit or stash |
| `o` / `v` / `t` | open in split / vsplit / tab |
| `P` / `A` / `D` | pop / apply / drop stash |
| `]]` / `[[` | next / previous section |
| `r` | refresh |
| `q` / `<Esc>` | close (`<Esc>` only for floats) |
| `?` | help |

All options, keymaps and highlight groups are documented in [`:help git.nvim`](doc/git.txt).

## Development

```sh
nvim --clean --headless -l tests/run.lua          # all tests
nvim --clean --headless -l tests/run.lua graph    # only specs matching "graph"
stylua --check .
```

The tests need nothing but `nvim` and `git`. They create throwaway repositories and ignore your global git config.

`extras/Show-GitStatus.ps1` is the PowerShell prompt function this plugin was ported from.
