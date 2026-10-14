# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

git.nvim is a Neovim plugin (Lua, Neovim ≥ 0.10, git ≥ 2.23) providing an interactive git status dashboard via `:GitStatus`: branches, tags, stashes, files (with inline diffs), a commit graph and commit details in one buffer. It is a port of the PowerShell prompt function in `extras/Show-GitStatus.ps1`. User-facing docs (options, keymaps, highlight groups) live in `doc/git.txt` — keep it in sync with `lua/git/config.lua` and `lua/git/highlights.lua`.

## Commands

```sh
nvim --clean --headless -l tests/run.lua          # all tests
nvim --clean --headless -l tests/run.lua graph    # only spec files whose name contains "graph"
stylua --check .                                  # formatting (no stylua.toml; stylua defaults)
```

`tests/run.lua` is a dependency-free, busted-style runner (`describe`, `it`, `before_each`, `after_each`, plus assertion globals `eq(expected, actual)`, `ok`, `matches`). The filter matches spec *file names* only, not test names. It makes git hermetic (no system/global config, fixed identity). `tests/helpers.lua` creates throwaway repos (`H.repo`, `H.write`, `H.commit`) and `H.await` blocks on async callbacks via `vim.wait`.

## Architecture

```
lua/git/
  init.lua  config.lua  highlights.lua  health.lua   -- entry point and cross-feature modules
  core/     runner.lua  repo.lua  util.lua  watch.lua  queries.lua
  parse/    status.lua  numstat.lua  log.lua        -- pure parsers
  status/   collect.lua  render.lua  graph.lua  ui.lua  actions.lua   -- the :GitStatus dashboard
```

`core/` and `parse/` are shared and must not depend on a feature. Each feature lives in its own folder (`status/` now; `signs/`, `blame/` etc. later) and gets its own `config.options.<feature>` table and its own `:Git<Feature>` command. There is deliberately no umbrella `:Git` command: it would clash with vim-fugitive.

Within `status/`, data flows one way: **repo → collect → render → ui**, with **actions** mutating and triggering a refresh.

- `plugin/git.lua` only defines `:GitStatus` and `<Plug>` maps; all modules are lazy-loaded through `lua/git/init.lua` (subcommand dispatch).
- `core/runner.lua` — the only place git is spawned (`vim.system`, async, callbacks scheduled onto the main loop). Read-only calls use `runner.run` with `GIT_OPTIONAL_LOCKS=0` so they never take `index.lock`. Repo-modifying calls must go through `runner.mutate`, a serial queue so mutations never race. Mutations on paths use `literal = true` (`--literal-pathspecs`) and `util.chunk` to stay under command-line limits. `error_message` slices off the fixed argv prefix — update the slice index if `M.argv` changes.
- `core/repo.lua` — resolves `{ root, gitdir }` (gitdir differs from `root/.git` for worktrees/submodules; always use `repo.gitdir`).
- `core/queries.lua` — read-only git queries that are not tied to a view (`file_diff`, `commit_details`). Put new general-purpose queries here, not in a feature's collect module.
- `core/watch.lua` — watches the gitdir (index, HEAD, refs files) and calls back; the status view uses it for debounced refreshes. It is currently started per view, not shared per repo.
- `status/collect.lua` — builds a `GitState` with two parallel rounds of git calls (`util.all`): first status/numstat/stash/tags/remotes, then upstream-dependent queries (the graph log, which includes `@{upstream}` when behind, and the unpushed/incoming hash sets). Parsers in `parse/` are pure functions over `-z`/custom-format output (formats defined as constants in `parse/log.lua`). Remote tags (`ls-remote`, network) are cached per repo/remote with a TTL and fetched separately by the UI.
- `status/render.lua` — pure: `GitState` + `{ width, height, expanded, commit, scroll, focus }` → `{ lines, marks, items, sections, boxes, scroll }`. Open diffs show only Files; `opts.commit` (set by `View:toggle_commit`) shows only Graph (30%) and a Commit box (70%). With `height`, the lower boxes split the remaining height and are windowed by per-box scroll offsets (`ui.lua` maps j/k/scroll keys/mouse wheel to box scrolling; the window itself never scrolls). `items` maps line numbers to `GitItem`s, which is how actions know what's under the cursor; `item_key` gives stable identity so the cursor survives redraws. Uses `status/graph.lua` (lane-based layout, pure) for the commit graph.
- `status/ui.lua` — `View` owns buffer/window, `state`, `expanded` diffs, the shown `commit`, per-box `scroll` offsets, and a `generation` counter: `refresh()` discards results of superseded refreshes. `redraw()` re-renders without git calls (e.g. on resize). Only one view exists (`M.current`).
- `status/actions.lua` — keymap handlers (stage/unstage/discard/open/stash/diff toggle/help) operating on `GitItem`s from cursor or visual range; key bindings come from `config.keys(action)` (the `status.keymaps` table), and `M.descriptions`/`M.order` drive the help window and render hints.
- `highlights.lua` — groups *copy* their source group (via `nvim_get_hl`) with italic removed instead of linking, since the plugin must never render italic text; `setup()` remembers what it applied so it re-applies on colorscheme changes but leaves user overrides alone. A few groups (`M.colors`) have fixed colors (grey box borders, commit row backgrounds).
- `config.lua` — defaults + validation. Shared options (`icons`, `timeout`) are top-level, dashboard options live under `status`; a `migrate` step moves the old flat dashboard keys into `status` with a warning. Read options via `require("git.config").options` at call time (not cached at module load) so `setup()` takes effect. When adding an option, update `M.defaults`, `validate` and the defaults block in `doc/git.txt` together.

Tests mirror this split: parser/graph/render/config specs are pure; `collect_spec` and `ui_spec` run against real temp repos.
