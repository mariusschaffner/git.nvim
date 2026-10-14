# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

git.nvim is a Neovim plugin (Lua, Neovim ≥ 0.10, git ≥ 2.23) providing an interactive git status dashboard via `:GitStatus`: branches, stashes, files (with inline diffs) and a commit graph in one buffer. It is a port of the PowerShell prompt function in `extras/Show-GitStatus.ps1`. User-facing docs (options, keymaps, highlight groups) live in `doc/git.txt` — keep it in sync with `lua/git/config.lua` and `lua/git/highlights.lua`.

## Commands

```sh
nvim --clean --headless -l tests/run.lua          # all tests
nvim --clean --headless -l tests/run.lua graph    # only spec files whose name contains "graph"
stylua --check .                                  # formatting (no stylua.toml; stylua defaults)
```

`tests/run.lua` is a dependency-free, busted-style runner (`describe`, `it`, `before_each`, `after_each`, plus assertion globals `eq(expected, actual)`, `ok`, `matches`). The filter matches spec *file names* only, not test names. It makes git hermetic (no system/global config, fixed identity). `tests/helpers.lua` creates throwaway repos (`H.repo`, `H.write`, `H.commit`) and `H.await` blocks on async callbacks via `vim.wait`.

## Architecture

Data flows one way: **repo → collect → render → ui**, with **actions** mutating and triggering a refresh.

- `plugin/git.lua` only defines `:GitStatus` and `<Plug>` maps; all modules are lazy-loaded through `lua/git/init.lua` (subcommand dispatch).
- `runner.lua` — the only place git is spawned (`vim.system`, async, callbacks scheduled onto the main loop). Read-only calls use `runner.run` with `GIT_OPTIONAL_LOCKS=0` so they never take `index.lock`. Repo-modifying calls must go through `runner.mutate`, a serial queue so mutations never race. Mutations on paths use `literal = true` (`--literal-pathspecs`) and `util.chunk` to stay under command-line limits. `error_message` slices off the fixed argv prefix — update the slice index if `M.argv` changes.
- `repo.lua` — resolves `{ root, gitdir }` (gitdir differs from `root/.git` for worktrees/submodules; always use `repo.gitdir`).
- `collect.lua` — builds a `GitState` with two parallel rounds of git calls (`util.all`): first status/numstat/stash/tags/remotes, then upstream-dependent queries (the graph log, which includes `@{upstream}` when behind, and the unpushed/incoming hash sets). Parsers in `parse/` are pure functions over `-z`/custom-format output (formats defined as constants in `parse/log.lua`). Remote tags (`ls-remote`, network) are cached per repo/remote with a TTL and fetched separately by the UI.
- `render.lua` — pure: `GitState` + `{ width, height, expanded, commit, scroll, focus }` → `{ lines, marks, items, sections, boxes, scroll }`. Open diffs hide Graph; `opts.commit` (set by `View:toggle_commit`) hides Files and adds a Commit box. With `height`, the lower boxes split the remaining height and are windowed by per-box scroll offsets (`ui.lua` maps j/k/scroll keys/mouse wheel to box scrolling; the window itself never scrolls). `items` maps line numbers to `GitItem`s, which is how actions know what's under the cursor; `item_key` gives stable identity so the cursor survives redraws. Uses `graph.lua` (lane-based layout, pure) for the commit graph.
- `ui.lua` — `View` owns buffer/window, `state`, `expanded` diffs, and a `generation` counter: `refresh()` discards results of superseded refreshes. `redraw()` re-renders without git calls (e.g. on resize). Only one view exists (`M.current`). `watch.lua` watches the gitdir (index, HEAD, refs files) and triggers debounced refreshes.
- `actions.lua` — keymap handlers (stage/unstage/discard/open/stash/diff toggle/help) operating on `GitItem`s from cursor or visual range; key bindings come from `config.keys(action)`, and `M.descriptions`/`M.order` drive the help window and render hints.
- `config.lua` — defaults + validation; read options via `require("git.config").options` at call time (not cached at module load) so `setup()` takes effect.

Tests mirror this split: parser/graph/render specs are pure; `collect_spec` and `ui_spec` run against real temp repos.
