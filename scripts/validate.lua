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
local hooks = require("alma.hooks")
local context = require("alma.context")
local events = require("alma.events")
local state = require("alma.state")
local ws = require("alma.ws")
local config = require("alma.config")
local rest = require("alma.rest")
local render = require("alma.ui.render")
local detail = require("alma.ui.detail")
local request_metadata = require("alma.ui.metadata")
local tokens = require("alma.ui.tokens")
local tool_renderers = require("alma.ui.tool_renderers")

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
  assert_eq(lines[thread.prompt_start - 1], config.get().render.prompt_marker, label .. " bottom composer marker")
  assert_eq(lines[thread.prompt_start], "", label .. " bottom composer breathing line")
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

local function placeholder_overlay_text(bufnr, namespace, line)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if mark[2] + 1 == line and details.virt_text_pos == "overlay" and details.virt_text then
      local text = ""
      local is_placeholder = false
      for _, chunk in ipairs(details.virt_text) do
        text = text .. (chunk[1] or "")
        is_placeholder = is_placeholder or tostring(chunk[2] or ""):match("^AlmaBlockPlaceholder") ~= nil
      end
      if is_placeholder then
        return text
      end
    end
  end
  return ""
end

local function spinner_overlay_text(bufnr, namespace, line)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if mark[2] + 1 == line and details.virt_text_pos == "overlay" and details.virt_text then
      local text = ""
      local is_spinner = false
      for _, chunk in ipairs(details.virt_text) do
        text = text .. (chunk[1] or "")
        is_spinner = is_spinner or chunk[2] == "AlmaSpinner"
      end
      if is_spinner then
        return text
      end
    end
  end
  return ""
end

local function placeholder_virt_lines_text(bufnr, namespace, line)
  local out = {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, namespace, 0, -1, { details = true })) do
    local details = mark[4] or {}
    if mark[2] + 1 == line and details.virt_lines then
      for _, virt_line in ipairs(details.virt_lines) do
        local text = ""
        for _, chunk in ipairs(virt_line) do
          text = text .. (chunk[1] or "")
        end
        table.insert(out, text)
      end
    end
  end
  return out
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

local function placeholder_lines_for_block(test_thread, block)
  local lines = {}
  for lnum, mark in pairs(test_thread.placeholder_index or {}) do
    if mark.block == block then
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
if vim.treesitter and vim.treesitter.language and vim.treesitter.language.get_lang then
  assert_eq(vim.treesitter.language.get_lang("alma"), "markdown", "Alma filetype maps to markdown parser")
  assert_eq(
    vim.treesitter.language.get_lang("alma.markdown_inline"),
    "markdown_inline",
    "Alma inline markdown service maps to markdown_inline parser"
  )
end
config.setup({ notify = false, api_url = "http://localhost:23001/" })
assert_eq(config.api_url(), "http://localhost:23001", "setup api url override")
assert_eq(config.ws_url(), "ws://localhost:23001/ws/threads", "setup ws url override")
config.setup({ notify = false })
assert_eq(config.get().model, nil, "default model is empty")
assert_eq(config.get().reasoning_effort, nil, "default reasoning effort is empty")
assert_eq(config.get().window_layout, "float", "default window layout is float")
config.setup({ notify = false, model = "gpt-test-default", reasoning_effort = "xhigh", window_layout = "sidebar" })
local configured_thread = state.get_thread("validate-config-default-thread", { cwd = root })
assert_eq(configured_thread.config.model, "gpt-test-default", "thread inherits configured default model")
assert_eq(configured_thread.config.reasoning_effort, "xhigh", "thread inherits configured default reasoning")
assert_eq(config.get().window_layout, "sidebar", "window layout can be configured")
config.setup({ notify = false })
local resolved_workspace = config.resolve_workspace(0)
assert(resolved_workspace.path and resolved_workspace.path ~= "", "workspace resolver returns a path")
config.setup({
  notify = false,
  resolve_workspace = function(ctx)
    return { id = "workspace-id", name = "workspace-name", path = ctx.cwd }
  end,
})
local custom_workspace = config.resolve_workspace(0)
assert_eq(custom_workspace.id, "workspace-id", "custom workspace resolver id")
assert_eq(custom_workspace.name, "workspace-name", "custom workspace resolver name")
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
assert(has_label(tokens.static_for_trigger(">"), ">file:<path>"), "token static context includes file selector")
assert(not has_label(tokens.static_for_trigger(">"), ">custom:<id>"), "token static context excludes custom selector")

assert_eq(tokens.classify("@ConfiguredTool", { tools = { "ConfiguredTool" } }).valid, true, "token configured tool valid")
assert_eq(tokens.classify("@OtherTool", { tools = { "ConfiguredTool" } }).valid, false, "token unknown configured tool rejected")
assert_eq(tokens.classify("@FallbackTool", { tools = {} }).valid, true, "token fallback tool valid without catalog data")
assert_eq(tokens.classify("@mcp:server-one", { mcp_servers = { "server-one" } }).valid, true, "token configured mcp valid")
assert_eq(tokens.classify("@mcp:server-two", { mcp_servers = { "server-one" } }).valid, false, "token unknown configured mcp rejected")
assert_eq(tokens.classify("@group:default").valid, true, "token group form valid")
assert_eq(tokens.classify("@group:").valid, false, "token empty group rejected")

local thread = state.get_thread("validate-thread", { cwd = root })
;(function()
local context_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_name(context_buf, root .. "/validate-context.txt")
vim.api.nvim_buf_set_lines(context_buf, 0, -1, false, { "alpha", "beta", "gamma" })
vim.api.nvim_set_current_buf(context_buf)
vim.fn.setpos("'<", { 0, 2, 1, 0 })
vim.fn.setpos("'>", { 0, 3, 1, 0 })
local parser_context_spec = parser.parse_input({
  ">buffer",
  ">selection",
  ">diagnostics",
  ">diff",
  ">file:scripts/validate.lua",
  "context prompt",
}, thread)
assert_eq(parser_context_spec.prompt, "context prompt", "parser context prompt")
assert_eq(parser_context_spec.ephemeral_context[1].type, "buffer", "parser buffer context type")
assert_eq(parser_context_spec.ephemeral_context[1].text, "alpha\nbeta\ngamma", "parser buffer context text")
assert_eq(parser_context_spec.ephemeral_context[2].type, "selection", "parser selection context type")
assert_eq(parser_context_spec.ephemeral_context[2].text, "beta\ngamma", "parser selection context text")
assert_eq(parser_context_spec.ephemeral_context[3].type, "diagnostics", "parser diagnostics context type")
assert_eq(parser_context_spec.ephemeral_context[4].type, "diff", "parser diff context type")
assert_eq(parser_context_spec.ephemeral_context[5].type, "file", "parser file context type")
assert_eq(
  parser_context_spec.ephemeral_context[5].path,
  vim.fn.fnamemodify("scripts/validate.lua", ":p"),
  "parser file context path"
)
end)()
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
assert_eq(spec.metadata.source, "alma_nvim", "parser metadata source is API-safe")
local custom_spec = parser.parse_input({ ">custom-context:example", "hello custom" }, thread)
assert_eq(custom_spec.prompt, ">custom-context:example\nhello custom", "parser keeps unknown context token in prompt")
assert_eq(#custom_spec.ephemeral_context, 0, "parser does not create unknown context")
assert(custom_spec.warnings[1]:find("Unknown Alma token", 1, true), "parser warns about unknown context token")

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
local image_path = root .. "/.alma-validate-image.png"
vim.fn.writefile({ "fakepng" }, image_path, "b")
local image_spec = parser.parse_input({ "look at this", "![chart](.alma-validate-image.png)" }, thread)
assert_eq(image_spec.prompt, "look at this", "parser strips markdown image from prompt")
assert_eq(image_spec.display_prompt, "look at this\n![chart](.alma-validate-image.png)", "parser preserves image markdown for display")
assert_eq(image_spec.images[1].type, "file", "parser image becomes file part")
assert_eq(image_spec.images[1].mediaType, "image/png", "parser image media type")
assert_eq(image_spec.images[1].filename, "chart", "parser image alt filename")
local image_payload = parser.compile_request(thread, image_spec)
assert_eq(image_payload.data.userMessage.parts[1].type, "text", "image payload keeps text part")
assert_eq(image_payload.data.userMessage.parts[2].type, "file", "image payload appends file part")
vim.fn.delete(image_path)
assert_eq(payload.data.model, "test-model", "compiled request model")
assert_eq(payload.data.ephemeralModel, "test-model", "compiled ephemeral model")
assert_eq(payload.data.userMessageMetadata.model, "test-model", "compiled model metadata")
assert_eq(payload.data.source, "alma_nvim", "compiled payload source is API-safe")

local read_render = table.concat(tool_renderers.render({
  tool = "Read",
  input = { file_path = root .. "/scripts/validate.lua", offset = 1, limit = 3 },
  output = { content = "local root = vim.fn.getcwd()\nprint(root)" },
}), "\n")
assert(read_render:find("```lua", 1, true), "Read renderer uses filetype code block")
assert(read_render:find("local root", 1, true), "Read renderer includes content")
local edit_render = table.concat(tool_renderers.render({
  tool = "Edit",
  input = {
    file_path = "scripts/validate.lua",
    old_string = "old line\n",
    new_string = "new line\n",
  },
  output = { changed = true, replacements = 1, start_line = 12, file_path = "scripts/validate.lua" },
}), "\n")
assert(edit_render:find("```diff", 1, true), "Edit renderer uses diff code block")
assert(edit_render:find("--- a/scripts/validate.lua", 1, true), "Edit renderer includes diff old path")
assert(edit_render:find("-old line", 1, true), "Edit renderer includes removed line")
assert(edit_render:find("+new line", 1, true), "Edit renderer includes added line")
config.setup({
  notify = false,
  render = {
    tool_outputs = {
      renderers = {
        CustomTool = function(block)
          return { "custom output: " .. tostring(block.output.value) }
        end,
      },
    },
  },
})
local custom_render = table.concat(tool_renderers.render({ tool = "CustomTool", output = { value = "ok" } }), "\n")
assert_eq(custom_render, "custom output: ok", "custom tool renderer override")
config.setup({ notify = false })

local captured_create_body
local original_post = rest.post
rest.post = function(path, body, callback)
  if path == "/api/threads" then
    captured_create_body = body
    callback({ id = "validate-created-thread", title = body.title, model = body.model, reasoningEffort = body.reasoningEffort }, nil)
    return
  end
  return original_post(path, body, callback)
end
rest.create_thread({
  title = "Created",
  workspace_id = "workspace-id",
  model = "provider:gpt-default",
  reasoning_effort = "xhigh",
}, function() end)
rest.post = original_post
assert_eq(captured_create_body.model, "provider:gpt-default", "thread create sends default model")
assert_eq(captured_create_body.reasoningEffort, "xhigh", "thread create sends default reasoning effort")

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

;(function()
local expected_hooks = {
  thread_opened = "AlmaThreadOpened",
  thread_changed = "AlmaThreadChanged",
  before_submit = "AlmaBeforeSubmit",
  request_compiled = "AlmaRequestCompiled",
  after_submit = "AlmaAfterSubmit",
  generation_completed = "AlmaGenerationCompleted",
  generation_error = "AlmaGenerationError",
  proposal_received = "AlmaProposalReceived",
}
local hook_names = hooks.names()
assert_eq(#hook_names, 8, "hook registry exposes expected hook count")
assert_eq(hooks.register, hooks.on, "hook registry exposes register alias")
assert_eq(hooks.unregister, hooks.off, "hook registry exposes unregister alias")
local hook_group = vim.api.nvim_create_augroup("alma_validate_hooks", { clear = true })
for name, autocmd in pairs(expected_hooks) do
  assert_eq(hooks.autocmd_name(name), autocmd, "hook autocmd name " .. name)
  hooks.clear(name)
  local callback_seen = false
  local autocmd_seen = false
  hooks.on(name, function()
    error("intentional hook failure")
  end)
  hooks.on(name, function(event)
    callback_seen = event.hook == name and event.thread_id == "validate-hook-thread"
  end)
  vim.api.nvim_create_autocmd("User", {
    group = hook_group,
    pattern = autocmd,
    callback = function(event)
      autocmd_seen = event.data and event.data.hook == name and event.data.thread_id == "validate-hook-thread"
    end,
  })
  local result = hooks.dispatch(name, { thread_id = "validate-hook-thread" })
  assert_eq(result.ok, false, "hook failure is reported " .. name)
  assert(callback_seen, "hook callback after failure ran " .. name)
  assert(autocmd_seen, "hook autocmd fired " .. name)
end
hooks.clear()
vim.api.nvim_clear_autocmds({ group = hook_group })

hooks.clear("thread_changed")
local slim_group = vim.api.nvim_create_augroup("alma_validate_slim_hooks", { clear = true })
local heavy_thread = {
  id = "validate-heavy-thread",
  title = "Heavy Thread",
  messages = { { id = "message-one" } },
  blocks = { { type = "AssistantBlock", text = string.rep("x", 1024) } },
}
local callback_thread
local autocmd_thread
local autocmd_event
hooks.on("thread_changed", function(event)
  callback_thread = event.thread
end)
vim.api.nvim_create_autocmd("User", {
  group = slim_group,
  pattern = "AlmaThreadChanged",
  callback = function(event)
    autocmd_thread = event.data.thread
    autocmd_event = event.data.event
  end,
})
hooks.dispatch("thread_changed", {
  thread_id = "validate-heavy-thread",
  thread = heavy_thread,
  event = { type = "rest_messages_loaded", messages = heavy_thread.messages },
  effects = { { type = "render", thread_id = "validate-heavy-thread", payload = heavy_thread } },
})
assert_eq(callback_thread.messages, heavy_thread.messages, "hook callbacks keep full thread data")
assert_eq(autocmd_thread.id, "validate-heavy-thread", "hook autocmd keeps thread identity")
assert_eq(autocmd_thread.messages, nil, "hook autocmd omits heavy thread messages")
assert_eq(autocmd_thread.blocks, nil, "hook autocmd omits heavy thread blocks")
assert_eq(autocmd_event.message_count, 1, "hook autocmd keeps message count summary")
hooks.clear()
vim.api.nvim_clear_autocmds({ group = slim_group })

;(function()
context.clear()
local file_attachment = context.attach("validate-context-thread", {
  type = "file",
  id = "stable-file",
  path = "scripts/validate.lua",
  label = "validation file",
  once = true,
})
assert_eq(file_attachment.id, "stable-file", "context file attachment id")
assert_eq(file_attachment.type, "file", "context file attachment type")
context.attach("validate-context-thread", {
  kind = "application/json",
  id = "stable-json",
  content = { version = 1, value = "before" },
  once = true,
})
context.attach("validate-context-thread", {
  type = "json",
  id = "stable-json",
  data = { version = 1, value = "after" },
  once = true,
})
local listed_context = context.list("validate-context-thread")
assert_eq(#listed_context, 2, "context attachments dedupe by stable id")
assert_eq(listed_context[2].data.value, "after", "context dedupe replaces attachment")
listed_context[2].data.value = "mutated copy"
assert_eq(context.list("validate-context-thread")[2].data.value, "after", "context list returns copies")
local json_request_context = context.to_ephemeral_context(context.list("validate-context-thread")[2])
assert_eq(json_request_context.type, "json", "context converts json attachment type")
assert_eq(json_request_context.title, "stable-json", "context converts json attachment title")
assert_eq(json_request_context.data.value, "after", "context converts json attachment data")
context.attach("validate-context-thread", {
  type = "json",
  id = "file-backed-json",
  title = "File Backed JSON",
  data = { secret = "file-backed-secret", value = 2 },
  inline = false,
  once = true,
})
local file_backed_context = context.to_ephemeral_context(context.list("validate-context-thread")[3])
assert_eq(file_backed_context.type, "file", "context falls back json attachment to file context")
assert_eq(file_backed_context.mediaType, "application/json", "file-backed json keeps media type")
assert_eq(file_backed_context.metadata.attachmentType, "json", "file-backed json keeps attachment type metadata")
assert_eq(file_backed_context.metadata.fileBacked, true, "file-backed json records file backing")
assert(file_backed_context.path and file_backed_context.path:match("%.json$"), "file-backed json writes json file")
local file_backed_text = table.concat(vim.fn.readfile(file_backed_context.path), "\n")
assert(file_backed_text:find("file%-backed%-secret"), "file-backed json writes payload to file")
local compact_context = context.compact_metadata(context.list("validate-context-thread"))
assert_eq(compact_context.count, 3, "context compact metadata counts attachments")
assert_eq(compact_context.labels[3], "File Backed JSON", "context compact metadata keeps label")
assert(not vim.inspect(compact_context):find("file%-backed%-secret"), "context compact metadata omits raw json")
local consumed_context = context.consume("validate-context-thread")
assert_eq(#consumed_context, 3, "context consume returns attachments")
assert_eq(#context.list("validate-context-thread"), 0, "context consume removes once attachments")
context.attach("validate-context-thread", {
  type = "json",
  id = "persistent-json",
  data = { value = "keep" },
})
context.attach("other-context-thread", {
  type = "json",
  id = "other-json",
  data = { value = "other" },
  once = true,
})
assert_eq(#context.consume("validate-context-thread"), 1, "context consume includes persistent attachment")
assert_eq(#context.list("validate-context-thread"), 1, "context consume keeps persistent attachment")
assert_eq(#context.list("other-context-thread"), 1, "context registry is thread scoped")
context.clear()
end)()

local hooks_source = table.concat(vim.fn.readfile(root .. "/lua/alma/hooks.lua"), "\n")
local context_source = table.concat(vim.fn.readfile(root .. "/lua/alma/context.lua"), "\n")
local domain_terms = {
  string.char(90, 75),
  string.char(84, 121, 112, 115, 116),
  string.char(119, 105, 107, 105),
  string.char(122, 107, 45, 108, 115, 112),
}
for _, forbidden in ipairs(domain_terms) do
  assert(not hooks_source:find(forbidden, 1, true), "hooks module excludes domain term " .. forbidden)
  assert(not context_source:find(forbidden, 1, true), "context module excludes domain term " .. forbidden)
end

local submit_thread = state.get_thread("validate-submit-hook-thread", { cwd = root })
local submit_buf = vim.api.nvim_create_buf(false, true)
state.bind_buffer(submit_thread, submit_buf)
submit_thread.prompt_start = 1
vim.api.nvim_buf_set_lines(submit_buf, 0, -1, false, { "## You", "submit through failing hook" })
vim.api.nvim_set_current_buf(submit_buf)
local effects = require("alma.effects")
local original_dispatch = effects.dispatch
local captured_submit
effects.dispatch = function(thread_id, event)
  captured_submit = { thread_id = thread_id, event = event }
end
local submit_seen = { context_counts = {} }
context.clear()
context.attach("validate-submit-hook-thread", {
  type = "json",
  id = "pre-submit-json",
  label = "Pre Submit JSON",
  data = { value = "registered before submit" },
  once = true,
})
context.attach("validate-submit-hook-thread", {
  type = "json",
  id = "pre-submit-file-json",
  title = "Pre Submit File JSON",
  data = { value = "registered before submit as file" },
  inline = false,
  once = true,
})
hooks.on("before_submit", function()
  error("intentional submit hook failure")
end)
hooks.on("before_submit", function(event)
  context.attach(event.thread_id, {
    kind = "application/json",
    title = "hook-json",
    content = { value = "registered in hook" },
    once = true,
  })
  context.attach(event.thread_id, {
    type = "file",
    id = "persistent-submit-file",
    path = "scripts/validate.lua",
  })
end)
hooks.on("request_compiled", function(event)
  submit_seen.compiled = true
  event.payload.data.userMessageMetadata.hookValidated = true
  table.insert(submit_seen.context_counts, #(event.payload.data.ephemeralContext or {}))
end)
hooks.on("after_submit", function(event)
  submit_seen.after = event.payload.data.userMessageMetadata.hookValidated == true
end)
require("alma.buffers").submit_current()
effects.dispatch = original_dispatch
hooks.clear()
assert(captured_submit, "submit dispatch continues after failing hook")
assert_eq(captured_submit.thread_id, "validate-submit-hook-thread", "submit hook dispatch thread id")
assert_eq(captured_submit.event.type, "submit", "submit hook dispatch event type")
assert(submit_seen.compiled, "request_compiled hook ran during submit")
assert(submit_seen.after, "after_submit hook sees compiled request mutation")
local submitted_context = captured_submit.event.request.payload.data.ephemeralContext or {}
assert_eq(#submitted_context, 4, "submit injects registered context attachments")
assert_eq(submit_seen.context_counts[1], 4, "request_compiled sees injected context attachments")
assert_eq(submitted_context[1].type, "json", "submit injects pre-registered json attachment")
assert_eq(submitted_context[1].data.value, "registered before submit", "submit preserves json attachment data")
assert_eq(submitted_context[2].type, "file", "submit falls back pre-registered json attachment to file")
assert_eq(submitted_context[2].mediaType, "application/json", "submit file-backed json keeps media type")
assert_eq(submitted_context[3].type, "json", "submit injects hook-registered json attachment")
assert_eq(submitted_context[3].title, "hook-json", "submit uses hook attachment title")
assert_eq(submitted_context[4].type, "file", "submit injects file attachment")
assert_eq(captured_submit.event.request.spec.prompt, "submit through failing hook", "submit attachments do not change spec prompt")
assert_eq(
  captured_submit.event.request.payload.data.userMessage.parts[1].text,
  "submit through failing hook",
  "submit attachments do not change payload prompt"
)
assert_eq(
  captured_submit.event.request.payload.data.userMessageMetadata.attachment_count,
  4,
  "submit stores compact attachment count metadata"
)
assert_eq(
  captured_submit.event.request.payload.data.userMessageMetadata.attachment_labels[1],
  "Pre Submit JSON",
  "submit stores compact attachment labels"
)
assert(
  not vim.inspect(captured_submit.event.request.payload.data.userMessageMetadata):find("registered before submit", 1, true),
  "submit compact metadata omits raw json payload"
)
local _, submit_reduce_effects = core.reduce_thread(submit_thread, captured_submit.event)
assert_eq(submit_thread.local_blocks[1].text, "submit through failing hook", "submit user block prompt unchanged")
assert_eq(submit_thread.local_blocks[1].attachment_count, 4, "submit user block stores compact attachment count")
local submit_labels = request_metadata.user_labels(submit_thread, submit_thread.local_blocks[1])
assert(vim.tbl_contains(submit_labels, "Pre Submit JSON"), "submit user labels include compact attachment label")
assert(vim.tbl_contains(submit_labels, "Pre Submit File JSON"), "submit user labels include second compact attachment label")
local submit_effect_has_ws = false
for _, effect in ipairs(submit_reduce_effects) do
  submit_effect_has_ws = submit_effect_has_ws or effect.type == "ws_send"
end
assert(submit_effect_has_ws, "submit reduce still sends websocket payload")
assert_eq(#context.list("validate-submit-hook-thread"), 1, "submit consumes only once attachments")
assert_eq(context.list("validate-submit-hook-thread")[1].id, "persistent-submit-file", "submit keeps persistent attachment")
context.clear()
end)()

;(function()
local once_thread = state.get_thread("validate-once-submit-thread", { cwd = root })
local once_buf = vim.api.nvim_create_buf(false, true)
state.bind_buffer(once_thread, once_buf)
once_thread.prompt_start = 1
vim.api.nvim_buf_set_lines(once_buf, 0, -1, false, { "## You", "repeat submit" })
vim.api.nvim_set_current_buf(once_buf)
local effects = require("alma.effects")
local original_dispatch = effects.dispatch
local captures = {}
effects.dispatch = function(thread_id, event)
  table.insert(captures, { thread_id = thread_id, event = event })
end
context.clear()
context.attach("validate-once-submit-thread", {
  type = "json",
  id = "once-json",
  label = "Once JSON",
  data = { value = "consume me once" },
  once = true,
})
context.attach("validate-once-submit-thread", {
  type = "file",
  id = "persistent-json-file",
  path = "scripts/validate.lua",
})
require("alma.buffers").submit_current()
require("alma.buffers").submit_current()
effects.dispatch = original_dispatch
hooks.clear()
assert_eq(#captures, 2, "once attachment validation captured two submits")
local first_context = captures[1].event.request.payload.data.ephemeralContext or {}
local second_context = captures[2].event.request.payload.data.ephemeralContext or {}
assert_eq(#first_context, 2, "first repeat submit includes once and persistent attachments")
assert_eq(first_context[1].id, "once-json", "first repeat submit includes once attachment")
assert_eq(#second_context, 1, "second repeat submit excludes consumed once attachment")
assert_eq(second_context[1].id, "persistent-json-file", "second repeat submit keeps persistent attachment only")
assert_eq(captures[2].event.request.payload.data.userMessage.parts[1].text, "repeat submit", "repeat submit prompt unchanged")
context.clear()
end)()

local normalized = events.normalize_ws_event({
  type = "text_delta",
  data = { threadId = "validate-thread", delta = "ok" },
})
assert_eq(normalized.thread_id, "validate-thread", "ws event thread id")
assert_eq(normalized.known, true, "ws event known")
;(function()
local proposal_event = events.normalize_ws_event({
  type = "generic_proposal_created",
  payload = {
    proposal = {
      id = "proposal-alpha",
      threadId = "validate-proposal-thread",
      title = "Review changes",
      baseSnapshotId = "snapshot-alpha",
      files = {
        {
          relativePath = "note/example.typ",
          patch = "@@ -1 +1 @@\n-old\n+new",
          hunks = { { oldStart = 1, newStart = 1 } },
        },
      },
    },
  },
})
assert_eq(proposal_event.name, "proposal_received", "proposal-like event normalizes to proposal_received")
assert_eq(proposal_event.thread_id, "validate-proposal-thread", "proposal-like event thread id")
assert_eq(proposal_event.known, true, "proposal-like event is known after normalization")
assert_eq(proposal_event.data.id, "proposal-alpha", "proposal-like event keeps id")
assert_eq(proposal_event.data.kind, "diff", "proposal-like event infers diff kind")
assert_eq(proposal_event.data.title, "Review changes", "proposal-like event keeps title")
assert_eq(proposal_event.data.base_snapshot_id, "snapshot-alpha", "proposal-like event keeps base snapshot")
assert_eq(proposal_event.data.files[1].relative_path, "note/example.typ", "proposal-like event keeps file path")
assert_eq(proposal_event.data.files[1].diff, "@@ -1 +1 @@\n-old\n+new", "proposal-like event keeps diff")
state.get_thread("validate-proposal-thread", { cwd = root })
local proposal_seen
hooks.on("proposal_received", function(event)
  proposal_seen = event.proposal
end)
require("alma.effects").dispatch("validate-proposal-thread", proposal_event)
hooks.clear()
assert(proposal_seen, "proposal_received hook dispatched normalized proposal")
assert_eq(proposal_seen.id, "proposal-alpha", "proposal_received hook sees proposal id")
assert_eq(proposal_seen.files[1].relative_path, "note/example.typ", "proposal_received hook sees generic files")
end)()

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
local subagent_message = events.normalize_ws_event({
  type = "subagent_message",
  data = { context = { parentThreadId = "validate-thread", taskId = "task-1" } },
})
assert_eq(subagent_message.thread_id, "validate-thread", "subagent message parent thread id")
assert_eq(subagent_message.known, true, "subagent message event known")
assert_eq(events.is_thread_scoped_event("subagent_message"), true, "subagent message is thread scoped")
assert_eq(events.is_thread_scoped_event("subagent_message_added"), true, "subagent added event is thread scoped")
assert_eq(events.is_thread_scoped_event("subagent_message_delta"), true, "subagent delta event is thread scoped")
assert_eq(events.is_thread_scoped_event("subagent_message_completed"), true, "subagent completed event is thread scoped")
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
assert_eq(chronological_blocks[2].type, "ReasoningBlock", "chronological reasoning block")
assert_eq(chronological_blocks[2].request_reasoning_effort, "xhigh", "reasoning inherits request effort")
assert_eq(chronological_blocks[3].type, "AssistantBlock", "chronological assistant block")
assert_eq(chronological_blocks[3].request_model, "test-model", "assistant inherits request model")
local visible_timeline_blocks = events.normalize_messages({
  {
    id = "validate-thread--assistant-visible-step",
    role = "assistant",
    parts = { { type = "step-start", text = "visible milestone" } },
  },
})
assert_eq(visible_timeline_blocks[1].type, "AgentTimelineBlock", "non-empty step-start remains visible")

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

;(function()
  local runtime_effects = require("alma.effects")
  runtime_effects._test.reset_pending_rest()
  local original_rest_messages = rest.messages
  local message_fetch_callbacks = {}
  local message_fetch_count = 0
  state.get_thread("coalesce-thread")
  rest.messages = function(_, callback)
    message_fetch_count = message_fetch_count + 1
    table.insert(message_fetch_callbacks, callback)
  end
  runtime_effects.run({
    { type = "rest_fetch_messages", thread_id = "coalesce-thread" },
    { type = "rest_fetch_messages", thread_id = "coalesce-thread" },
    { type = "rest_fetch_messages", thread_id = "coalesce-thread" },
  })
  assert_eq(message_fetch_count, 1, "message refetch coalesces concurrent requests")
  message_fetch_callbacks[1]({ { id = "message-one", message = { role = "assistant", parts = {} } } }, nil)
  vim.wait(100, function()
    return message_fetch_count == 2
  end)
  assert_eq(message_fetch_count, 2, "message refetch runs one queued follow-up")
  runtime_effects.run({ { type = "rest_fetch_messages", thread_id = "coalesce-thread" } })
  assert_eq(message_fetch_count, 2, "message refetch joins queued follow-up")
  message_fetch_callbacks[2]({ { id = "message-two", message = { role = "assistant", parts = {} } } }, nil)
  vim.wait(100, function()
    return vim.tbl_isempty(runtime_effects._test.pending_rest)
  end)
  assert(vim.tbl_isempty(runtime_effects._test.pending_rest), "message refetch clears pending state")
  rest.messages = original_rest_messages
end)()

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
assert_eq(thread.local_blocks[2].type, "QueuedBlock", "queued submit uses placeholder block")
assert_eq(thread.local_blocks[2].request_model, "test-model", "queued placeholder block inherits request model")
local queue_bufnr = vim.api.nvim_create_buf(false, true)
state.bind_buffer(thread, queue_bufnr)
render.render(thread)
local queue_render_ns = vim.api.nvim_get_namespaces()["alma.nvim"]
local queued_placeholder_line = placeholder_lines_for_block(thread, thread.local_blocks[2])[1]
local queued_placeholder = placeholder_overlay_text(queue_bufnr, queue_render_ns, queued_placeholder_line)
assert(queued_placeholder:find("Queued Request %[queued%]"), "queued placeholder uses unified title")
assert(queued_placeholder:find("waiting for current response", 1, true), "queued placeholder uses compact meta")
assert(not queued_placeholder:find("⏳", 1, true), "queued placeholder omits hourglass emoji")
assert(not vim.tbl_contains(vim.api.nvim_buf_get_lines(queue_bufnr, 0, -1, false), "This request will send after the current response finishes."), "queued message body is virtual only")
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

thread.backend_generating = false
thread.pending_request = nil
thread.streaming_text = nil
thread.streaming_reasoning_text = nil
thread.local_blocks = {}
thread.subagent_streams = {}
thread.subagent_order = {}
thread.generation = "idle"
local _, subagent_added_effects = core.reduce_thread(thread, {
  type = "ws_event",
  name = "subagent_message_added",
  known = true,
  data = {
    context = {
      threadId = "validate-thread",
      taskId = "task-alpha",
      subagentMessageId = "subagent-msg-alpha",
      parentToolCallId = "call-parent-alpha",
      agentProfileName = "Developer",
    },
    message = {
      role = "assistant",
      parts = {
        { type = "text", text = "delegated " },
        {
          type = "tool-Bash",
          toolName = "Bash",
          toolCallId = "call-sub",
          state = "running",
          args = { command = "pwd" },
        },
      },
    },
  },
})
assert_eq(thread.local_blocks[1].type, "AssistantBlock", "subagent added renders assistant block")
assert_eq(thread.local_blocks[1].text, "delegated ", "subagent added preserves text")
assert_eq(thread.local_blocks[1].metadata.subAgentName, "Developer", "subagent metadata keeps agent name")
assert_eq(thread.local_blocks[1].metadata.role, "assistant", "subagent metadata keeps message role")
assert_eq(thread.local_blocks[1].metadata.subAgentTaskId, "task-alpha", "subagent metadata keeps task id")
assert_eq(thread.local_blocks[1].metadata.subAgentMessageId, "subagent-msg-alpha", "subagent metadata keeps message id")
assert_eq(thread.local_blocks[1].metadata.parentToolCallId, "call-parent-alpha", "subagent metadata keeps parent tool call id")
assert_eq(thread.local_blocks[1].event_type, "subagent_message", "subagent block keeps event type")
assert_eq(thread.local_blocks[2].type, "ToolCallBlock", "subagent added renders tool block")
assert_eq(thread.local_blocks[2].tool, "Bash", "subagent tool name is preserved")
assert_eq(subagent_added_effects[2].type, "render", "subagent added renders streaming update")
core.reduce_thread(thread, {
  type = "ws_event",
  name = "subagent_message_delta",
  known = true,
  data = {
    context = { threadId = "validate-thread", taskId = "task-alpha", agentProfileName = "Developer" },
    deltas = { { type = "text_append", partIndex = 0, text = "output" } },
  },
})
assert_eq(thread.local_blocks[1].text, "delegated output", "subagent delta appends text by part index")
core.reduce_thread(thread, {
  type = "ws_event",
  name = "subagent_message_completed",
  known = true,
  data = {
    context = { threadId = "validate-thread", taskId = "task-alpha", agentProfileName = "Developer" },
    deltas = { { type = "tool_output_set", partIndex = 1, state = "output-available", output = "done" } },
  },
})
assert_eq(thread.local_blocks[1].state, "done", "subagent completed marks text block done")
assert_eq(thread.local_blocks[2].state, "output-available", "subagent completed updates tool state")
assert_eq(thread.local_blocks[2].output, "done", "subagent completed updates tool output")
local crew_lines = detail.agent_crew_lines(thread)
local crew_text = table.concat(crew_lines, "\n")
assert(vim.tbl_contains(crew_lines, "## Live Task Activity"), "local crew fallback shows task activity")
assert(crew_text:find("✓ Developer %[done%]") or crew_text:find("✓ Developer [done]", 1, true), "local crew fallback shows task status")
assert(crew_text:find("tools: Bash %[output%-available%]") or crew_text:find("tools: Bash [output-available]", 1, true), "local crew fallback shows tool summary")
assert(not crew_text:find("delegated output", 1, true), "local crew fallback hides delegated text content")
local api_crew_lines = detail.agent_crew_lines({
  missions = {
    {
      id = "mission-one",
      title = "Build complete app",
      status = "running",
      harnessMode = "sprint-harness",
      currentPhase = "generating",
      summary = { totalRuns = 2, completedRuns = 1, activeRuns = 1 },
      sprints = {
        { id = "sprint-one", sprintNumber = 1, title = "Foundation", status = "passed", agentId = "developer" },
        { id = "sprint-two", sprintNumber = 2, title = "Crew progress view", status = "active", agentId = "developer" },
      },
      contracts = {
        {
          id = "contract-two",
          sprintId = "sprint-two",
          status = "agreed",
          criteria = { { id = "c1", description = "Shows the current sprint without exposing the agent implementation." } },
        },
      },
      evaluations = {},
      handoffs = {},
      runs = {},
    },
  },
}, { thread = { title = "Crew thread" } })
local api_crew_text = table.concat(api_crew_lines, "\n")
assert(api_crew_text:find("Crew · 1 missions, 2 runs, 1 active", 1, true), "agent crew API view shows totals")
assert(api_crew_text:find("mode: Sprint Harness", 1, true), "agent crew API view mirrors harness mode")
assert(api_crew_text:find("phase: Building", 1, true), "agent crew API view shows phase label")
assert(api_crew_text:find("progress: 1/2 sprints", 1, true), "agent crew API view shows sprint progress")
assert(api_crew_text:find("current: Building: S2 Crew progress view", 1, true), "agent crew API view highlights current step")
assert(api_crew_text:find("● S2 Crew progress view %[active%]") or api_crew_text:find("● S2 Crew progress view [active]", 1, true), "agent crew API view renders active sprint")
assert(api_crew_text:find("Contract", 1, true), "agent crew API view expands active contract")
assert(api_crew_text:find("c1 Shows the current sprint", 1, true), "agent crew API view shows acceptance criteria")
assert(not api_crew_text:find("developer", 1, true), "agent crew API view hides agent implementation details")
thread.subagent_streams = {}
thread.subagent_order = {}
thread.local_blocks = {}
thread.generation = "idle"

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
assert(rendered_lines[1]:match("^# Alma:"), "render keeps only the top Alma title")
assert(rendered_lines[2] == "", "render title is followed by a blank line")
local hidden_header_prefixes = {
  "thread:",
  "cwd:",
  "transport:",
  "generation:",
  "sync:",
  "status:",
  "last_error:",
}
local positions = {}
for index, line in ipairs(rendered_lines) do
  positions[line] = positions[line] or index
  assert(not line:find("\n", 1, true), "render line must not contain newline")
  for _, prefix in ipairs(hidden_header_prefixes) do
    assert(not vim.startswith(line, prefix), "render hides header metadata prefix " .. prefix)
  end
end
assert(positions["## You"] < positions["## Alma"], "user renders before assistant group")
assert(not positions["### Agent Timeline: step-start"], "empty step-start timeline is hidden")
local reasoning_lines = placeholder_lines_for_block(thread, chronological_blocks[2])
assert(#reasoning_lines == 1, "reasoning renders as one placeholder line")
assert(positions["## Alma"] < reasoning_lines[1], "assistant heading wraps reasoning placeholder")
assert(reasoning_lines[1] < positions["answer second"], "reasoning placeholder renders before assistant text")
assert(not positions["thinking first"], "reasoning body is not persisted in the markdown buffer")
assert_eq(rendered_lines[thread.prompt_start - 1], "## You", "idle prompt uses user header")
assert_eq(rendered_lines[thread.prompt_start], "", "idle prompt breathes after user header")
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
local reasoning_placeholder = placeholder_overlay_text(bufnr, render_ns, reasoning_lines[1])
assert(reasoning_placeholder:find("Reasoning %[done%]"), "reasoning placeholder shows status")
assert(reasoning_placeholder:find("za expand", 1, true), "reasoning placeholder exposes expansion hint")
assert_eq(#placeholder_virt_lines_text(bufnr, render_ns, reasoning_lines[1]), 0, "collapsed reasoning has no virtual body")
vim.api.nvim_win_set_cursor(0, { reasoning_lines[1], 0 })
render.toggle_under_cursor()
local expanded_reasoning = placeholder_virt_lines_text(bufnr, render_ns, reasoning_lines[1])
assert(#expanded_reasoning > 0, "expanded reasoning uses virtual lines")
assert(table.concat(expanded_reasoning, "\n"):find("thinking first", 1, true), "expanded reasoning shows body virtually")
assert(not vim.tbl_contains(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "thinking first"), "expanded reasoning still does not persist body")
render.toggle_under_cursor()
assert_eq(vim.bo[bufnr].modifiable, true, "idle chat buffer is editable")
thread.last_error = nil

local hint_thread = state.get_thread("validate-placeholder-hint-thread", { cwd = root })
local hint_bufnr = vim.api.nvim_create_buf(false, true)
state.bind_buffer(hint_thread, hint_bufnr)
local first_hint_reasoning = { type = "ReasoningBlock", message_id = "hint-1", text = "first hint body", state = "done" }
local repeated_hint_reasoning = { type = "ReasoningBlock", message_id = "hint-2", text = "second hint body", state = "done" }
hint_thread.blocks = { first_hint_reasoning, repeated_hint_reasoning }
hint_thread.local_blocks = {}
hint_thread.pending_request = nil
hint_thread.generation = "idle"
render.render(hint_thread)
local first_hint_line = placeholder_lines_for_block(hint_thread, first_hint_reasoning)[1]
local repeated_hint_line = placeholder_lines_for_block(hint_thread, repeated_hint_reasoning)[1]
assert(
  placeholder_overlay_text(hint_bufnr, render_ns, first_hint_line):find("za expand", 1, true),
  "first placeholder exposes expansion hint"
)
assert(
  not placeholder_overlay_text(hint_bufnr, render_ns, repeated_hint_line):find("za expand", 1, true),
  "repeated placeholder omits expansion hint"
)

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
  header_thread.prompt_start - 1,
  "composer-thread-model",
  "composer header thread model"
)
assert_header_contains(header_bufnr, render_ns, header_thread.prompt_start - 1, "effort medium", "composer header thread reasoning")
assert_header_not_contains(header_bufnr, render_ns, header_thread.prompt_start - 1, "ctx", "composer header no fabricated ctx")
assert_header_not_contains(
  header_bufnr,
  render_ns,
  header_thread.prompt_start - 1,
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
  header_thread.prompt_start - 1,
  "composer-request-model",
  "composer header pending request model"
)
assert_header_contains(header_bufnr, render_ns, header_thread.prompt_start - 1, "effort xhigh", "composer header pending reasoning")
header_thread.context_usage = { remainingTokens = 321 }
render.render(header_thread)
assert_header_contains(
  header_bufnr,
  render_ns,
  header_thread.prompt_start - 1,
  "ctx remaining 321",
  "composer header real context remaining"
)

local crew_progress_thread = state.get_thread("validate-crew-progress-thread", { cwd = root })
local crew_progress_bufnr = vim.api.nvim_create_buf(false, true)
state.bind_buffer(crew_progress_thread, crew_progress_bufnr)
crew_progress_thread.blocks = {}
crew_progress_thread.local_blocks = {}
crew_progress_thread.pending_request = nil
crew_progress_thread.generation = "idle"
crew_progress_thread.agent_crew = {
  missions = {
    {
      title = "Build task tree",
      status = "running",
      harnessMode = "sprint-harness",
      currentPhase = "generating",
      sprints = {
        { id = "crew-s1", sprintNumber = 1, title = "Foundation", status = "passed" },
        { id = "crew-s2", sprintNumber = 2, title = "Progress extmark", status = "active" },
      },
      summary = { totalRuns = 2, completedRuns = 1, activeRuns = 1 },
    },
  },
}
render.render(crew_progress_thread)
local crew_progress_lines = placeholder_virt_lines_text(crew_progress_bufnr, render_ns, crew_progress_thread.prompt_start + 1)
local crew_progress_text = table.concat(crew_progress_lines, "\n")
assert(crew_progress_text:find("Build task tree", 1, true), "crew progress extmark shows mission title")
assert(crew_progress_text:find("1/2", 1, true), "crew progress extmark shows sprint progress")
assert(crew_progress_text:find("Building: S2 Progress extmark", 1, true), "crew progress extmark shows current step")
assert(not vim.tbl_contains(vim.api.nvim_buf_get_lines(crew_progress_bufnr, 0, -1, false), "Build task tree"), "crew progress is virtual only")
assert(next(vim.api.nvim_get_hl(0, { name = "AlmaCrewProgressActive", link = true })) ~= nil, "crew progress active highlight is defined")

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
local tool_output_decoration_block = {
  type = "ToolOutputBlock",
  message_id = "stream-primary",
  tool = "Bash",
  output = "second tool output body",
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
local persisted_subagent_task_block = {
  type = "AssistantBlock",
  message_id = "stream-subagent-task",
  metadata = { subagentTaskId = "task-persisted-alpha", subagentParentMessageId = "msg-parent-alpha" },
  text = "persisted subagent assistant output",
}
local persisted_subagent_reasoning_block = {
  type = "ReasoningBlock",
  message_id = "stream-subagent-task",
  metadata = { subagentTaskId = "task-persisted-alpha", subagentParentMessageId = "msg-parent-alpha" },
  text = "persisted subagent reasoning output",
  state = "done",
}
stream_thread.blocks = {
  primary_assistant_block,
  tool_decoration_block,
  tool_output_decoration_block,
  timeline_decoration_block,
  raw_decoration_block,
  subagent_metadata_block,
  subagent_event_block,
  persisted_subagent_task_block,
  persisted_subagent_reasoning_block,
}
stream_thread.local_blocks = {}
stream_thread.pending_request = nil
stream_thread.generation = "idle"
render.render(stream_thread)
local stream_marks = stream_decoration_marks(stream_bufnr, render_ns)
assert_stream_decoration(stream_thread, stream_marks, tool_decoration_block, "AlmaStreamTool", "tool block gutter")
assert_stream_decoration(stream_thread, stream_marks, tool_output_decoration_block, "AlmaStreamTool", "tool output gutter")
local tool_placeholder_line = placeholder_lines_for_block(stream_thread, tool_decoration_block)[1]
local tool_output_placeholder_line = placeholder_lines_for_block(stream_thread, tool_output_decoration_block)[1]
assert(
  placeholder_overlay_text(stream_bufnr, render_ns, tool_placeholder_line):find("za expand", 1, true),
  "first tool placeholder exposes expansion hint"
)
assert(
  not placeholder_overlay_text(stream_bufnr, render_ns, tool_output_placeholder_line):find("za expand", 1, true),
  "repeated tool placeholder omits expansion hint"
)
assert_stream_decoration(
  stream_thread,
  stream_marks,
  timeline_decoration_block,
  "AlmaStreamTimeline",
  "timeline block gutter"
)
assert_stream_decoration(stream_thread, stream_marks, raw_decoration_block, "AlmaStreamRaw", "raw event block gutter")
assert_no_stream_decoration(stream_thread, stream_marks, subagent_metadata_block, "subagent metadata title-only block")
assert_no_stream_decoration(stream_thread, stream_marks, subagent_event_block, "subagent event title-only block")
assert_no_stream_decoration(stream_thread, stream_marks, persisted_subagent_task_block, "persisted subagent task title-only block")
assert_no_stream_decoration(stream_thread, stream_marks, persisted_subagent_reasoning_block, "persisted subagent reasoning title-only block")
assert_no_stream_decoration(stream_thread, stream_marks, primary_assistant_block, "primary assistant gutter")
local persisted_stream_lines = vim.api.nvim_buf_get_lines(stream_bufnr, 0, -1, false)
assert(vim.tbl_contains(persisted_stream_lines, "## Alma researcher"), "subagent metadata block uses source header")
assert(vim.tbl_contains(persisted_stream_lines, "## Alma Subagent"), "subagent event block uses fallback source header")
assert(not vim.tbl_contains(persisted_stream_lines, "persisted subagent assistant output"), "persisted subagent assistant content is hidden inline")
assert(not vim.tbl_contains(persisted_stream_lines, "persisted subagent reasoning output"), "persisted subagent reasoning content is hidden inline")
assert(not vim.tbl_contains(persisted_stream_lines, "delegated worker output"), "subagent metadata content is hidden inline")
assert(not vim.tbl_contains(persisted_stream_lines, "delegated event output"), "subagent event content is hidden inline")
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
assert(
  next(vim.api.nvim_get_hl(0, { name = "AlmaHeaderSubAgent1", link = true })) ~= nil,
  "subagent header palette highlight is defined"
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
  vim.api.nvim_buf_get_lines(token_bufnr, token_thread.prompt_start - 2, token_thread.prompt_start - 1, false)[1],
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
}
render.render(thread)
local locked_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
local you_positions = {}
local old_heading_count = 0
for index, line in ipairs(locked_lines) do
  if line == "## You" then
    table.insert(you_positions, index)
  end
  if line:match("^## You %[") or line:match("^## Alma %[") then
    old_heading_count = old_heading_count + 1
  end
end
local spinner_line_pos = thread.spinner_mark and thread.spinner_mark.line
local composer_line = you_positions[#you_positions]
assert_eq(#you_positions, 2, "submitted render keeps submitted user block and bottom composer")
assert_eq(locked_lines[thread.prompt_start - 1], "## You", "submitted render keeps bottom composer")
assert_eq(locked_lines[thread.prompt_start], "", "submitted render breathes after composer header")
assert(not vim.tbl_contains(locked_lines, "⏳ Alma is thinking..."), "submitted render omits redundant loading assistant block")
assert(not vim.tbl_contains(locked_lines, "## Alma"), "submitted render omits empty Alma section before streaming")
assert(spinner_line_pos and spinner_line_pos < composer_line, "submitted render keeps spinner before composer")
assert_eq(locked_lines[spinner_line_pos], " ", "submitted render uses stable spinner placeholder line")
assert(
  spinner_overlay_text(bufnr, render_ns, spinner_line_pos):find("Alma streaming", 1, true),
  "submitted render draws spinner through overlay text"
)
local spinner_tick = vim.b[bufnr].changedtick
render.update_spinner(thread)
assert_eq(vim.b[bufnr].changedtick, spinner_tick, "spinner update does not rewrite buffer text")
assert_eq(old_heading_count, 0, "submitted render avoids legacy state headings")
assert_header_contains(bufnr, render_ns, you_positions[1], "test-model", "submitted user header model")
assert_header_contains(bufnr, render_ns, you_positions[1], "effort xhigh", "submitted user header reasoning")
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
local reasoning_pos = placeholder_lines_for_block(thread, thread.local_blocks[2])[1]
local answer_pos
local streaming_alma_pos
local streaming_composer_pos
for index, line in ipairs(streaming_lines) do
  if line == "## Alma" and not streaming_alma_pos then
    streaming_alma_pos = index
  elseif line == "partial answer" then
    answer_pos = index
  elseif line == "## You" then
    streaming_composer_pos = index
  end
end
assert(streaming_alma_pos and reasoning_pos and streaming_alma_pos < reasoning_pos, "streaming reasoning placeholder is inside Alma section")
assert(reasoning_pos and answer_pos and reasoning_pos < answer_pos, "streaming reasoning placeholder renders before answer")
assert(answer_pos and streaming_composer_pos and answer_pos < streaming_composer_pos, "streaming answer renders before composer")
assert(placeholder_overlay_text(bufnr, render_ns, reasoning_pos):find("Reasoning %[streaming%]"), "streaming reasoning placeholder shows status")
assert(not vim.tbl_contains(streaming_lines, "thinking now"), "streaming reasoning body is virtual only")
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
local stable_changedtick = vim.b[bufnr].changedtick
render.render(thread)
assert_eq(vim.b[bufnr].changedtick, stable_changedtick, "unchanged render skips buffer rewrite")

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
assert_eq(vim.api.nvim_win_get_buf(legacy_win), legacy_thread.bufnr, "open_thread focuses thread buffer")
assert_eq(vim.api.nvim_win_get_config(legacy_win).relative, "editor", "open_thread uses configured window layout")
assert_eq(vim.bo[legacy_thread.bufnr].filetype, "alma", "Alma thread buffer uses Alma filetype")
assert_eq(vim.bo[legacy_thread.bufnr].syntax, "", "Alma thread buffer avoids duplicate legacy markdown syntax when Tree-sitter starts")
assert_eq(vim.treesitter.get_parser(legacy_thread.bufnr):lang(), "markdown", "Alma thread buffer uses markdown Tree-sitter parser")
assert(vim.bo[legacy_thread.bufnr].undolevels ~= -1, "Alma thread buffer does not persistently disable undo")
assert_eq(vim.wo[legacy_win].number, false, "Alma thread window hides absolute numbers")
assert_eq(vim.wo[legacy_win].relativenumber, false, "Alma thread window hides relative numbers")
assert_bottom_composer(legacy_thread, legacy_win, "open_thread")

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

pcall(vim.cmd, "only!")
vim.cmd("enew!")
local scoped_source_win = vim.api.nvim_get_current_win()
vim.wo[scoped_source_win].number = true
vim.wo[scoped_source_win].relativenumber = true
vim.wo[scoped_source_win].signcolumn = "yes"
local global_undolevels = vim.go.undolevels
vim.cmd("Alma sidebar validate-scoped-options-thread")
local scoped_thread = state.get_thread("validate-scoped-options-thread")
local scoped_win = vim.api.nvim_get_current_win()
assert_eq(vim.bo[scoped_thread.bufnr].filetype, "alma", "scoped Alma buffer uses Alma filetype")
assert_eq(vim.bo[scoped_thread.bufnr].syntax, "", "scoped Alma buffer avoids duplicate legacy markdown syntax when Tree-sitter starts")
assert_eq(vim.treesitter.get_parser(scoped_thread.bufnr):lang(), "markdown", "scoped Alma buffer uses markdown Tree-sitter parser")
assert(vim.fn.maparg("za", "n", false, true).buffer == 1, "Alma za override is buffer-local")
assert(vim.bo[scoped_thread.bufnr].undolevels ~= -1, "scoped Alma buffer restores local undolevels after render")
assert_eq(vim.go.undolevels, global_undolevels, "scoped Alma render preserves global undolevels")
assert_eq(vim.wo[scoped_win].number, false, "scoped Alma window hides absolute numbers")
assert_eq(vim.wo[scoped_win].relativenumber, false, "scoped Alma window hides relative numbers")
assert_eq(vim.wo[scoped_win].signcolumn, "no", "scoped Alma window hides signcolumn")
vim.cmd("enew!")
assert(vim.fn.maparg("za", "n", false, true).buffer ~= 1, "leaving Alma removes buffer-local za override")
assert_eq(vim.wo[scoped_win].number, true, "leaving Alma restores absolute numbers")
assert_eq(vim.wo[scoped_win].relativenumber, true, "leaving Alma restores relative numbers")
assert_eq(vim.wo[scoped_win].signcolumn, "yes", "leaving Alma restores signcolumn")
assert_eq(vim.go.undolevels, global_undolevels, "leaving Alma preserves global undolevels")

print("alma.nvim validation OK")
vim.cmd("qa")
