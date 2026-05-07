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
local request_metadata = require("alma.ui.metadata")
local tokens = require("alma.ui.tokens")

local function thread_visible_windows(test_thread)
  local wins = {}
  if not test_thread or not test_thread.bufnr or not vim.api.nvim_buf_is_valid(test_thread.bufnr) then
    return wins
  end
  for _, win in ipairs(vim.fn.win_findbuf(test_thread.bufnr)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == test_thread.bufnr then
      table.insert(wins, win)
    end
  end
  return wins
end

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

local function assert_bottom_composer(thread, win, label)
  assert(thread and thread.bufnr and vim.api.nvim_buf_is_valid(thread.bufnr), label .. " thread buffer exists")
  assert(vim.api.nvim_win_is_valid(win), label .. " window exists")
  assert_eq(vim.api.nvim_win_get_buf(win), thread.bufnr, label .. " window shows thread buffer")
  assert(thread.prompt_start ~= nil, label .. " prompt start exists")
  local lines = vim.api.nvim_buf_get_lines(thread.bufnr, 0, -1, false)
  assert_eq(lines[thread.prompt_start], config.get().render.prompt_marker, label .. " bottom composer marker")
  assert_cursor_in_composer(thread, win, label)
end

local function has_label(items, label)
  for _, item in ipairs(items or {}) do
    if item.label == label then
      return true
    end
  end
  return false
end

local valid_composer_hl = {
  AlmaComposerCommand = true,
  AlmaComposerMention = true,
  AlmaComposerSelector = true,
}

local stream_decoration_hl = {
  AlmaStreamRaw = true,
  AlmaStreamSubAgent = true,
  AlmaStreamTimeline = true,
  AlmaStreamTool = true,
}

local function composer_token_marks(bufnr, namespace)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if valid_composer_hl[details.hl_group] and details.end_col then
      local line = lines[mark[2] + 1] or ""
      local token = line:sub(mark[3] + 1, details.end_col)
      out[token] = out[token] or {}
      table.insert(out[token], {
        line = mark[2] + 1,
        col = mark[3],
        end_col = details.end_col,
        hl_group = details.hl_group,
      })
    end
  end
  return out
end

local function stream_decoration_marks(bufnr, namespace)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if details.virt_text_pos == "inline" and details.virt_text then
      for _, chunk in ipairs(details.virt_text) do
        if stream_decoration_hl[chunk[2]] then
          local lnum = mark[2] + 1
          out[lnum] = out[lnum] or {}
          table.insert(out[lnum], {
            marker = chunk[1],
            hl_group = chunk[2],
          })
        end
      end
    end
  end
  return out
end

local function header_overlay_text(bufnr, namespace, line)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if mark[2] + 1 == line and details.virt_text_pos == "overlay" and details.virt_text then
      local text = ""
      for _, chunk in ipairs(details.virt_text) do
        text = text .. (chunk[1] or "")
      end
      return text
    end
  end
  return ""
end

local function assert_header_contains(bufnr, namespace, line, needle, label)
  local text = header_overlay_text(bufnr, namespace, line)
  if not text:find(needle, 1, true) then
    error(label .. ": expected header to contain " .. vim.inspect(needle) .. ", got " .. vim.inspect(text))
  end
end

local function assert_header_not_contains(bufnr, namespace, line, needle, label)
  local text = header_overlay_text(bufnr, namespace, line)
  if text:find(needle, 1, true) then
    error(label .. ": unexpected header text " .. vim.inspect(needle) .. " in " .. vim.inspect(text))
  end
end

local function lines_for_block(test_thread, block)
  local lines = {}
  for lnum, indexed_block in pairs(test_thread.render_index or {}) do
    if indexed_block == block then
      table.insert(lines, lnum)
    end
  end
  table.sort(lines)
  return lines
end

local function assert_stream_decoration(test_thread, marks, block, hl_group, label)
  for _, lnum in ipairs(lines_for_block(test_thread, block)) do
    for _, mark in ipairs(marks[lnum] or {}) do
      if mark.hl_group == hl_group then
        return
      end
    end
  end
  error(label .. ": expected " .. hl_group .. " stream decoration, got " .. vim.inspect(lines_for_block(test_thread, block)))
end

local function assert_no_stream_decoration(test_thread, marks, block, label)
  for _, lnum in ipairs(lines_for_block(test_thread, block)) do
    if marks[lnum] then
      error(label .. ": unexpected stream decoration on line " .. tostring(lnum) .. ": " .. vim.inspect(marks[lnum]))
    end
  end
end

local function assert_token_mark(marks, token, hl_group, min_line, label)
  for _, mark in ipairs(marks[token] or {}) do
    if mark.hl_group == hl_group and mark.line >= min_line then
      return
    end
  end
  error(label .. ": expected " .. token .. " with " .. hl_group .. ", got " .. vim.inspect(marks[token]))
end

local function assert_no_token_mark(marks, token, label)
  if marks[token] then
    error(label .. ": unexpected valid-token mark for " .. token .. ": " .. vim.inspect(marks[token]))
  end
end

local function assert_no_composer_marks_before(bufnr, namespace, first_line, label)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if valid_composer_hl[details.hl_group] and mark[2] + 1 < first_line then
      error(label .. ": unexpected composer token mark before prompt: " .. vim.inspect(mark))
    end
  end
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

local slash_new = tokens.classify("/new")
assert(has_label(tokens.static_for_trigger("/"), "/new"), "token static slash includes /new")
assert(has_label(tokens.static_for_trigger("/"), "/stop"), "token static slash includes /stop")
assert(has_label(tokens.static_for_trigger("/"), "/rename"), "token static slash includes /rename")
assert(has_label(tokens.static_for_trigger("/"), "/skill:<id>"), "token static slash includes /skill:<id>")
assert_eq(slash_new.valid, true, "token slash new valid")
assert_eq(slash_new.command, "new", "token slash new command")
assert_eq(tokens.classify("/stop").command, "stop", "token slash stop command")
assert_eq(tokens.classify("/rename").command, "rename", "token slash rename command")
assert_eq(tokens.classify("/skill:lint").kind, "skill", "token skill selector valid")
assert_eq(tokens.classify("/unknown").valid, false, "token invalid slash rejected")

local model_selector = tokens.classify("$model:gpt-test")
assert(has_label(tokens.static_for_trigger("$"), "$model:<id>"), "token static dollar includes model selector")
assert(has_label(tokens.static_for_trigger("$"), "$reasoning:xhigh"), "token static dollar includes reasoning selector")
assert(has_label(tokens.static_for_trigger("$"), "$temp:<n>"), "token static dollar includes temp selector")
assert(has_label(tokens.static_for_trigger("$"), "$no-tools"), "token static dollar includes no-tools selector")
assert_eq(model_selector.valid, true, "token model selector valid")
assert_eq(model_selector.value, "gpt-test", "token model selector value")
assert_eq(tokens.classify("$reasoning:xhigh").value, "xhigh", "token reasoning selector value")
assert_eq(tokens.classify("$temp:0.25").value, 0.25, "token temp selector value")
assert_eq(tokens.classify("$no-tools").selector, "no_tools", "token no-tools selector valid")
assert_eq(tokens.classify("$temp:not-a-number").valid, false, "token invalid temp rejected")

assert_eq(tokens.classify("@ConfiguredTool", { tools = { "ConfiguredTool" } }).valid, true, "token configured tool valid")
assert_eq(tokens.classify("@OtherTool", { tools = { "ConfiguredTool" } }).valid, false, "token unknown configured tool rejected")
assert_eq(tokens.classify("@FallbackTool", { tools = {} }).valid, true, "token fallback tool valid without catalog data")
assert_eq(tokens.classify("@mcp:server-one", { mcp_servers = { "server-one" } }).valid, true, "token configured mcp valid")
assert_eq(tokens.classify("@mcp:server-two", { mcp_servers = { "server-one" } }).valid, false, "token unknown configured mcp rejected")
assert_eq(tokens.classify("@group:default").valid, true, "token group form valid")
assert_eq(tokens.classify("@group:").valid, false, "token empty group rejected")

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
local current_request_metadata = request_metadata.from_request({ spec = spec, payload = payload })
assert_eq(current_request_metadata.model, "test-model", "metadata helper current request model")
assert_eq(current_request_metadata.reasoning_effort, "xhigh", "metadata helper current request reasoning")
local block_request_metadata = request_metadata.from_block({
  metadata = { requestModel = "block-model", reasoningEffort = "high" },
})
assert_eq(block_request_metadata.model, "block-model", "metadata helper block metadata model")
assert_eq(block_request_metadata.reasoning_effort, "high", "metadata helper block metadata reasoning")
local message_request_metadata = request_metadata.from_message({
  message = {
    metadata = {
      originalText = "$model:message-model\n$reasoning:medium\nhello",
      modelOverride = true,
      reasoningOverride = true,
    },
  },
})
assert_eq(message_request_metadata.model, "message-model", "metadata helper message original model")
assert_eq(message_request_metadata.reasoning_effort, "medium", "metadata helper message original reasoning")
local legacy_override_metadata = request_metadata.from_metadata({
  model = "thread-default-model",
  reasoningEffort = "low",
  originalText = "$model:legacy-request-model\n$reasoning:high\nhello",
  modelOverride = true,
  reasoningOverride = true,
})
assert_eq(legacy_override_metadata.model, "legacy-request-model", "metadata helper selector model overrides generic model")
assert_eq(
  legacy_override_metadata.reasoning_effort,
  "high",
  "metadata helper selector reasoning overrides generic reasoning"
)
local no_request_metadata = request_metadata.resolve({ config = { model = "thread-default", reasoning_effort = "low" } }, {})
assert_eq(no_request_metadata, nil, "metadata helper does not fabricate thread defaults")
local pending_metadata_thread = { pending_request = { spec = { model = "pending-model", reasoning_effort = "low" } } }
local historical_labels = request_metadata.assistant_labels(pending_metadata_thread, { type = "AssistantBlock" })
assert_eq(#historical_labels, 0, "metadata helper does not apply pending request to historical block")
local local_labels = request_metadata.assistant_labels(
  pending_metadata_thread,
  { type = "AssistantBlock", local_only = true },
  pending_metadata_thread.pending_request
)
assert_eq(local_labels[1], "pending-model", "metadata helper applies pending request to local block")
local formatted_request_labels = request_metadata.request_labels({
  model = "provider:gpt-formatted",
  reasoning_effort = "high",
})
assert_eq(formatted_request_labels[1], "gpt-formatted", "metadata formatter shortens model label")
assert_eq(formatted_request_labels[2], "effort high", "metadata formatter reasoning label")
local composer_option_labels = request_metadata.composer_labels({
  config = { model = "thread-option-model", reasoning_effort = "medium" },
})
assert_eq(composer_option_labels[1], "thread-option-model", "metadata composer labels use thread model")
assert_eq(composer_option_labels[2], "effort medium", "metadata composer labels use thread reasoning")
assert_eq(request_metadata.context_label({ context_usage = {} }), nil, "metadata helper does not fabricate context label")
assert_eq(
  request_metadata.context_label({ context_usage = { remainingTokens = 2048 } }),
  "ctx remaining 2048",
  "metadata helper uses real context remaining"
)
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
assert_eq(auto_payload.data.tools, nil, "compiled payload omits auto tools sentinel")
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
local context_compaction_started = events.normalize_ws_event({
  type = "context_compaction_started",
  data = { threadId = "validate-thread", messageCount = 41 },
})
assert_eq(context_compaction_started.thread_id, "validate-thread", "context compaction event thread id")
assert_eq(context_compaction_started.known, true, "context compaction event known")
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

local deepseek_blocks = events.normalize_messages({
  {
    id = "deepseek-thread--user-1",
    message = {
      id = "deepseek-user-1",
      role = "user",
      parts = { { type = "text", text = "question" } },
    },
    metadata = {
      original_text = "$model:deepseek-v4-pro\nquestion",
      modelOverride = true,
    },
  },
  {
    id = "deepseek-thread--assistant-1",
    parentId = "deepseek-thread--user-1",
    message = {
      id = "deepseek-assistant-1",
      role = "assistant",
      parts = { { type = "text", text = "answer" } },
    },
  },
})
assert_eq(deepseek_blocks[1].type, "UserBlock", "deepseek request user block")
assert_eq(
  deepseek_blocks[1].metadata.original_text,
  "$model:deepseek-v4-pro\nquestion",
  "deepseek model selector remains in user metadata"
)
assert_eq(deepseek_blocks[1].request_model, "deepseek-v4-pro", "deepseek user request model metadata")
assert_eq(deepseek_blocks[2].request_model, "deepseek-v4-pro", "deepseek assistant inherits parent model")

local chained_metadata_blocks = events.normalize_messages({
  {
    id = "chain-thread--user-1",
    message = {
      id = "chain-user-1",
      role = "user",
      parts = { { type = "text", text = "question" } },
    },
    metadata = {
      original_text = "$model:chain-parent-model\n$reasoning:high\nquestion",
      modelOverride = true,
      reasoningOverride = true,
    },
  },
  {
    id = "chain-thread--assistant-1",
    parentId = "chain-thread--user-1",
    message = {
      id = "chain-assistant-1",
      role = "assistant",
      parts = { { type = "text", text = "intermediate answer" } },
    },
  },
  {
    id = "chain-thread--assistant-2",
    parentId = "chain-thread--assistant-1",
    message = {
      id = "chain-assistant-2",
      role = "assistant",
      parts = { { type = "text", text = "follow-up answer" } },
    },
  },
})
assert_eq(chained_metadata_blocks[2].request_model, "chain-parent-model", "first assistant inherits parent model")
assert_eq(
  chained_metadata_blocks[3].request_model,
  "chain-parent-model",
  "assistant inherits request model through assistant parent chain"
)
assert_eq(
  chained_metadata_blocks[3].request_reasoning_effort,
  "high",
  "assistant inherits request reasoning through assistant parent chain"
)

local direct_assistant_metadata_blocks = events.normalize_messages({
  {
    id = "direct-thread--user-1",
    message = {
      id = "direct-user-1",
      role = "user",
      parts = { { type = "text", text = "question" } },
    },
    metadata = {
      original_text = "$model:direct-parent-model\n$reasoning:medium\nquestion",
      modelOverride = true,
      reasoningOverride = true,
    },
  },
  {
    id = "direct-thread--assistant-1",
    parentId = "direct-thread--user-1",
    message = {
      id = "direct-assistant-1",
      role = "assistant",
      metadata = {
        requestModel = "direct-assistant-model",
        reasoningEffort = "low",
      },
      parts = { { type = "text", text = "answer" } },
    },
  },
})
assert_eq(
  direct_assistant_metadata_blocks[2].request_model,
  "direct-assistant-model",
  "assistant direct metadata overrides inherited parent model"
)
assert_eq(
  direct_assistant_metadata_blocks[2].request_reasoning_effort,
  "low",
  "assistant direct metadata overrides inherited parent reasoning"
)

local subagent_metadata_blocks = events.normalize_messages({
  {
    message = {
      id = "m-subagent",
      role = "assistant",
      metadata = { subAgentId = "researcher" },
      parts = { { type = "text", text = "delegated normalized output" } },
    },
  },
})
assert_eq(subagent_metadata_blocks[1].type, "AssistantBlock", "subagent metadata message normalizes as assistant")
assert_eq(
  subagent_metadata_blocks[1].metadata.subAgentId,
  "researcher",
  "subagent metadata is preserved for renderer"
)

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
assert_eq(thread.local_blocks[1].metadata.requestModel, "test-model", "queued user block stores request model metadata")
assert_eq(thread.local_blocks[2].request_model, "test-model", "queued assistant block inherits request model")
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

local persisted_stream_user = {
  id = "validate-thread--user-stream",
  message = {
    id = "user-stream",
    role = "user",
    parts = { { type = "text", text = spec.prompt } },
  },
  metadata = spec.metadata,
}
local persisted_stream_assistant = {
  id = "validate-thread--assistant-stream",
  parentId = "validate-thread--user-stream",
  message = {
    id = "assistant-stream",
    role = "assistant",
    parts = {
      { type = "step-start" },
      { type = "reasoning", text = "persisted thinking", state = "done" },
      { type = "text", text = "persisted answer" },
    },
  },
}
thread.backend_generating = true
thread.generation = "streaming"
thread.pending_request = { spec = spec, payload = payload, created_at = 3 }
thread.streaming_text = "local duplicate"
thread.streaming_reasoning_text = nil
thread.local_blocks = {}
core.reduce_thread(thread, {
  type = "rest_messages_loaded",
  messages = { persisted_stream_user },
})
assert_eq(#thread.local_blocks, 1, "persisted user alone keeps local stream visible")
assert_eq(thread.local_blocks[1].type, "AssistantBlock", "persisted user local stream uses assistant block")
assert_eq(thread.local_blocks[1].text, "local duplicate", "persisted user keeps local stream text")
thread.streaming_text = "local duplicate"
thread.streaming_reasoning_text = "local thinking"
core.reduce_thread(thread, {
  type = "rest_messages_loaded",
  messages = { persisted_stream_user, persisted_stream_assistant },
})
assert_eq(thread.streaming_text, nil, "persisted assistant clears local stream text")
assert_eq(thread.streaming_reasoning_text, nil, "persisted assistant clears local reasoning stream")
assert_eq(#thread.local_blocks, 0, "persisted assistant suppresses duplicate local blocks")
core.reduce_thread(thread, {
  type = "ws_event",
  name = "message_delta",
  known = true,
  data = {
    threadId = "validate-thread",
    deltas = { { type = "text_append", partType = "text", text = "late local duplicate" } },
  },
})
assert_eq(thread.streaming_text, nil, "persisted assistant suppresses late local deltas")
assert_eq(#thread.local_blocks, 0, "late local delta does not recreate duplicate assistant block")
thread.backend_generating = false
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
assert_header_contains(bufnr, render_ns, positions["## Alma"], "test-model", "historical assistant header model")
assert_header_contains(bufnr, render_ns, positions["## Alma"], "effort xhigh", "historical assistant header reasoning")
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

local header_thread = state.get_thread("validate-header-metadata-thread", {
  cwd = root,
  model = "composer-thread-model",
  reasoning_effort = "medium",
})
local header_bufnr = vim.api.nvim_create_buf(false, true)
state.bind_buffer(header_thread, header_bufnr)
header_thread.blocks = {}
header_thread.local_blocks = {}
header_thread.pending_request = nil
header_thread.context_usage = {}
header_thread.generation = "idle"
render.render(header_thread)
assert_header_contains(
  header_bufnr,
  render_ns,
  header_thread.prompt_start,
  "composer-thread-model",
  "composer header thread model"
)
assert_header_contains(header_bufnr, render_ns, header_thread.prompt_start, "effort medium", "composer header thread reasoning")
assert_header_not_contains(header_bufnr, render_ns, header_thread.prompt_start, "ctx", "composer header no fabricated ctx")
assert_header_not_contains(
  header_bufnr,
  render_ns,
  header_thread.prompt_start,
  "remaining",
  "composer header no fabricated context remaining"
)
header_thread.pending_request = {
  spec = {
    model = "composer-request-model",
    reasoning_effort = "xhigh",
    metadata = {
      requestModel = "composer-request-model",
      reasoningEffort = "xhigh",
    },
  },
}
render.render(header_thread)
assert_header_contains(
  header_bufnr,
  render_ns,
  header_thread.prompt_start,
  "composer-request-model",
  "composer header pending request model"
)
assert_header_contains(header_bufnr, render_ns, header_thread.prompt_start, "effort xhigh", "composer header pending reasoning")
header_thread.context_usage = { remainingTokens = 321 }
render.render(header_thread)
assert_header_contains(
  header_bufnr,
  render_ns,
  header_thread.prompt_start,
  "ctx remaining 321",
  "composer header real context remaining"
)

local stream_thread = state.get_thread("validate-stream-decoration-thread", { cwd = root })
local stream_bufnr = vim.api.nvim_create_buf(false, true)
state.bind_buffer(stream_thread, stream_bufnr)
local primary_assistant_block = {
  type = "AssistantBlock",
  message_id = "stream-primary",
  text = "ordinary primary answer",
}
local tool_decoration_block = {
  type = "ToolCallBlock",
  message_id = "stream-primary",
  tool = "Bash",
  state = "output-available",
  output = "tool output body",
}
local timeline_decoration_block = {
  type = "AgentTimelineBlock",
  message_id = "stream-primary",
  title = "step-start",
  text = "timeline event body",
}
local raw_decoration_block = {
  type = "RawEventBlock",
  message_id = "stream-primary",
  title = "unhandled",
  raw = { type = "unknown_event", data = { value = 1 } },
}
local subagent_metadata_block = {
  type = "AssistantBlock",
  message_id = "stream-subagent-meta",
  metadata = { subAgentId = "researcher" },
  text = "delegated worker output",
}
local subagent_event_block = {
  type = "AssistantBlock",
  message_id = "stream-subagent-event",
  event_type = "subagent_message_delta",
  text = "delegated event output",
}
stream_thread.blocks = {
  primary_assistant_block,
  tool_decoration_block,
  timeline_decoration_block,
  raw_decoration_block,
  subagent_metadata_block,
  subagent_event_block,
}
stream_thread.local_blocks = {}
stream_thread.pending_request = nil
stream_thread.generation = "idle"
render.render(stream_thread)
local stream_marks = stream_decoration_marks(stream_bufnr, render_ns)
assert_stream_decoration(stream_thread, stream_marks, tool_decoration_block, "AlmaStreamTool", "tool block gutter")
assert_stream_decoration(
  stream_thread,
  stream_marks,
  timeline_decoration_block,
  "AlmaStreamTimeline",
  "timeline block gutter"
)
assert_stream_decoration(stream_thread, stream_marks, raw_decoration_block, "AlmaStreamRaw", "raw event block gutter")
assert_stream_decoration(
  stream_thread,
  stream_marks,
  subagent_metadata_block,
  "AlmaStreamSubAgent",
  "subagent metadata block gutter"
)
assert_stream_decoration(
  stream_thread,
  stream_marks,
  subagent_event_block,
  "AlmaStreamSubAgent",
  "subagent event block gutter"
)
assert_no_stream_decoration(stream_thread, stream_marks, primary_assistant_block, "primary assistant gutter")
local persisted_stream_lines = vim.api.nvim_buf_get_lines(stream_bufnr, 0, -1, false)
for _, line in ipairs(persisted_stream_lines) do
  assert(not line:find("▌", 1, true), "tool gutter marker is virtual only")
  assert(not line:find("▎", 1, true), "timeline gutter marker is virtual only")
  assert(not line:find("╎", 1, true), "raw-event gutter marker is virtual only")
  assert(not line:find("▸", 1, true), "subagent gutter marker is virtual only")
end

local command_hl = vim.api.nvim_get_hl(0, { name = "AlmaComposerCommand", link = true })
local mention_hl = vim.api.nvim_get_hl(0, { name = "AlmaComposerMention", link = true })
local selector_hl = vim.api.nvim_get_hl(0, { name = "AlmaComposerSelector", link = true })
assert(command_hl and next(command_hl) ~= nil, "composer command highlight is defined")
assert(mention_hl and next(mention_hl) ~= nil, "composer mention highlight is defined")
assert(selector_hl and next(selector_hl) ~= nil, "composer selector highlight is defined")
assert(next(vim.api.nvim_get_hl(0, { name = "AlmaStreamTool", link = true })) ~= nil, "tool stream highlight is defined")
assert(
  next(vim.api.nvim_get_hl(0, { name = "AlmaStreamTimeline", link = true })) ~= nil,
  "timeline stream highlight is defined"
)
assert(next(vim.api.nvim_get_hl(0, { name = "AlmaStreamRaw", link = true })) ~= nil, "raw stream highlight is defined")
assert(
  next(vim.api.nvim_get_hl(0, { name = "AlmaStreamSubAgent", link = true })) ~= nil,
  "subagent stream highlight is defined"
)

local token_thread = state.get_thread("validate-token-highlight-thread", { cwd = root })
local token_bufnr = vim.api.nvim_create_buf(false, true)
state.bind_buffer(token_thread, token_bufnr)
token_thread.config.tools = { "ConfiguredTool" }
token_thread.config.mcp_servers = { "server-one" }
token_thread.config.tool_groups = { "ops" }
token_thread.blocks = {
  { type = "UserBlock", message_id = "token-user-1", text = "/new @Bash $model:historical" },
  { type = "AssistantBlock", message_id = "token-assistant-1", text = "Historical @ConfiguredTool and $reasoning:high" },
}
token_thread.pending_request = nil
token_thread.generation = "idle"
token_thread.local_blocks = {}
token_thread.prompt_lines = {
  "/new @Bash @ConfiguredTool @mcp:server-one @group:ops",
  "$model:gpt-test $reasoning:xhigh $temp:0.25 $no-tools /skill:lint",
  "/unknown @UnknownTool $unknown $temp:not-a-number",
}
render.render(token_thread)
local first_prompt_line = token_thread.prompt_start + 1
local token_marks = composer_token_marks(token_bufnr, render_ns)
assert_token_mark(token_marks, "/new", "AlmaComposerCommand", first_prompt_line, "composer slash command")
assert_token_mark(token_marks, "/skill:lint", "AlmaComposerCommand", first_prompt_line, "composer skill token")
assert_token_mark(token_marks, "@Bash", "AlmaComposerMention", first_prompt_line, "composer static mention")
assert_token_mark(token_marks, "@ConfiguredTool", "AlmaComposerMention", first_prompt_line, "composer configured mention")
assert_token_mark(token_marks, "@mcp:server-one", "AlmaComposerMention", first_prompt_line, "composer mcp mention")
assert_token_mark(token_marks, "@group:ops", "AlmaComposerMention", first_prompt_line, "composer group mention")
assert_token_mark(token_marks, "$model:gpt-test", "AlmaComposerSelector", first_prompt_line, "composer model selector")
assert_token_mark(token_marks, "$reasoning:xhigh", "AlmaComposerSelector", first_prompt_line, "composer reasoning selector")
assert_token_mark(token_marks, "$temp:0.25", "AlmaComposerSelector", first_prompt_line, "composer temperature selector")
assert_token_mark(token_marks, "$no-tools", "AlmaComposerSelector", first_prompt_line, "composer no-tools selector")
assert_no_token_mark(token_marks, "/unknown", "invalid slash token")
assert_no_token_mark(token_marks, "@UnknownTool", "unknown mention token")
assert_no_token_mark(token_marks, "$unknown", "unknown selector token")
assert_no_token_mark(token_marks, "$temp:not-a-number", "invalid selector token")
assert_no_composer_marks_before(token_bufnr, render_ns, first_prompt_line, "historical text token highlighting")
assert_eq(
  vim.api.nvim_buf_get_lines(token_bufnr, token_thread.prompt_start - 1, token_thread.prompt_start, false)[1],
  "## You",
  "token highlight render keeps bottom composer marker"
)

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
assert_header_contains(bufnr, render_ns, you_positions[1], "test-model", "submitted user header model")
assert_header_contains(bufnr, render_ns, you_positions[1], "effort xhigh", "submitted user header reasoning")
assert_header_contains(bufnr, render_ns, alma_line, "test-model", "active assistant header model")
assert_header_contains(bufnr, render_ns, alma_line, "effort xhigh", "active assistant header reasoning")
assert_header_contains(bufnr, render_ns, composer_line, "test-model", "active composer header model")
assert_header_contains(bufnr, render_ns, composer_line, "effort xhigh", "active composer header reasoning")
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
assert_header_contains(bufnr, render_ns, streaming_alma_pos, "test-model", "streaming assistant header model")
assert_header_contains(bufnr, render_ns, streaming_alma_pos, "effort xhigh", "streaming assistant header reasoning")
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

local legacy_thread = require("alma").open_thread("validate-legacy-thread")
local legacy_win = vim.api.nvim_get_current_win()
assert_eq(vim.api.nvim_win_get_buf(legacy_win), legacy_thread.bufnr, "legacy open_thread focuses thread buffer")
assert_eq(vim.api.nvim_win_get_config(legacy_win).relative, "", "legacy open_thread uses normal window")
assert_bottom_composer(legacy_thread, legacy_win, "legacy open_thread")

vim.cmd("Alma float validate-layout-thread")
local layout_thread = state.get_thread("validate-layout-thread")
local layout_bufnr = layout_thread.bufnr
local float_win = vim.api.nvim_get_current_win()
local float_cfg = vim.api.nvim_win_get_config(float_win)
assert_eq(float_cfg.relative, "editor", "Alma float uses editor float")
assert(float_cfg.width >= math.min(40, vim.o.columns), "Alma float width is sane")
assert(float_cfg.height >= math.min(12, math.max(1, vim.o.lines - vim.o.cmdheight - 1)), "Alma float height is sane")
assert(float_cfg.col >= 0 and float_cfg.col + float_cfg.width <= vim.o.columns, "Alma float fits horizontally")
assert_bottom_composer(layout_thread, float_win, "Alma float")

vim.cmd("Alma float validate-layout-thread")
assert_eq(state.get_thread("validate-layout-thread").bufnr, layout_bufnr, "Alma float reuses thread buffer")
assert_eq(vim.api.nvim_get_current_win(), float_win, "Alma float reuses existing float window")
assert_bottom_composer(layout_thread, float_win, "Alma float reuse")

vim.cmd("Alma sidebar validate-layout-thread")
local sidebar_win = vim.api.nvim_get_current_win()
local sidebar_cfg = vim.api.nvim_win_get_config(sidebar_win)
assert_eq(sidebar_cfg.relative, "", "Alma sidebar uses normal split")
assert_eq(vim.api.nvim_win_get_buf(sidebar_win), layout_bufnr, "Alma sidebar reuses thread buffer")
local sidebar_info = vim.fn.getwininfo(sidebar_win)[1] or {}
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if win ~= sidebar_win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == "" then
    local info = vim.fn.getwininfo(win)[1] or {}
    assert((sidebar_info.wincol or 0) >= (info.wincol or 0), "Alma sidebar is right-biased")
  end
end
assert_bottom_composer(layout_thread, sidebar_win, "Alma sidebar")

vim.cmd("Alma open validate-layout-thread")
local open_win = vim.api.nvim_get_current_win()
assert_eq(vim.api.nvim_win_get_config(open_win).relative, "editor", "Alma open defaults to float")
assert_eq(state.get_thread("validate-layout-thread").bufnr, layout_bufnr, "Alma open reuses thread buffer")
assert_bottom_composer(layout_thread, open_win, "Alma open")

vim.cmd("Alma toggle validate-layout-thread")
assert_eq(#thread_visible_windows(layout_thread), 0, "Alma toggle hides visible thread windows")
vim.cmd("Alma toggle validate-layout-thread")
local toggle_win = vim.api.nvim_get_current_win()
assert_eq(state.get_thread("validate-layout-thread").bufnr, layout_bufnr, "Alma toggle reuses thread buffer")
assert_bottom_composer(layout_thread, toggle_win, "Alma toggle open")
vim.cmd("Alma toggle validate-layout-thread")
assert_eq(#thread_visible_windows(layout_thread), 0, "Alma toggle hides reopened thread")

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
