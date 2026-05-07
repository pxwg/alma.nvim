local config = require("alma.config")
local events = require("alma.events")
local util = require("alma.util")

local M = {}

local ns = vim.api.nvim_create_namespace("alma.nvim")

local foldable_types = {
  ReasoningBlock = true,
  ToolCallBlock = true,
  ToolOutputBlock = true,
  RawEventBlock = true,
  AgentTimelineBlock = true,
}

local assistant_content_types = {
  AssistantBlock = true,
  ReasoningBlock = true,
  ToolCallBlock = true,
  ToolOutputBlock = true,
  RawEventBlock = true,
  AgentTimelineBlock = true,
  ErrorBlock = true,
}

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AlmaHeaderUser", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "AlmaHeaderAssistant", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSection", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "AlmaHeaderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSeparator", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaLoading", { default = true, link = "DiagnosticInfo" })
end

local function add(lines, value)
  local text_lines = util.split_lines(value)
  if #text_lines == 0 then
    table.insert(lines, "")
  else
    for _, line in ipairs(text_lines) do
      table.insert(lines, line)
    end
  end
  return #lines
end

local function add_text(lines, value)
  local text_lines = util.split_lines(value)
  if #text_lines == 0 then
    add(lines, "")
    return
  end
  for _, line in ipairs(text_lines) do
    add(lines, line)
  end
end

local function stringify(value)
  if value == nil then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  return vim.inspect(value)
end

local function is_long(text)
  local opts = config.get()
  if #text > opts.long_output_bytes then
    return true
  end
  local _, count = text:gsub("\n", "")
  return count + 1 > opts.long_output_lines
end

local function model_label(value)
  value = tostring(value or "")
  if value == "" then
    return nil
  end
  return value:match("([^:]+)$") or value
end

local function context_label(thread, block)
  if block and block.context_count and block.context_count > 0 then
    return "ctx " .. tostring(block.context_count)
  end
  local usage = thread.context_usage
  if type(usage) ~= "table" then
    return nil
  end
  local used = usage.used or usage.tokens or usage.inputTokens
  local total = usage.total or usage.limit or usage.max
  if used and total then
    return "ctx " .. tostring(used) .. "/" .. tostring(total)
  end
  if used then
    return "ctx " .. tostring(used)
  end
  return nil
end

local function assistant_meta(thread, block)
  local meta = {}
  local request = thread.pending_request
  local model = request and request.spec and request.spec.model or thread.config.model
  local reasoning = request and request.spec and request.spec.reasoning_effort or thread.config.reasoning_effort
  local model_name = model_label(model)
  if model_name then
    table.insert(meta, model_name)
  end
  if reasoning and reasoning ~= "" then
    table.insert(meta, "effort " .. tostring(reasoning))
  end
  if block and block.state and block.state ~= "" and block.state ~= "done" then
    table.insert(meta, tostring(block.state))
  end
  return meta
end

local function header_hl(kind)
  if kind == "user" then
    return "AlmaHeaderUser"
  end
  if kind == "assistant" then
    return "AlmaHeaderAssistant"
  end
  return "AlmaHeaderSection"
end

local function mark_header(thread, line, kind, title, meta, block)
  table.insert(thread.header_marks, {
    line = line,
    kind = kind,
    title = title,
    meta = meta or {},
    block = block,
  })
end

local function header_virt_text(mark)
  local title = " " .. tostring(mark.title or "") .. " "
  local chunks = { { title, header_hl(mark.kind) } }
  if mark.meta and #mark.meta > 0 then
    table.insert(chunks, { " " .. table.concat(mark.meta, " · ") .. " ", "AlmaHeaderMeta" })
  end
  local used = vim.fn.strdisplaywidth(table.concat(vim.tbl_map(function(chunk)
    return chunk[1]
  end, chunks), ""))
  local sep = config.get().render.separator or "───"
  local remaining = math.max(3, vim.o.columns - used - 1)
  table.insert(chunks, { string.rep(sep, math.max(1, math.ceil(remaining / #sep))), "AlmaHeaderSeparator" })
  return chunks
end

local function apply_header_marks(thread, bufnr)
  for _, mark in ipairs(thread.header_marks or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, {
      conceal = "",
      virt_text = header_virt_text(mark),
      virt_text_pos = "overlay",
      priority = 2000,
      strict = false,
    })
    if mark.block then
      thread.render_index[mark.line] = mark.block
    end
  end
end

local function render_tool(thread, lines, block)
  local title = "Tool: " .. tostring(block.tool or "unknown")
  if block.state then
    title = title .. " [" .. tostring(block.state) .. "]"
  end
  local line = add(lines, "### " .. title)
  mark_header(thread, line, "section", title, {}, block)
  if block.tool_call_id then
    add(lines, "tool_call_id: " .. tostring(block.tool_call_id))
  end
  if block.input ~= nil then
    add(lines, "input:")
    add_text(lines, stringify(block.input))
  end
  if block.output ~= nil then
    local output = stringify(block.output)
    if is_long(output) then
      add(lines, "output: [long output available with :AlmaToolDetails]")
    else
      add(lines, "output:")
      add_text(lines, output)
    end
  elseif block.text and block.text ~= "" then
    add_text(lines, block.text)
  end
end

local function render_block(thread, lines, block, opts)
  opts = opts or {}
  local start = #lines + 1
  if block.type == "UserBlock" then
    local line = add(lines, "## You")
    local meta = {}
    if block.state and block.state ~= "" then
      table.insert(meta, tostring(block.state))
    end
    local ctx = context_label(thread, block)
    if ctx then
      table.insert(meta, ctx)
    end
    mark_header(thread, line, "user", "You", meta, block)
    add_text(lines, block.text)
  elseif block.type == "AssistantBlock" then
    if not opts.assistant_body then
      local line = add(lines, "## Alma")
      mark_header(thread, line, "assistant", "Alma", assistant_meta(thread, block), block)
      add(lines, "")
    end
    add_text(lines, block.text)
  elseif block.type == "ReasoningBlock" then
    local title = "Reasoning" .. (block.state and (" [" .. block.state .. "]") or "")
    local line = add(lines, "### " .. title)
    mark_header(thread, line, "section", title, {}, block)
    add_text(lines, events.block_text(block))
  elseif block.type == "ToolCallBlock" then
    render_tool(thread, lines, block)
  elseif block.type == "AgentTimelineBlock" then
    local title = "Agent Timeline: " .. tostring(block.title or "event")
    local line = add(lines, "### " .. title)
    mark_header(thread, line, "section", title, {}, block)
    add_text(lines, events.block_text(block))
  elseif block.type == "RawEventBlock" then
    local title = "Raw Event: " .. tostring(block.title or "unknown")
    local line = add(lines, "### " .. title)
    mark_header(thread, line, "section", title, {}, block)
    add_text(lines, vim.inspect(block.raw or block))
  elseif block.type == "ErrorBlock" then
    local line = add(lines, "### Error")
    mark_header(thread, line, "section", "Error", {}, block)
    add_text(lines, events.block_text(block))
  else
    local title = tostring(block.type or "Block")
    local line = add(lines, "### " .. title)
    mark_header(thread, line, "section", title, {}, block)
    add_text(lines, events.block_text(block))
  end

  local finish = #lines
  for lnum = start, finish do
    thread.render_index[lnum] = block
  end
  if foldable_types[block.type] and finish > start then
    table.insert(thread.folds, { start = start, finish = finish })
  end
  add(lines, "")
end

local function assistant_group_id(block)
  if not block or not block.message_id or not assistant_content_types[block.type] then
    return nil
  end
  return block.message_id
end

local function render_assistant_group(thread, lines, blocks, index)
  local group_id = assistant_group_id(blocks[index])
  local first_block = blocks[index]
  local line = add(lines, "## Alma")
  mark_header(thread, line, "assistant", "Alma", assistant_meta(thread, first_block), first_block)
  add(lines, "")

  while index <= #blocks and assistant_group_id(blocks[index]) == group_id do
    render_block(thread, lines, blocks[index], { assistant_body = true })
    index = index + 1
  end
  return index
end

local function existing_prompt(thread)
  if not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) or not thread.prompt_start then
    return { "" }
  end
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, thread.bufnr, thread.prompt_start, -1, false)
  if ok and #lines > 0 then
    return lines
  end
  return { "" }
end

local function header(thread)
  local parts = {
    "# Alma: " .. tostring(thread.title or thread.id),
    "thread: " .. tostring(thread.id),
    "cwd: " .. tostring(thread.cwd or ""),
    "transport: " .. tostring(thread.transport),
    "generation: " .. tostring(thread.generation),
    "sync: " .. tostring(thread.sync),
  }
  if thread.status_message then
    table.insert(parts, "status: " .. tostring(thread.status_message))
  end
  if thread.last_error then
    table.insert(parts, "last_error: " .. tostring(thread.last_error))
  end
  return parts
end

local function buffer_locked(thread)
  return thread.pending_request ~= nil or thread.generation ~= "idle" or #(thread.queue or {}) > 0
end

function _G.AlmaFoldExpr(lnum)
  local thread = require("alma.state").thread_for_buf(0)
  if not thread then
    return "0"
  end
  for _, fold in ipairs(thread.folds or {}) do
    if lnum == fold.start then
      return ">1"
    end
    if lnum > fold.start and lnum < fold.finish then
      return "1"
    end
    if lnum == fold.finish then
      return "<1"
    end
  end
  return "0"
end

function M.select_render_tree(thread)
  local blocks = {}
  util.list_extend(blocks, thread.blocks or {})
  util.list_extend(blocks, thread.local_blocks or {})
  if config.get().render.show_raw_events then
    util.list_extend(blocks, thread.raw_blocks or {})
  end
  return blocks
end

function M.render(thread)
  if not thread or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return
  end

  setup_highlights()

  local bufnr = thread.bufnr
  local locked = buffer_locked(thread)
  local prompt = locked and { "" } or (thread.prompt_lines or existing_prompt(thread))
  thread.prompt_lines = nil
  thread.render_index = {}
  thread.header_marks = {}
  thread.folds = {}

  local lines = {}
  for _, line in ipairs(header(thread)) do
    add(lines, line)
  end
  add(lines, "")

  local blocks = M.select_render_tree(thread)
  local index = 1
  while index <= #blocks do
    if assistant_group_id(blocks[index]) then
      index = render_assistant_group(thread, lines, blocks, index)
    else
      render_block(thread, lines, blocks[index])
      index = index + 1
    end
  end

  if not locked then
    local line = add(lines, config.get().render.prompt_marker)
    mark_header(thread, line, "user", "You", {}, nil)
    local prompt_start = #lines
    for _, prompt_line in ipairs(#prompt > 0 and prompt or { "" }) do
      add(lines, prompt_line)
    end
    thread.prompt_start = prompt_start
  else
    thread.prompt_start = nil
  end

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  apply_header_marks(thread, bufnr)
  vim.bo[bufnr].modifiable = not locked

  local virt = {
    { "model: " .. tostring(model_label(thread.config.model) or "default"), "Comment" },
    { " / reasoning: " .. tostring(thread.config.reasoning_effort or "default"), "Comment" },
  }
  if thread.context_usage then
    table.insert(virt, { " / " .. tostring(context_label(thread) or "context"), "Comment" })
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
    virt_text = virt,
    virt_text_pos = "right_align",
  })

  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].foldmethod = "expr"
      vim.wo[win].foldexpr = "v:lua.AlmaFoldExpr(v:lnum)"
      vim.wo[win].foldlevel = 0
      vim.wo[win].wrap = true
      vim.wo[win].conceallevel = math.max(vim.wo[win].conceallevel, 1)
    end
  end
end

return M
