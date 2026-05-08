# AGENTS.md

## Project Positioning

alma.nvim is the Neovim adapter layer for Alma, the local AI coding and
orchestration environment from https://alma.now/ by https://github.com/yetone.
Keep this repository focused on making Alma feel native inside Neovim with
minimal friction.

The plugin should preserve Alma's strengths: memory, providers, tools, skills,
agents, workspace awareness, and runtime orchestration. Neovim should provide
the editing experience: buffers, windows, selections, diagnostics, quickfix,
completion, folds, and keyboard-first navigation.

The project is also deeply influenced by CopilotChat.nvim
(https://github.com/CopilotC-Nvim/CopilotChat.nvim). Its author is a loyal user
and contributor of CopilotChat.nvim, so maintainers should respect that lineage
while still keeping alma.nvim focused on Alma's runtime and Neovim-native UX.

Avoid implementing a second AI backend in this repository. Prefer adapting
Alma's public local API and representing Alma state cleanly in Neovim.

## Implementation Model

- One Alma thread maps to one Neovim buffer.
- Alma REST endpoints are the source of truth for threads, messages,
  workspaces, catalogs, and reconciliation.
- WebSocket events provide low-latency streaming, generation status, tool events,
  and stop/submission flow.
- The default local API base is `http://127.0.0.1:23001`; keep `ALMA_API_URL`
  and `require("alma").setup({ api_url = ... })` overrides working.
- The default WebSocket URL is derived from the configured API URL unless
  `ws_url` is explicitly provided.
- Streaming or completion errors must reconcile through REST instead of trusting
  partial client state.
- Workspace behavior should follow the existing
  `git root -> cwd -> current file directory` resolution unless configured
  otherwise.

## Dependency Assumptions

- Require Neovim 0.12.0 or newer.
- Treat `snacks.picker` from `snacks.nvim` as a required navigation dependency.
- Treat `blink.cmp` as the required completion integration.
- Require `curl` in `PATH` for REST requests.
- Require Alma's local API to be running for live thread, catalog, and message
  behavior.
- Keep LuaRocks dependencies limited to Lua/runtime packaging unless a real
  LuaRocks-managed dependency is introduced.

## Code Style

- Use Lua modules that return a local `M` table.
- Keep dependencies as top-level `local require(...)` bindings.
- Use `snake_case` for Lua variables, functions, and module fields.
- Use 2-space indentation and match the surrounding file style.
- Keep Neovim API calls explicit through `vim.api`, `vim.fn`, `vim.fs`,
  `vim.system`, and related standard namespaces.
- Prefer small local helper functions over broad shared utility changes.
- Keep public setup options backward compatible; add defaults in
  `lua/alma/config.lua` when introducing user-facing config.
- Avoid global state unless it belongs in `lua/alma/state.lua` or an existing
  module-level cache.
- Do not shell out from UI/rendering paths when an existing REST, WebSocket, or
  Neovim API path exists.
- User-visible errors should go through the existing notification/util patterns
  and avoid noisy logs during normal streaming.

## UI Design Rules

- Stream assistant text directly into the Alma buffer as normal editable/readable text.
- Represent non-text objects with compact placeholder lines plus extmarks, not by
  inserting large payloads into the buffer.
- Tool calls, tool outputs, reasoning blocks, raw events, agent timeline events,
  queued states, and similar structured objects should use placeholder + extmark
  rendering.
- Expanded structured objects should render with extmark virtual lines and remain
  fold/toggle friendly through `za` and `:AlmaToggleBlock`.
- Full structured payloads belong in detail views such as `:AlmaToolDetails`, not
  inline in the chat buffer.
- Keep placeholder text short, stable, and scannable; avoid exposing raw JSON
  unless the user explicitly opens details.
- Preserve user scroll position while streaming. Only follow the bottom when the
  user is already near the active composer/response.
- Prefer native Neovim affordances: buffers, windows, highlights, folds,
  quickfix, extmarks, virtual text, virtual lines, and picker integrations.
- Define highlight groups with `default = true` and sensible links so themes can
  override them.
- Keep the `alma` filetype compatible with markdown and `markdown_inline`
  Tree-sitter behavior.

## Request and Composer Rules

- Token-only request lines configure metadata and should be removed from the
  submitted prompt.
- Unknown token-only lines should stay visible and surface warnings instead of
  being silently discarded.
- Request defaults should remain thread-local where appropriate: model,
  reasoning effort, tools, skills, MCP servers, and prompt context.
- Markdown image references should remain visible locally while being sent to
  Alma as file parts when supported.

## Documentation Rules

- Update `README.md` for user-facing behavior, commands, setup options, and
  positioning changes.
- Update `doc/alma.txt` when Neovim help, commands, mappings, or user-facing
  workflows change.
- Keep examples copy-pasteable and aligned with the current default config.

## Validation

Run the headless validation before handing off behavior changes when practical:

```bash
nvim --headless -u NONE -n -i NONE --cmd 'set rtp^=.' -l scripts/validate.lua
```

For UI/rendering changes, prefer adding focused assertions to
`scripts/validate.lua` near related helpers instead of creating unrelated test
harnesses.

## Commit Guidelines

- Use focused commits with one coherent change per commit.
- Prefer Conventional Commit prefixes: `feat:`, `fix:`, `docs:`, `refactor:`, `test:`, `chore:`.
- Keep the subject imperative and under roughly 72 characters.
- Mention user-visible behavior and validation in the commit body when the change is non-trivial.
- Do not commit generated snapshots, local config, or unrelated formatting churn.
