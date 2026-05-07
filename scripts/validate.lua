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
local render = require("alma.ui.render")

local function save_view(win)
  return vim.api.nvim_win_call(win, function()
    return vim.fn.winsaveview()
  end)
end

local function restore_view(win, view)
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview(view)
  end)
end

local function assert_near_bottom(win, bufnr, label)
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local cursor = vim.api.nvim_win_get_cursor(win)
  local info = vim.fn.getwininfo(win)[1] or {}
  assert(line_count - cursor[1] <= 5, label .. " cursor follows bottom")
  assert(line_count - (info.botline or cursor[1]) <= 5, label .. " viewport follows bottom")
end

local function assert_cursor_in_composer(thread, win, label)
  local cursor = vim.api.nvim_win_get_cursor(win)
  assert(thread.prompt_start ~= nil, label .. " prompt start exists")
  assert(cursor[1] >= thread.prompt_start + 1, label .. " cursor stays in composer")
end

local function history_blocks(prefix, count)
  local blocks = {}
  for index = 1, count do
    table.insert(blocks, { type = "UserBlock", text = prefix .. " question " .. tostring(index) })
    table.insert(blocks, {
      type = "AssistantBlock",
      text = table.concat({
        prefix .. " answer " .. tostring(index),
        "detail line " .. tostring(index),
        "more detail " .. tostring(index),
      }, "\n"),
    })
  end
  return blocks
end

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
  "$model: test-model",
  "$reasoning:xhigh",
  "@Bash",
  ">diagnostics",
  "hello alma",
}, thread)

assert_eq(spec.prompt, "hello alma", "parser prompt")
assert_eq(spec.model, "test-model", "parser model")
assert_eq(spec.model_override, true, "parser model override")
assert_eq(spec.metadata.requestModel, "test-model", "parser request model metadata")
assert_eq(spec.reasoning_effort, "xhigh", "parser reasoning")
assert_eq(spec.metadata.reasoningEffort, "xhigh", "parser reasoning metadata")
assert_eq(spec.tools[1], "Bash", "parser tool")
assert_eq(spec.ephemeral_context[1].type, "diagnostics", "parser context")

local payload = parser.compile_request(thread, spec)
assert_eq(payload.type, "generate_response", "compiled payload type")
assert_eq(payload.data.threadId, "validate-thread", "compiled payload thread")
assert_eq(payload.data.userMessage.role, "user", "compiled user message role")
assert_eq(payload.data.userMessage.parts[1].type, "text", "compiled user message part type")
assert_eq(payload.data.userMessage.parts[1].text, "hello alma", "compiled user message text")
assert_eq(payload.data.model, "test-model", "compiled request model")
assert_eq(payload.data.ephemeralModel, "test-model", "compiled ephemeral model")
assert_eq(payload.data.userMessageMetadata.model, "test-model", "compiled model metadata")

local auto_thread = state.get_thread("validate-auto-thread", { cwd = root })
auto_thread.config.tools = "__auto__"
auto_thread.config.skills = "__auto_skill__"
local auto_spec = parser.parse_input({ "hello auto" }, auto_thread)
assert_eq(auto_spec.tools, "__auto__", "parser preserves auto tools sentinel")
assert_eq(auto_spec.skills, "__auto_skill__", "parser preserves auto skills sentinel")
local auto_payload = parser.compile_request(auto_thread, auto_spec)
assert_eq(auto_payload.data.tools, "__auto__", "compiled payload preserves auto tools sentinel")
assert_eq(auto_payload.data.skillIds, "__auto_skill__", "compiled payload preserves auto skills sentinel")
local explicit_spec = parser.parse_input({ "@Bash", "/skill:test-skill", "hello explicit" }, auto_thread)
assert_eq(explicit_spec.tools[1], "Bash", "explicit tool overrides auto tools sentinel")
assert_eq(explicit_spec.skills[1], "test-skill", "explicit skill overrides auto skills sentinel")

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
local subagent_delta = events.normalize_ws_event({
  type = "subagent_message_delta",
  data = {
    context = { threadId = "validate-thread" },
    deltas = {
      { threadId = "validate-thread", type = "text_append" },
    },
  },
})
assert_eq(subagent_delta.thread_id, "validate-thread", "subagent event context thread id")
assert_eq(subagent_delta.known, true, "subagent event known")
assert_eq(events.is_thread_scoped_event("subagent_message_delta"), true, "subagent event is thread scoped")
assert_eq(events.is_global_ws_event("subagent_message_delta"), false, "subagent event is not global")
assert_eq(events.is_global_ws_event("unknown_ws_event"), false, "unknown event is not global")
local subagent_delta_only = events.normalize_ws_event({
  type = "subagent_message_delta",
  data = {
    deltas = {
      { threadId = "validate-thread", type = "text_append" },
    },
  },
})
assert_eq(subagent_delta_only.thread_id, "validate-thread", "subagent event delta thread id")

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

local chronological_blocks = events.normalize_messages({
  {
    id = "validate-thread--user-1",
    message = {
      id = "user-1",
      role = "user",
      parts = { { type = "text", text = "question" } },
    },
    metadata = {
      original_text = "$model:test-model\n$reasoning:xhigh\nquestion",
      modelOverride = true,
      reasoningOverride = true,
    },
  },
  {
    id = "validate-thread--assistant-1",
    parentId = "validate-thread--user-1",
    message = {
      id = "m2",
      role = "assistant",
      parts = {
        { type = "step-start" },
        { type = "reasoning", text = "thinking first", state = "done" },
        { type = "text", text = "answer second" },
      },
    },
  },
})
assert_eq(chronological_blocks[1].type, "UserBlock", "chronological user block")
assert_eq(chronological_blocks[2].type, "AgentTimelineBlock", "chronological timeline block")
assert_eq(chronological_blocks[2].title, "step-start", "timeline fallback title")
assert_eq(chronological_blocks[2].request_model, "test-model", "timeline inherits request model")
assert_eq(chronological_blocks[3].type, "ReasoningBlock", "chronological reasoning block")
assert_eq(chronological_blocks[3].request_reasoning_effort, "xhigh", "reasoning inherits request effort")
assert_eq(chronological_blocks[4].type, "AssistantBlock", "chronological assistant block")
assert_eq(chronological_blocks[4].request_model, "test-model", "assistant inherits request model")

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
thread.pending_request = { spec = spec, payload = payload, created_at = 2 }
thread.streaming_text = nil
thread.streaming_reasoning_text = nil
local _, stream_effects = core.reduce_thread(thread, {
  type = "ws_event",
  name = "message_delta",
  known = true,
  data = {
    threadId = "validate-thread",
    deltas = {
      { type = "tool_input_append", text = "ignored tool text" },
      { type = "text_append", partType = "text", text = "stream" },
      { type = "text_append", partType = "text", text = "ing" },
      { type = "text_done", partType = "text" },
    },
  },
})
assert_eq(thread.streaming_text, "streaming", "message_delta array streams text chunks")
assert_eq(thread.local_blocks[2].type, "AssistantBlock", "message_delta text uses assistant block")
assert_eq(thread.local_blocks[2].text, "streaming", "message_delta array rebuilds streaming block")
assert_eq(stream_effects[2].type, "render", "message_delta renders streaming update")
thread.streaming_text = nil
thread.streaming_reasoning_text = nil
thread.local_blocks = {}
local _, reasoning_stream_effects = core.reduce_thread(thread, {
  type = "ws_event",
  name = "message_delta",
  known = true,
  data = {
    threadId = "validate-thread",
    deltas = {
      { type = "text_append", partType = "reasoning", text = "think" },
      { type = "text_append", partType = "reasoning", text = "ing" },
      { type = "text_append", partType = "text", text = "answer" },
    },
  },
})
assert_eq(thread.streaming_reasoning_text, "thinking", "message_delta array streams reasoning chunks")
assert_eq(thread.streaming_text, "answer", "message_delta array keeps answer chunks separate")
assert_eq(thread.local_blocks[2].type, "ReasoningBlock", "streaming reasoning uses reasoning block")
assert_eq(thread.local_blocks[2].text, "thinking", "streaming reasoning block has cot text")
assert_eq(thread.local_blocks[3].type, "AssistantBlock", "streaming answer remains assistant block")
assert_eq(thread.local_blocks[3].text, "answer", "streaming answer block has answer text")
assert_eq(reasoning_stream_effects[2].type, "render", "reasoning message_delta renders streaming update")
thread.pending_request = nil
thread.streaming_text = nil
thread.streaming_reasoning_text = nil
thread.local_blocks = {}
thread.generation = "idle"

local bufnr = vim.api.nvim_create_buf(false, true)
vim.api.nvim_set_current_buf(bufnr)
state.bind_buffer(thread, bufnr)
thread.blocks = {
  { type = "UserBlock", message_id = "u1", text = "sleep improved" },
}
for _, block in ipairs(chronological_blocks) do
  table.insert(thread.blocks, block)
end
thread.last_error = "curl: timed out\n"
render.render(thread)
assert(vim.api.nvim_buf_line_count(bufnr) > 5, "render produced lines")
local rendered_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local positions = {}
for index, line in ipairs(rendered_lines) do
  positions[line] = positions[line] or index
  assert(not line:find("\n", 1, true), "render line must not contain newline")
end
assert(positions["## You"] < positions["## Alma"], "user renders before assistant group")
assert(positions["## Alma"] < positions["### Agent Timeline: step-start"], "assistant heading wraps timeline")
assert(positions["### Agent Timeline: step-start"] < positions["### Reasoning [done]"], "timeline renders before reasoning")
assert(positions["### Reasoning [done]"] < positions["answer second"], "reasoning renders before assistant text")
assert_eq(rendered_lines[#rendered_lines - 1], "## You", "idle prompt uses user header")
local render_ns = vim.api.nvim_get_namespaces()["alma.nvim"]
local overlay_width_ok = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, render_ns, 0, -1, { details = true })) do
  local details = mark[4] or {}
  if details.virt_text_pos == "overlay" and details.virt_text then
    local text = ""
    for _, chunk in ipairs(details.virt_text) do
      text = text .. (chunk[1] or "")
    end
    overlay_width_ok = overlay_width_ok or vim.fn.strdisplaywidth(text) >= vim.o.columns
  end
end
assert(overlay_width_ok, "header overlay covers current window width")
local reasoning_line = positions["thinking first"]
assert(reasoning_line, "reasoning body line rendered")
local reasoning_text_ok = false
local reasoning_border_ok = false
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, render_ns, 0, -1, { details = true })) do
  local details = mark[4] or {}
  if mark[2] + 1 == reasoning_line then
    reasoning_text_ok = reasoning_text_ok or details.hl_group == "AlmaReasoningText"
    if details.virt_text_pos == "inline" and details.virt_text then
      for _, chunk in ipairs(details.virt_text) do
        reasoning_border_ok = reasoning_border_ok or chunk[2] == "AlmaReasoningBorder"
      end
    end
  end
end
assert(reasoning_text_ok, "reasoning body uses muted text highlight")
assert(reasoning_border_ok, "reasoning body uses inline border marker")
assert_eq(vim.bo[bufnr].modifiable, true, "idle chat buffer is editable")
thread.last_error = nil

local sticky_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(sticky_win, { thread.prompt_start + 1, 0 })
render.prepare_submit_follow(thread, sticky_win)
thread.pending_request = { spec = spec, payload = payload, created_at = 2 }
thread.generation = "submitted"
thread.streaming_text = nil
thread.blocks = {}
thread.local_blocks = {
  { type = "UserBlock", text = "Test", local_only = true },
  { type = "AssistantBlock", text = "⏳ Alma is thinking...", state = "loading", local_only = true },
}
render.render(thread)
local locked_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local you_positions = {}
local old_heading_count = 0
local loading_line
local alma_line
for index, line in ipairs(locked_lines) do
  if line == "## You" then
    table.insert(you_positions, index)
  elseif line == "## Alma" then
    alma_line = index
  elseif line == "⏳ Alma is thinking..." then
    loading_line = index
  end
  if line:match("^## You %[") or line:match("^## Alma %[") then
    old_heading_count = old_heading_count + 1
  end
end
local composer_line = you_positions[#you_positions]
assert_eq(#you_positions, 2, "submitted render keeps submitted user block and bottom composer")
assert_eq(locked_lines[#locked_lines - 1], "## You", "submitted render keeps bottom composer")
assert(alma_line and loading_line and alma_line < loading_line, "submitted assistant loading has Alma heading")
assert(loading_line and composer_line and loading_line < composer_line, "submitted assistant loading renders before composer")
assert_eq(old_heading_count, 0, "submitted render avoids legacy state headings")
assert_eq(vim.bo[bufnr].modifiable, true, "generating chat buffer remains editable")
assert_cursor_in_composer(thread, sticky_win, "sticky submitted render")
assert_near_bottom(sticky_win, bufnr, "sticky submitted render")

vim.api.nvim_buf_set_lines(bufnr, thread.prompt_start, -1, false, { "draft next request" })
thread.generation = "streaming"
thread.local_blocks = {
  { type = "UserBlock", text = "Test", local_only = true },
  { type = "ReasoningBlock", text = "thinking now", state = "streaming", local_only = true },
  { type = "AssistantBlock", text = "partial answer", state = "streaming", local_only = true },
}
render.render(thread)
local streaming_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local reasoning_pos
local answer_pos
local streaming_alma_pos
local streaming_composer_pos
for index, line in ipairs(streaming_lines) do
  if line == "## Alma" and not streaming_alma_pos then
    streaming_alma_pos = index
  elseif line == "### Reasoning [streaming]" then
    reasoning_pos = index
  elseif line == "partial answer" then
    answer_pos = index
  elseif line == "## You" then
    streaming_composer_pos = index
  end
end
assert(streaming_alma_pos and reasoning_pos and streaming_alma_pos < reasoning_pos, "streaming reasoning is inside Alma section")
assert(reasoning_pos and answer_pos and reasoning_pos < answer_pos, "streaming reasoning renders before answer")
assert(answer_pos and streaming_composer_pos and answer_pos < streaming_composer_pos, "streaming answer renders before composer")
assert_eq(
  vim.api.nvim_buf_get_lines(bufnr, thread.prompt_start, thread.prompt_start + 1, false)[1],
  "draft next request",
  "streaming render preserves composer draft"
)
assert_cursor_in_composer(thread, sticky_win, "sticky streaming render")
thread.pending_request = nil
thread.generation = "idle"
thread.local_blocks = {}
render.render(thread)
assert_eq(vim.bo[bufnr].modifiable, true, "completed chat buffer is editable")
assert(thread.prompt_start ~= nil, "completed render restores prompt")
assert_eq(vim.api.nvim_win_get_cursor(sticky_win)[1], thread.prompt_start + 1, "sticky completed render returns cursor to prompt")

thread.blocks = history_blocks("history", 18)
thread.pending_request = nil
thread.generation = "idle"
thread.local_blocks = {}
render.render(thread)
local history_line_count = vim.api.nvim_buf_line_count(bufnr)
restore_view(sticky_win, {
  lnum = history_line_count - 8,
  col = 0,
  curswant = 0,
  topline = math.max(1, history_line_count - vim.api.nvim_win_get_height(sticky_win) + 1),
  leftcol = 0,
  skipcol = 0,
})
render.on_user_view_changed(thread, sticky_win, "cursor")
assert_eq(thread.view_state[sticky_win].follow, false, "cursor jump above bottom suspends sticky")
restore_view(sticky_win, { lnum = 6, col = 0, curswant = 0, topline = 6, leftcol = 0, skipcol = 0 })
render.on_user_view_changed(thread, sticky_win, "cursor")
local history_view = save_view(sticky_win)
thread.pending_request = { spec = spec, payload = payload, created_at = 3 }
thread.generation = "streaming"
thread.local_blocks = {
  { type = "UserBlock", text = "follow-up", local_only = true },
  { type = "AssistantBlock", text = "streaming\nnew\ncontent", state = "streaming", local_only = true },
}
render.render(thread)
local restored_history_view = save_view(sticky_win)
assert_eq(restored_history_view.lnum, history_view.lnum, "non-sticky render preserves cursor")
assert_eq(restored_history_view.topline, history_view.topline, "non-sticky render preserves viewport")
vim.api.nvim_win_set_cursor(sticky_win, { vim.api.nvim_buf_line_count(bufnr), 0 })
render.on_user_view_changed(thread, sticky_win, "cursor")
thread.local_blocks[2].text = "streaming\nnew\ncontent\nresumed"
render.render(thread)
assert_near_bottom(sticky_win, bufnr, "sticky resumes after returning bottom")

local multi_thread = state.get_thread("validate-window-thread", { cwd = root })
local multi_bufnr = vim.api.nvim_create_buf(false, true)
state.bind_buffer(multi_thread, multi_bufnr)
multi_thread.blocks = history_blocks("multi", 18)
multi_thread.pending_request = nil
multi_thread.generation = "idle"
multi_thread.local_blocks = {}
vim.api.nvim_set_current_buf(multi_bufnr)
render.render(multi_thread)
local follow_win = vim.api.nvim_get_current_win()
vim.cmd("vsplit")
local history_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_buf(history_win, multi_bufnr)
local multi_line_count = vim.api.nvim_buf_line_count(multi_bufnr)
vim.api.nvim_win_set_cursor(follow_win, { multi_line_count, 0 })
render.on_user_view_changed(multi_thread, follow_win, "cursor")
restore_view(history_win, { lnum = 6, col = 0, curswant = 0, topline = 6, leftcol = 0, skipcol = 0 })
render.on_user_view_changed(multi_thread, history_win, "cursor")
local multi_history_view = save_view(history_win)
multi_thread.pending_request = { spec = spec, payload = payload, created_at = 4 }
multi_thread.generation = "streaming"
multi_thread.local_blocks = {
  { type = "UserBlock", text = "multi follow-up", local_only = true },
  { type = "AssistantBlock", text = "multi\nstream\ncontent", state = "streaming", local_only = true },
}
render.render(multi_thread)
assert_near_bottom(follow_win, multi_bufnr, "multi-window sticky render")
local multi_history_after = save_view(history_win)
assert_eq(multi_history_after.lnum, multi_history_view.lnum, "multi-window history cursor preserved")
assert_eq(multi_history_after.topline, multi_history_view.topline, "multi-window history viewport preserved")
pcall(vim.api.nvim_win_close, history_win, true)

print("alma.nvim validation OK")
vim.cmd("qa")
