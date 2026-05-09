# Blackboard Events and Context Attachments Spec

Status: draft task spec
Date: 2026-05-09
Scope: `alma.nvim` only

## Positioning

`alma.nvim` remains a generic Neovim frontend for Alma. It must not contain ZK, Typst, wiki, or user-specific workspace semantics.

This spec adds generic extension points so downstream Neovim configuration can build blackboard/review workflows on top of Alma without forking the plugin.

## Existing State

- One Alma thread maps to one Neovim buffer.
- Requests currently flow through `buffers.submit_current()` -> `parser.parse_input()` -> `parser.compile_request()` -> `effects.dispatch()`.
- `spec.ephemeral_context` already exists and is serialized as `payload.data.ephemeralContext`.
- Token context such as `>buffer`, `>selection`, `>diagnostics`, `>diff`, and `>file:<path>` already flows into `spec.ephemeral_context`.
- UI currently shows compact request metadata/context count, while detailed payloads belong in detail views.

## Goals

1. Expose stable generic lifecycle events around thread, request, response, and proposal handling.
2. Provide a generic context attachment API that can inject JSON/file/buffer context into the next request without polluting the prompt text.
3. Allow configuration layers to mutate `spec.ephemeral_context` and request metadata before request compilation.
4. Allow external layers to receive generic proposal/diff payloads and render their own review UI.
5. Keep all user-specific workflows outside `alma.nvim`.

## Non-goals

- No ZK workspace registry.
- No Typst note semantics.
- No hardcoded `zk-lsp` calls.
- No blackboard state machine in the plugin core.
- No direct file modification policy beyond existing generic Alma behavior.
- No dependency on MCP for this workflow.

## Proposed Public API

### Hook registry

Add a module such as `lua/alma/hooks.lua`:

```lua
local alma_hooks = require("alma.hooks")

alma_hooks.register("before_submit", function(ctx)
  -- ctx.thread
  -- ctx.spec
  -- ctx.lines
  -- mutate ctx.spec.ephemeral_context or ctx.spec.metadata
end)
```

Required hook names:

- `thread_opened`
- `thread_changed`
- `before_submit`
- `request_compiled`
- `after_submit`
- `generation_completed`
- `generation_error`
- `proposal_received`

Hook callbacks should run through `pcall`; one failing hook must not corrupt the thread state. Failures should notify via existing `util.notify` patterns.

### User autocmd mirror

For integration with normal Neovim config, each hook should also emit a `User` autocmd:

- `User AlmaThreadOpened`
- `User AlmaThreadChanged`
- `User AlmaBeforeSubmit`
- `User AlmaRequestCompiled`
- `User AlmaAfterSubmit`
- `User AlmaGenerationCompleted`
- `User AlmaGenerationError`
- `User AlmaProposalReceived`

Autocmd payload should be placed in `vim.g.alma_event` or an equivalent documented handoff object if `nvim_exec_autocmds(..., { data = ... })` is not enough for target Neovim versions.

### Context attachment registry

Add a module such as `lua/alma/context.lua`:

```lua
require("alma.context").attach(thread_id, {
  id = "review-context:p12",
  title = "Review feedback from Proposal #12",
  kind = "application/json",
  path = "/absolute/path/to/review-context.json",
  once = true,
  visibility = "compact",
})
```

Attachment fields:

- `id`: stable dedupe key.
- `title`: compact UI label.
- `kind`: MIME-like type, usually `application/json`.
- `path`: absolute file path, if the content lives in a file.
- `content`: optional inline string/table content for small payloads.
- `once`: consume after the next successful submit.
- `visibility`: `compact`, `hidden`, or `detail`.
- `metadata`: optional generic metadata table.

Compilation behavior:

- Attachments are appended to `spec.ephemeral_context` before `compile_request()`.
- File attachments should become a generic context object such as `{ type = "file", path = ... }` plus metadata if supported.
- Inline JSON attachments should become a generic context object such as `{ type = "json", title = ..., content = ... }` if Alma backend accepts it; otherwise they should fall back to a temporary file context.
- Prompt text must remain unchanged.

UI behavior:

- Composer/user block shows compact chips such as `Review feedback · 3 comments`.
- Raw JSON is not inserted into the chat buffer.
- Full attachment details belong in a detail buffer command, not inline streaming text.

## Generic Proposal Event

`alma.nvim` should normalize proposal-like events without assuming their source.

Suggested shape:

```lua
{
  id = "proposal-id",
  thread_id = "thread-id",
  kind = "diff",
  title = "Proposal title",
  base_snapshot_id = "optional-base-id",
  files = {
    {
      path = "/absolute/path",
      relative_path = "note/x.typ",
      diff = "unified diff text",
      hunks = {},
    },
  },
  raw = {},
}
```

The plugin only emits `proposal_received`; downstream config decides how to render, approve, reject, comment, or apply.

## Implementation Tasks

1. Add `alma.hooks` with ordered hook registration, safe dispatch, and clear error handling.
2. Emit hook/autocmd events from the current request and thread lifecycle points.
3. Add `alma.context` attachment registry keyed by thread id.
4. Merge pending attachments into `spec.ephemeral_context` before request compilation.
5. Render compact attachment labels in the user/request metadata area.
6. Add detail command support for inspecting request attachments.
7. Normalize proposal-like events only far enough to emit generic data.
8. Document the API in `README.md` and `doc/alma.txt` after implementation.
9. Add focused headless validation in `scripts/validate.lua`.

## Acceptance Criteria

- A Neovim config callback can attach a JSON file to the next request without changing prompt text.
- The resulting request contains the attachment in `ephemeralContext` or an equivalent backend-supported context field.
- The user block shows compact attachment metadata, not raw JSON.
- Attachments marked `once = true` are consumed after submit and are not duplicated on later requests.
- Hook failures are reported but do not break chat submission.
- No ZK-specific string, command, path convention, or dependency is introduced.
- Existing model/reasoning/tool/skill token behavior remains compatible.
- `nvim --headless -u NONE -n -i NONE --cmd 'set rtp^=.' -l scripts/validate.lua` passes after implementation.

## Open Questions

- Which backend `ephemeralContext` object shapes are currently accepted for JSON attachments?
- Should context-only requests be allowed when prompt text is empty but attachments are present?
- Should proposal events be sourced only from Alma WebSocket events, or can local integrations call the hook directly?
