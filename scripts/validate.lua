local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local function assert_eq(actual, expected, label)
  if actual ~= expected then
    error(string.format("%s: expected %s, got %s", label, vim.inspect(expected), vim.inspect(actual)))
  end
end

require("alma").setup({ notify = false })

local parser = require("alma.parser")
local core = require("alma.core")
local events = require("alma.events")
local state = require("alma.state")
local ws = require("alma.ws")

local thread = state.get_thread("validate-thread", { cwd = root })
local spec = parser.parse_input({
  "$model:test-model",
  "$reasoning:xhigh",
  "@Bash",
  ">diagnostics",
  "hello alma",
}, thread)

assert_eq(spec.prompt, "hello alma", "parser prompt")
assert_eq(spec.model, "test-model", "parser model")
assert_eq(spec.reasoning_effort, "xhigh", "parser reasoning")
assert_eq(spec.tools[1], "Bash", "parser tool")
assert_eq(spec.ephemeral_context[1].type, "diagnostics", "parser context")

local payload = parser.compile_request(thread, spec)
assert_eq(payload.type, "generate_response", "compiled payload type")
assert_eq(payload.data.threadId, "validate-thread", "compiled payload thread")

local normalized = events.normalize_ws_event({
  type = "text_delta",
  data = { threadId = "validate-thread", delta = "ok" },
})
assert_eq(normalized.thread_id, "validate-thread", "ws event thread id")
assert_eq(normalized.known, true, "ws event known")

local blocks = events.normalize_messages({
  {
    message = {
      id = "m1",
      role = "assistant",
      parts = {
        { type = "text", text = "answer" },
        { type = "reasoning", text = "thinking" },
        { type = "tool-Bash", state = "output-available", input = { command = "pwd" }, output = "x.lua:1:1: ok" },
      },
    },
  },
})
assert_eq(blocks[1].type, "AssistantBlock", "message text block")
assert_eq(blocks[2].type, "ReasoningBlock", "message reasoning block")
assert_eq(blocks[3].type, "ToolCallBlock", "message tool block")

local parsed = ws._test.parse_url("ws://localhost:23001/ws/threads")
assert_eq(parsed.host, "localhost", "ws url host")
assert_eq(parsed.port, 23001, "ws url port")

local frame = ws._test.encode_frame("hello", 1)
local seen
ws._test.decode_frames(frame, function(decoded)
  seen = decoded.payload
end)
assert_eq(seen, "hello", "ws frame roundtrip")

thread.backend_generating = true
local _, effects = core.reduce_thread(thread, {
  type = "submit",
  request = { spec = spec, payload = payload, created_at = 1 },
})
assert_eq(#thread.queue, 1, "busy submit queues")
assert(#thread.local_blocks >= 2, "queued submit renders local blocks")
assert(effects[1].type == "notify" or effects[2].type == "notify", "queued submit notifies")
thread.backend_generating = false
thread.queue = {}
thread.local_blocks = {}

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
state.bind_buffer(thread, bufnr)
thread.blocks = blocks
require("alma.ui.render").render(thread)
assert(vim.api.nvim_buf_line_count(bufnr) > 5, "render produced lines")

print("alma.nvim validation OK")
vim.cmd("qa")
