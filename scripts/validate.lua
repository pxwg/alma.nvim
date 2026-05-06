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
local config = require("alma.config")

local expected_api_url = (vim.env.ALMA_API_URL or "http://127.0.0.1:23001"):gsub("/+$", "")
assert_eq(config.api_url(), expected_api_url, "default or env api url")
if not vim.env.ALMA_API_URL then
  assert_eq(config.ws_url(), "ws://127.0.0.1:23001/ws/threads", "default ws url")
end
config.setup({ notify = false, api_url = "http://localhost:23001/" })
assert_eq(config.api_url(), "http://localhost:23001", "setup api url override")
assert_eq(config.ws_url(), "ws://localhost:23001/ws/threads", "setup ws url override")
config.setup({ notify = false })

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
assert_eq(payload.data.userMessage.role, "user", "compiled user message role")
assert_eq(payload.data.userMessage.parts[1].type, "text", "compiled user message part type")
assert_eq(payload.data.userMessage.parts[1].text, "hello alma", "compiled user message text")

local normalized = events.normalize_ws_event({
  type = "text_delta",
  data = { threadId = "validate-thread", delta = "ok" },
})
assert_eq(normalized.thread_id, "validate-thread", "ws event thread id")
assert_eq(normalized.known, true, "ws event known")

local thread_generating = events.normalize_ws_event({
  type = "thread_generating",
  data = { id = "validate-thread", isGenerating = true },
})
assert_eq(thread_generating.thread_id, "validate-thread", "thread event data id")
local message_added = events.normalize_ws_event({
  type = "message_added",
  data = { id = "validate-thread--message-1" },
})
assert_eq(message_added.thread_id, "validate-thread", "message event composite id")

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

local nvim_user_blocks = events.normalize_messages({
  {
    id = "thread--user-1",
    message = { id = "user-1" },
    metadata = { original_text = "hello from nvim" },
  },
})
assert_eq(nvim_user_blocks[1].type, "UserBlock", "nvim user skeleton block")
assert_eq(nvim_user_blocks[1].text, "hello from nvim", "nvim user skeleton text")

local parsed = ws._test.parse_url("ws://localhost:23001/ws/threads")
assert_eq(parsed.host, "localhost", "ws url host")
assert_eq(parsed.port, 23001, "ws url port")

local original_new_tcp = vim.uv.new_tcp
local attempts = {}
local handles = {}
vim.uv.new_tcp = function()
  local handle = {}
  table.insert(handles, handle)
  function handle:connect(addr, port, callback)
    table.insert(attempts, { addr = addr, port = port })
    if addr == "::1" then
      callback("ECONNREFUSED")
    else
      callback(nil)
    end
  end
  function handle:close()
    self.closed = true
  end
  return handle
end

local retry_client = ws.new({ url = "ws://localhost:23001/ws/threads" })
retry_client.parsed = parsed
retry_client.status = "connecting"
retry_client.connect_id = {}
retry_client._start_read = function(self)
  self.started = true
end
retry_client._write_handshake = function(self)
  self.handshake_written = true
end

local ok, retry_err = pcall(function()
  retry_client:_connect_addresses({ { addr = "::1" }, { addr = "127.0.0.1" } }, 1, nil, retry_client.connect_id)
  assert_eq(#attempts, 2, "ws retry attempt count")
  assert_eq(attempts[1].addr, "::1", "ws retry first address")
  assert_eq(attempts[2].addr, "127.0.0.1", "ws retry second address")
  assert_eq(attempts[2].port, 23001, "ws retry port")
  assert_eq(handles[1].closed, true, "ws retry closes failed tcp")
  assert_eq(retry_client.started, true, "ws retry starts read")
  assert_eq(retry_client.handshake_written, true, "ws retry writes handshake")
end)
vim.uv.new_tcp = original_new_tcp
if not ok then
  error(retry_err)
end

local frame = ws._test.encode_frame("hello", 1)
local seen
ws._test.decode_frames(frame, function(decoded)
  seen = decoded.payload
end)
assert_eq(seen, "hello", "ws frame roundtrip")

thread.backend_generating = true
thread.generation = "idle"
thread.pending_request = nil
local _, effects = core.reduce_thread(thread, {
  type = "submit",
  request = { spec = spec, payload = payload, created_at = 1 },
})
assert_eq(#thread.queue, 1, "busy submit queues")
assert(#thread.local_blocks >= 2, "queued submit renders local blocks")
assert(effects[1].type == "notify" or effects[2].type == "notify", "queued submit notifies")
local has_rest_fetch_thread = false
for _, effect in ipairs(effects) do
  has_rest_fetch_thread = has_rest_fetch_thread or effect.type == "rest_fetch_thread"
end
assert(has_rest_fetch_thread, "stale backend queue verifies thread metadata")
local _, metadata_effects = core.reduce_thread(thread, {
  type = "rest_thread_loaded",
  thread = { id = "validate-thread", isGenerating = false },
})
assert_eq(thread.backend_generating, false, "rest metadata clears stale backend generation")
assert_eq(#thread.queue, 0, "rest metadata releases queued submit")
local has_dispatch = false
for _, effect in ipairs(metadata_effects) do
  has_dispatch = has_dispatch or effect.type == "dispatch"
end
assert(has_dispatch, "rest metadata dispatches released queue")
thread.backend_generating = false
thread.queue = {}
thread.local_blocks = {}
thread.generation = "idle"

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
state.bind_buffer(thread, bufnr)
thread.blocks = blocks
thread.last_error = "curl: timed out\n"
require("alma.ui.render").render(thread)
assert(vim.api.nvim_buf_line_count(bufnr) > 5, "render produced lines")
for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
  assert(not line:find("\n", 1, true), "render line must not contain newline")
end
thread.last_error = nil

print("alma.nvim validation OK")
vim.cmd("qa")
