# alma.nvim

Native Neovim frontend for Alma's local runtime. One Alma thread maps to one
Neovim buffer; REST is used as the source of truth and WebSocket is used for
fast updates and request submission.

## Requirements

- Neovim 0.12.0 or newer.
- `curl` in `PATH`.
- Alma API running locally. The default is `http://localhost:23001`; override
  with `ALMA_API_URL` or `require("alma").setup({ api_url = "..." })`.
- LuaRocks for dependency management. This MVP has no external Lua runtime
  dependency beyond Neovim's Lua environment, but the rockspec is the canonical
  dependency/install manifest.

## Install

With a plugin manager, add this repository and call:

```lua
require("alma").setup({
  api_url = vim.env.ALMA_API_URL or "http://localhost:23001",
})
```

With LuaRocks from this checkout:

```bash
luarocks make alma.nvim-scm-1.rockspec
```

## Commands

- `:AlmaHealth` checks Neovim, `curl`, and the Alma API.
- `:AlmaThreadOpen <thread_id>` opens a thread buffer and fetches messages.
- `:AlmaSubmit [prompt]` submits prompt text. Without arguments it submits the
  editable prompt area at the bottom of an Alma buffer.
- `:AlmaStop` sends `stop_generation` over WebSocket.
- `:AlmaThreads`, `:AlmaProjects`, `:AlmaBuffers`, `:AlmaEvents` open
  `snacks.picker` navigation.
- `:AlmaModels`, `:AlmaTools`, `:AlmaSkills`, `:AlmaMCPServers` update
  thread-local request defaults.
- `:AlmaToolDetails`, `:AlmaQuickfix`, `:AlmaBlockQuickfix`, `:AlmaDiff` inspect
  tool output, file locations, and patch-like output.

## blink.cmp

Register the source:

```lua
require("blink.cmp").setup({
  sources = {
    default = { "lsp", "path", "snippets", "buffer", "alma" },
    providers = {
      alma = {
        name = "Alma",
        module = "alma.completion.blink",
      },
    },
  },
})
```

Static completions work offline for `/`, `@`, `$`, and `>`. Dynamic models,
tools, skills, and MCP servers are fetched opportunistically from Alma API
catalog endpoints and cached with a TTL.

## Request Tokens

Token-only lines configure a request and are removed from the final prompt:

- `/skill:<id>` enables a skill for the request. `/stop` stops generation.
- `@Bash`, `@Read`, `@Grep`, `@Glob`, `@Task`, `@mcp:<server>` configure tools.
- `$model:<id>`, `$reasoning:low|medium|high|xhigh`, `$temp:<n>`, `$no-tools`
  configure generation.
- `>buffer`, `>selection`, `>diagnostics`, `>diff`, `>file:<path>`, `>zk:<id>`
  add structured ephemeral context metadata.

Unknown token-only lines are kept in the prompt and surfaced as warnings.

## Reliability Contract

Submitting a request immediately renders a local user block and assistant
placeholder. If Alma is already generating for the same thread, the request is
queued in Neovim and the buffer shows that queued state. Completion or error
events force REST reconciliation through `GET /api/threads/<id>/messages`.

If no related WebSocket event arrives before the ack timeout, the buffer shows
that the request was sent and starts REST polling fallback.

## Verify

Run the local headless validation:

```bash
nvim --headless -u NONE -n -i NONE --cmd 'set rtp^=.' -l scripts/validate.lua
```

Run a manual API check:

```vim
:AlmaHealth
:AlmaThreadOpen <thread_id>
```
