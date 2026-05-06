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

local function render_tool(lines, block)
  add(lines, "### Tool: " .. tostring(block.tool or "unknown") .. (block.state and (" [" .. block.state .. "]") or ""))
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
    add(lines, "## You" .. (block.state and (" [" .. block.state .. "]") or ""))
    add_text(lines, block.text)
  elseif block.type == "AssistantBlock" then
    if not opts.assistant_body then
      add(lines, "## Alma" .. (block.state and (" [" .. block.state .. "]") or ""))
    end
    add_text(lines, block.text)
  elseif block.type == "ReasoningBlock" then
    add(lines, "### Reasoning" .. (block.state and (" [" .. block.state .. "]") or ""))
    add_text(lines, events.block_text(block))
  elseif block.type == "ToolCallBlock" then
    render_tool(lines, block)
  elseif block.type == "AgentTimelineBlock" then
    add(lines, "### Agent Timeline: " .. tostring(block.title or "event"))
    add_text(lines, events.block_text(block))
  elseif block.type == "RawEventBlock" then
    add(lines, "### Raw Event: " .. tostring(block.title or "unknown"))
    add_text(lines, vim.inspect(block.raw or block))
  elseif block.type == "ErrorBlock" then
    add(lines, "### Error")
    add_text(lines, events.block_text(block))
  else
    add(lines, "### " .. tostring(block.type or "Block"))
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
  local start = #lines + 1
  add(lines, "## Alma")
  for lnum = start, #lines do
    thread.render_index[lnum] = first_block
  end
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
    table.insert(parts, "status: " .. thread.status_message)
  end
  if thread.last_error then
    table.insert(parts, "last_error: " .. tostring(thread.last_error))
  end
  return parts
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

  local bufnr = thread.bufnr
  local prompt = thread.prompt_lines or existing_prompt(thread)
  thread.prompt_lines = nil
  thread.render_index = {}
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

  add(lines, config.get().render.prompt_marker)
  local prompt_start = #lines
  for _, line in ipairs(#prompt > 0 and prompt or { "" }) do
    add(lines, line)
  end
  thread.prompt_start = prompt_start

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.bo[bufnr].modifiable = true

  local virt = {
    { "model: " .. tostring(thread.config.model or "default"), "Comment" },
    { " / reasoning: " .. tostring(thread.config.reasoning_effort or "default"), "Comment" },
  }
  if thread.context_usage then
    table.insert(virt, { " / context: " .. tostring(thread.context_usage.used or thread.context_usage.tokens or "?"), "Comment" })
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
    end
  end
end

return M
