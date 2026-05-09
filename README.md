# alma.nvim

Native Neovim frontend for Alma's local runtime. One Alma thread maps to one
Neovim buffer; REST is used as the source of truth and WebSocket is used for
fast updates and request submission.

## Positioning

`alma.nvim` is the Neovim adapter layer for [Alma](https://alma.now/), the AI
coding and orchestration environment created by [yetone](https://github.com/yetone).
It embeds Alma into Neovim with as little friction as possible: prompts, streamed
answers, tool calls, thread navigation, model selection, and workspace context all
live naturally inside the editor.

The plugin keeps Alma's memory, provider orchestration, skills, tools, agents,
and local runtime as the source of intelligence, while Neovim stays responsible
for the fast editing loop: buffers, windows, selections, diagnostics, quickfix,
completion, and keyboard-native navigation.

With `alma.nvim`, you can skip the heavy Electron frontend when you are already
working in your favorite terminal editor. It brings Alma into the place where
you write, navigate, refactor, and review code every day, so AI assistance feels
like part of the editing flow rather than another app to context-switch into.

`alma.nvim` is also deeply influenced by
[CopilotChat.nvim](https://github.com/CopilotC-Nvim/CopilotChat.nvim). Its
author is a loyal user and contributor of CopilotChat.nvim, and `alma.nvim` carries
forward that same belief that AI conversations should feel editor-native instead
of bolted on.

## Requirements

- Neovim 0.12.0 or newer.
- `snacks.picker` from `snacks.nvim` for thread, workspace, buffer, event,
  model, tool, skill, and MCP navigation.
- `blink.cmp` for Alma's completion source.
- `curl` in `PATH`.
- Alma API running locally. The default is `http://127.0.0.1:23001`; override
  with `ALMA_API_URL` or `require("alma").setup({ api_url = "..." })`.
- LuaRocks for dependency management. This MVP has no LuaRocks-managed runtime
  dependency beyond Neovim's Lua environment, but the rockspec is the canonical
  dependency/install manifest.

## Install

With a plugin manager, install `snacks.nvim`, `blink.cmp`, and this repository,
then call:

```lua
require("alma").setup({
  api_url = vim.env.ALMA_API_URL or "http://127.0.0.1:23001",
  model = nil,
  reasoning_effort = nil,
  window_layout = "float",
})
```

With LuaRocks from this checkout:

```bash
luarocks make alma.nvim-scm-1.rockspec
```

## Commands

- `:AlmaHealth` checks Neovim, `curl`, and the Alma API.
- `:Alma new [title]` creates a new thread in the current workspace.
- `:Alma pick` and `:AlmaThreads` pick a thread from the current workspace.
- `:AlmaThreadsGlobal` keeps the old global thread picker behavior explicit.
- `:Alma open <thread_id>`, `:Alma toggle <thread_id>`, `:Alma float <thread_id>`,
  and `:Alma sidebar <thread_id>` open or hide a specific Alma thread using the
  configured window layout behavior.
- `:AlmaThreadOpen <thread_id>` opens a thread with the configured Alma layout
  and fetches messages.
- `:AlmaSubmit [prompt]` submits prompt text. Without arguments it submits the
  editable bottom `## You` composer in an Alma buffer.
- `:AlmaStop` sends `stop_generation` over WebSocket.
- `:AlmaThreads`, `:AlmaProjects`, `:AlmaBuffers`, `:AlmaEvents` open
  `snacks.picker` navigation.
- `:AlmaModels`, `:AlmaTools`, `:AlmaSkills`, `:AlmaMCPServers` update
  thread-local request defaults.
- `:AlmaToolDetails`, `:AlmaAgentCrew`, `:AlmaToggleBlock`, `:AlmaQuickfix`,
  `:AlmaBlockQuickfix`, `:AlmaDiff` inspect, expand, or route tool output,
  native crew timelines, file locations, and patch-like output.

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

## Defaults

`model` and `reasoning_effort` default to `nil`, so each thread/request uses
Alma's backend default unless the user configures a default or selects one in the
thread composer. `window_layout` defaults to `"float"`; set it to `"sidebar"` to
open threads in the side panel by default.

## Workspace Resolution

By default `alma.nvim` resolves the current workspace as `git root -> cwd -> current
file directory`. Override it with:

```lua
require("alma").setup({
  resolve_workspace = function(ctx)
    return { id = nil, name = "project", path = ctx.git_root or ctx.cwd or ctx.file_dir }
  end,
})
```

## Request Tokens

Token-only lines configure a request and are removed from the final prompt:

- `/skill:<id>` enables a skill for the request. `/stop` stops generation.
- `@Bash`, `@Read`, `@Grep`, `@Glob`, `@Task`, `@mcp:<server>` configure tools.
- `$model:<id>`, `$reasoning:low|medium|high|xhigh`, `$temp:<n>`, `$no-tools`
  configure generation.
- `>buffer`, `>selection`, `>diagnostics`, `>diff`, and `>file:<path>` add
  structured ephemeral context metadata.

Unknown token-only lines are kept in the prompt and surfaced as warnings.

Markdown images like `![alt](./image.png)`, `![alt](/abs/image.png)`,
`![alt](file:///abs/image.png)`, `![alt](https://...)`, and data URI images are
sent as Alma file parts while the original markdown stays visible locally.

## Extension Hooks

`require("alma.hooks")` provides a generic hook registry. Register callbacks with
`hooks.on(name, callback)` or `hooks.register(name, callback)`; callbacks receive
one event table and are isolated with `pcall`, so one failing callback does not
stop later callbacks or the submit flow. Each dispatch also emits a matching
`User` autocmd whose `event.data` contains the same inspectable table.

Supported hooks and autocmds:

- `thread_opened` -> `User AlmaThreadOpened`
- `thread_changed` -> `User AlmaThreadChanged`
- `before_submit` -> `User AlmaBeforeSubmit`
- `request_compiled` -> `User AlmaRequestCompiled`
- `after_submit` -> `User AlmaAfterSubmit`
- `generation_completed` -> `User AlmaGenerationCompleted`
- `generation_error` -> `User AlmaGenerationError`
- `proposal_received` -> `User AlmaProposalReceived`

```lua
local hooks = require("alma.hooks")

hooks.on("before_submit", function(event)
  -- event.thread_id, event.thread, and event.spec are available here.
end)

vim.api.nvim_create_autocmd("User", {
  pattern = "AlmaGenerationCompleted",
  callback = function(event)
    vim.print(event.data.thread_id)
  end,
})
```

## Context Attachments

`require("alma.context")` stores thread-scoped file or JSON attachments with
stable id-based dedupe. Pending attachments are appended to the next request's
`ephemeralContext` after `before_submit` hooks and before request compilation.
Inline JSON is sent as JSON context by default; set `inline = false`,
`file_backed = true`, provide `path`, or set `max_inline_bytes` to use a
file-backed JSON context. Submitted requests carry compact attachment metadata
labels/counts, not raw JSON content. `once = true` attachments are removed only
after the local submit dispatch succeeds, while persistent attachments remain
registered.

```lua
local context = require("alma.context")

context.attach("thread-id", {
  type = "file",
  id = "build-log",
  path = "/tmp/build.log",
  label = "Build log",
  once = true,
})

context.attach("thread-id", {
  type = "json",
  id = "review-state",
  title = "Review state",
  content = { pending = 2 },
})

context.attach("thread-id", {
  type = "json",
  id = "review-snapshot",
  title = "Review snapshot",
  content = { files = 3 },
  inline = false,
  once = true,
})

local pending = context.list("thread-id")
local consumed = context.consume("thread-id")
```

Proposal-like WebSocket events with generic `proposal`/`files`/`diff` payloads
are normalized to the `proposal_received` hook shape before dispatching
`User AlmaProposalReceived`.

## Tool Output Rendering

Alma buffers use the dedicated `alma` filetype while registering markdown and
`markdown_inline` Tree-sitter services. If Tree-sitter is unavailable, they fall
back to legacy markdown syntax; otherwise they avoid stacking both highlighters.
They persist only chat text plus one-line placeholders for reasoning, tool
calls, raw events, and agent timeline events. Subagent streams render as
color-keyed `Alma <agent>` source titles without inserting delegated content into
the chat buffer, matching their role as specialized tool-call activity. Use
`:AlmaAgentCrew` or `:Alma crews` to inspect the current thread's native Alma
crew timeline, fetched from `/api/threads/{id}/agent-crew` and rendered as
missions, sprint progress, active steps, contracts, evaluations, handoffs, and
runs while hiding delegated message content. The same crew timeline also appears
as compact virtual progress lines below the bottom composer, so the current task
step stays visible without adding text to the buffer. Placeholder bodies are
rendered with extmark virtual lines when expanded via `za` or `:AlmaToggleBlock`,
so large tool payloads no longer inflate the markdown-like buffer. Use
`:AlmaToolDetails` for the full, untruncated payload.

Tool output rendering still uses a registry for expanded/detail views. Built-in
renderers format `Bash`, `Read`, `Edit`, `Write`, `Grep`, and `Glob` with
tool-specific code blocks, including standard ```diff blocks for editable
patches. Unknown tools fall back to raw Lua-style output.

```lua
require("alma").setup({
  render = {
    virtual_blocks = {
      default_expanded = false,
      max_lines = 80,
      max_width = 180,
    },
    tool_outputs = {
      mode = "smart", -- or "raw"
      fallback = "raw",
      renderers = {
        MyTool = function(block)
          return { "custom:", "```text", vim.inspect(block.output), "```" }
        end,
      },
    },
  },
})
```

## Reliability Contract

Submitting a request turns the bottom `## You` composer into the sent user
message and shows progress with the lightweight spinner until the response
streams or reconciles. If Alma is already generating for the same thread, the
request is queued in Neovim and the buffer shows that queued state.
Completion or error events force REST reconciliation through
`GET /api/threads/<id>/messages`.

If no related WebSocket event arrives before the ack timeout, the buffer shows
that the request was sent and starts REST polling fallback.

During streaming, the bottom `## You` composer is only anchored when it is
already visible; if the user is reading elsewhere, `alma.nvim` preserves that view
and does not steal the scroll position. A lightweight TUI loading bar is rendered
near the active response while generation is in progress.

## Verify

Run the local headless validation:

```bash
nvim --headless -u NONE -n -i NONE --cmd 'set rtp^=.' -l scripts/validate.lua
```

Run a manual API check:

```vim
:AlmaHealth
:Alma new
:Alma pick
:Alma open <thread_id>
:Alma sidebar <thread_id>
:AlmaThreadOpen <thread_id>
```
