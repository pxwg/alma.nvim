local config = require("alma.config")
local events = require("alma.events")
local metadata = require("alma.ui.metadata")
local tokens = require("alma.ui.tokens")
local util = require("alma.util")

local M = {}

local ns = vim.api.nvim_create_namespace("alma.nvim")
local follow_threshold = 5
local pending_render_timers = {}

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

local composer_token_prefixes = {
  ["/"] = true,
  ["@"] = true,
  ["$"] = true,
}

local composer_trailing_punctuation = {
  [","] = true,
  ["."] = true,
  [";"] = true,
  ["!"] = true,
  ["?"] = true,
  [")"] = true,
  ["]"] = true,
  ["}"] = true,
}

local stream_decoration_by_type = {
  ToolCallBlock = { kind = "tool", marker = "▌ ", hl_group = "AlmaStreamTool" },
  ToolOutputBlock = { kind = "tool", marker = "▌ ", hl_group = "AlmaStreamTool" },
  AgentTimelineBlock = { kind = "timeline", marker = "▎ ", hl_group = "AlmaStreamTimeline" },
  RawEventBlock = { kind = "raw_event", marker = "╎ ", hl_group = "AlmaStreamRaw" },
}

local subagent_decoration = { kind = "subagent", marker = "▸ ", hl_group = "AlmaStreamSubAgent" }

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AlmaHeaderUser", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "AlmaHeaderAssistant", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSection", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "AlmaHeaderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSeparator", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaLoading", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AlmaReasoningText", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaReasoningBorder", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "AlmaComposerCommand", { default = true, link = "Statement" })
  vim.api.nvim_set_hl(0, "AlmaComposerMention", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "AlmaComposerSelector", { default = true, link = "Constant" })
  vim.api.nvim_set_hl(0, "AlmaStreamTool", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AlmaStreamTimeline", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "AlmaStreamRaw", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AlmaStreamSubAgent", { default = true, link = "DiagnosticOk" })
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

local function first_string(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

local function normalize_key(value)
  if type(value) ~= "string" then
    return ""
  end
  return value:gsub("[^%w]", ""):lower()
end

local function is_subagent_value(value)
  local normalized = normalize_key(value)
  return normalized == "subagent" or vim.startswith(normalized, "subagent")
end

local function is_subagent_block_type(value)
  local normalized = normalize_key(value)
  return vim.startswith(normalized, "subagent") and normalized:match("block$") ~= nil
end

local function is_subagent_event_name(value)
  return is_subagent_value(value)
end

local subagent_metadata_keys = {
  subagent = true,
  subagentid = true,
  subagentname = true,
  subagentrole = true,
  subagenttype = true,
  subagentmodel = true,
}

local subagent_value_keys = {
  kind = true,
  origin = true,
  role = true,
  source = true,
  stream = true,
  type = true,
}

local function metadata_has_subagent_signal(value)
  if type(value) ~= "table" then
    return false
  end
  for key, item in pairs(value) do
    local normalized_key = normalize_key(key)
    if subagent_metadata_keys[normalized_key] then
      if item ~= false and item ~= nil and item ~= "" then
        return true
      end
    end
    if subagent_value_keys[normalized_key] and is_subagent_value(item) then
      return true
    end
  end
  return false
end

local function event_name_from(value)
  if type(value) ~= "table" then
    return nil
  end
  return first_string(value.event_type, value.eventType, value.event_name, value.eventName, value.name, value.event, value.type)
end

local function block_has_subagent_signal(block)
  if type(block) ~= "table" then
    return false
  end
  if is_subagent_block_type(block.type) then
    return true
  end
  if is_subagent_event_name(first_string(block.event_type, block.eventType, block.event_name, block.eventName, block.name)) then
    return true
  end
  if metadata_has_subagent_signal(block.metadata) then
    return true
  end
  local raw = block.raw
  if type(raw) ~= "table" then
    return false
  end
  if is_subagent_event_name(event_name_from(raw)) then
    return true
  end
  local data = type(raw.data) == "table" and raw.data or {}
  return metadata_has_subagent_signal(raw.metadata)
    or metadata_has_subagent_signal(raw.userMessageMetadata)
    or metadata_has_subagent_signal(raw.context)
    or metadata_has_subagent_signal(data)
    or metadata_has_subagent_signal(data.context)
end

local function stream_decoration_for_block(block)
  if not block or block.type == "ReasoningBlock" then
    return nil
  end
  if block.type ~= "RawEventBlock" and stream_decoration_by_type[block.type] then
    return stream_decoration_by_type[block.type]
  end
  if block_has_subagent_signal(block) then
    return subagent_decoration
  end
  return stream_decoration_by_type[block.type]
end

local function is_long(text)
  local opts = config.get()
  if #text > opts.long_output_bytes then
    return true
  end
  local _, count = text:gsub("\n", "")
  return count + 1 > opts.long_output_lines
end

local function assistant_meta(thread, block)
  local request = block and block.local_only and thread.pending_request or nil
  return metadata.assistant_labels(thread, block, request)
end

local function user_meta(thread, block)
  local request = block and block.local_only and thread.pending_request or nil
  local labels = metadata.user_labels(thread, block, request)
  if block and block.state and block.state ~= "" then
    table.insert(labels, tostring(block.state))
  end
  local ctx = metadata.context_label(thread, block)
  if ctx then
    table.insert(labels, ctx)
  end
  return labels
end

local function composer_meta(thread)
  local labels = metadata.composer_labels(thread)
  local ctx = metadata.context_label(thread)
  if ctx then
    table.insert(labels, ctx)
  end
  return labels
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

local function mark_reasoning_lines(thread, start_line, finish_line)
  if finish_line < start_line then
    return
  end
  table.insert(thread.reasoning_marks, {
    start_line = start_line,
    finish_line = finish_line,
  })
end

local function mark_stream_decoration(thread, start_line, finish_line, decoration, block)
  if not decoration or finish_line < start_line then
    return
  end
  table.insert(thread.stream_decoration_marks, {
    start_line = start_line,
    finish_line = finish_line,
    kind = decoration.kind,
    marker = decoration.marker,
    hl_group = decoration.hl_group,
    block = block,
  })
end

local function chunks_width(chunks)
  local width = 0
  for _, chunk in ipairs(chunks or {}) do
    width = width + vim.fn.strdisplaywidth(chunk[1] or "")
  end
  return width
end

local function repeat_to_width(text, target_width)
  local unit_width = math.max(1, vim.fn.strdisplaywidth(text))
  return string.rep(text, math.max(1, math.ceil(target_width / unit_width)))
end

local function window_text_width(win)
  local width = vim.api.nvim_win_get_width(win)
  local ok, info = pcall(vim.fn.getwininfo, win)
  if ok and info and info[1] and info[1].textoff then
    width = width - info[1].textoff
  end
  return math.max(20, width)
end

local function header_target_width(bufnr)
  local width = vim.o.columns
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      width = math.max(width, window_text_width(win))
    end
  end
  return width + 32
end

local function header_virt_text(mark, target_width)
  local title = " " .. tostring(mark.title or "") .. " "
  local chunks = { { title, header_hl(mark.kind) } }
  if mark.meta and #mark.meta > 0 then
    table.insert(chunks, { " " .. table.concat(mark.meta, " · ") .. " ", "AlmaHeaderMeta" })
  end
  local sep = config.get().render.separator or "───"
  local remaining = math.max(vim.fn.strdisplaywidth(sep), target_width - chunks_width(chunks))
  table.insert(chunks, { repeat_to_width(sep, remaining), "AlmaHeaderSeparator" })
  return chunks
end

local function apply_header_marks(thread, bufnr)
  local target_width = header_target_width(bufnr)
  for _, mark in ipairs(thread.header_marks or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, {
      conceal = "",
      virt_text = header_virt_text(mark, target_width),
      virt_text_pos = "overlay",
      priority = 2000,
      strict = false,
    })
    if mark.block then
      thread.render_index[mark.line] = mark.block
    end
  end
end

local function apply_reasoning_marks(thread, bufnr)
  for _, mark in ipairs(thread.reasoning_marks or {}) do
    for lnum = mark.start_line, mark.finish_line do
      local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        virt_text = { { "▏ ", "AlmaReasoningBorder" } },
        virt_text_pos = "inline",
        priority = 1200,
        strict = false,
      })
      if line ~= "" then
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
          end_col = #line,
          hl_group = "AlmaReasoningText",
          hl_mode = "combine",
          priority = 900,
          strict = false,
        })
      end
    end
  end
end

local function apply_stream_decoration_marks(thread, bufnr)
  for _, mark in ipairs(thread.stream_decoration_marks or {}) do
    for lnum = mark.start_line, mark.finish_line do
      vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
        virt_text = { { mark.marker, mark.hl_group } },
        virt_text_pos = "inline",
        priority = 1100,
        strict = false,
      })
    end
  end
end

local function composer_token_hl(classified)
  if not classified or not classified.valid or classified.fallback then
    return nil
  end
  if classified.kind == "slash_command" or classified.kind == "skill" then
    return "AlmaComposerCommand"
  end
  if classified.kind == "mention" then
    return "AlmaComposerMention"
  end
  if classified.kind == "selector" then
    return "AlmaComposerSelector"
  end
  return nil
end

local function composer_token_boundary(line, index)
  if index <= 1 then
    return true
  end
  return line:sub(index - 1, index - 1):match("%s") ~= nil
end

local function composer_candidate_end(line, index)
  local pos = index
  while pos <= #line do
    if line:sub(pos, pos):match("%s") then
      break
    end
    pos = pos + 1
  end
  return pos - 1
end

local function trim_composer_candidate(raw)
  local finish = #raw
  while finish > 1 and composer_trailing_punctuation[raw:sub(finish, finish)] do
    finish = finish - 1
  end
  return raw:sub(1, finish)
end

local function next_composer_candidate(line, start_index)
  local index = start_index
  while index <= #line do
    local ch = line:sub(index, index)
    if composer_token_prefixes[ch] and composer_token_boundary(line, index) then
      local raw_finish = composer_candidate_end(line, index)
      local token = trim_composer_candidate(line:sub(index, raw_finish))
      if #token > 1 then
        return index, index + #token - 1, token, raw_finish + 1
      end
      index = raw_finish + 1
    else
      index = index + 1
    end
  end
  return nil
end

local function apply_composer_token_marks(thread, bufnr)
  thread.composer_token_marks = {}
  if not thread.prompt_start then
    return
  end

  local lines = vim.api.nvim_buf_get_lines(bufnr, thread.prompt_start, -1, false)
  for offset, line in ipairs(lines) do
    local lnum0 = thread.prompt_start + offset - 1
    local search_from = 1
    while search_from <= #line do
      local start_col1, finish_col1, token, next_index = next_composer_candidate(line, search_from)
      if not start_col1 then
        break
      end

      local classified = tokens.classify(token, { thread = thread })
      local hl_group = composer_token_hl(classified)
      if hl_group then
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum0, start_col1 - 1, {
          end_col = finish_col1,
          hl_group = hl_group,
          hl_mode = "combine",
          priority = 1300,
          strict = false,
        })
        table.insert(thread.composer_token_marks, {
          line = lnum0 + 1,
          col = start_col1 - 1,
          end_col = finish_col1,
          token = token,
          kind = classified.kind,
          hl_group = hl_group,
        })
      end

      search_from = next_index
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
    mark_header(thread, line, "user", "You", user_meta(thread, block), block)
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
    local body_start = #lines + 1
    add_text(lines, events.block_text(block))
    mark_reasoning_lines(thread, body_start, #lines)
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
  local stream_decoration = stream_decoration_for_block(block)
  if stream_decoration then
    local decoration_start = finish > start and start + 1 or start
    mark_stream_decoration(thread, decoration_start, finish, stream_decoration, block)
  end
  add(lines, "")
end

local function assistant_group_id(block)
  if not block or not assistant_content_types[block.type] then
    return nil
  end
  if block.message_id then
    return block.message_id
  end
  if block.local_only then
    return "__local_assistant__"
  end
  return nil
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

local function ensure_view_state(thread)
  thread.view_state = thread.view_state or {}
  return thread.view_state
end

local function view_state_for_win(thread, win)
  local states = ensure_view_state(thread)
  states[win] = states[win] or {
    follow = nil,
    suspended_by_user = false,
    programmatic = 0,
    last_programmatic = false,
  }
  return states[win]
end

local function valid_window_for_buffer(win, bufnr)
  return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr
end

local function window_info(win)
  local ok, info = pcall(vim.fn.getwininfo, win)
  if ok and info and info[1] then
    return info[1]
  end
  return nil
end

local function cursor_line(win)
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  if ok and cursor then
    return cursor[1]
  end
  return 1
end

local function clamp_lnum(lnum, line_count)
  return math.min(math.max(tonumber(lnum) or 1, 1), math.max(1, line_count))
end

local function line_col(bufnr, lnum, col)
  local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1] or ""
  return math.min(tonumber(col) or 0, #line)
end

local function save_window_view(win)
  local ok, view = pcall(vim.api.nvim_win_call, win, function()
    return vim.fn.winsaveview()
  end)
  if ok then
    return view
  end
  return nil
end

local function with_programmatic_view(thread, win, fn)
  local state = view_state_for_win(thread, win)
  state.programmatic = (state.programmatic or 0) + 1
  state.last_programmatic = true
  local ok, err = pcall(fn)
  state.programmatic = math.max((state.programmatic or 1) - 1, 0)
  if not ok then
    error(err)
  end
end

local function restore_window_view(thread, win, snapshot)
  local bufnr = thread.bufnr
  if not snapshot or not snapshot.view or not valid_window_for_buffer(win, bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local view = vim.deepcopy(snapshot.view)
  view.lnum = clamp_lnum(view.lnum, line_count)
  view.topline = clamp_lnum(view.topline, line_count)
  view.col = line_col(bufnr, view.lnum, view.col)
  view.curswant = view.curswant or view.col
  with_programmatic_view(thread, win, function()
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
  end)
end

local function follow_cursor_line(thread, line_count)
  if thread.prompt_start then
    return clamp_lnum(thread.prompt_start + 1, line_count)
  end
  return line_count
end

local function anchor_follow_window(thread, win)
  local bufnr = thread.bufnr
  if not valid_window_for_buffer(win, bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local lnum = follow_cursor_line(thread, line_count)
  local col = line_col(bufnr, lnum, 0)
  local height = math.max(1, vim.api.nvim_win_get_height(win))
  local topline = math.max(1, line_count - height + 1)
  with_programmatic_view(thread, win, function()
    vim.api.nvim_win_set_cursor(win, { lnum, col })
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview({
        lnum = lnum,
        col = col,
        curswant = col,
        topline = topline,
        leftcol = 0,
        skipcol = 0,
      })
    end)
    vim.api.nvim_win_set_cursor(win, { lnum, col })
  end)
  local state = view_state_for_win(thread, win)
  state.follow = true
  state.suspended_by_user = false
end

local function cursor_near_bottom(thread, win)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return false
  end
  local line_count = vim.api.nvim_buf_line_count(thread.bufnr)
  local lnum = cursor_line(win)
  if line_count - lnum <= follow_threshold then
    return true
  end
  if thread.prompt_start and lnum >= math.max(1, thread.prompt_start - follow_threshold) then
    return true
  end
  return false
end

local function viewport_near_bottom(thread, win)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return false
  end
  local line_count = vim.api.nvim_buf_line_count(thread.bufnr)
  local info = window_info(win)
  local botline = info and info.botline or cursor_line(win)
  return line_count - botline <= follow_threshold
end

function M.window_near_bottom(thread, win)
  return cursor_near_bottom(thread, win) or viewport_near_bottom(thread, win)
end

function M.prepare_submit_follow(thread, win)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return
  end
  local state = view_state_for_win(thread, win)
  local follow = M.window_near_bottom(thread, win)
  state.follow = follow
  state.suspended_by_user = not follow
end

function M.on_user_view_changed(thread, win, source)
  if not thread or not thread.bufnr or not valid_window_for_buffer(win, thread.bufnr) then
    return
  end
  local state = view_state_for_win(thread, win)
  if (state.programmatic or 0) > 0 then
    return
  end
  local follow = source == "viewport" and viewport_near_bottom(thread, win) or cursor_near_bottom(thread, win)
  state.follow = follow
  state.suspended_by_user = not follow
end

local function capture_window_views(thread, bufnr)
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_window_for_buffer(win, bufnr) then
      local state = view_state_for_win(thread, win)
      local near_bottom = M.window_near_bottom(thread, win)
      if state.suspended_by_user and cursor_near_bottom(thread, win) then
        state.follow = true
        state.suspended_by_user = false
      elseif state.suspended_by_user then
        state.follow = false
      elseif near_bottom then
        state.follow = true
        state.suspended_by_user = false
      elseif state.follow == true then
        state.follow = false
        state.suspended_by_user = true
      elseif state.follow == nil then
        state.follow = false
        state.suspended_by_user = true
      end
      snapshots[win] = {
        view = save_window_view(win),
        follow = state.follow == true and state.suspended_by_user ~= true,
      }
    end
  end
  return snapshots
end

local function apply_window_views(thread, bufnr, snapshots)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_window_for_buffer(win, bufnr) then
      local snapshot = snapshots[win]
      vim.wo[win].foldmethod = "expr"
      vim.wo[win].foldexpr = "v:lua.AlmaFoldExpr(v:lnum)"
      vim.wo[win].foldlevel = 0
      vim.wo[win].wrap = true
      vim.wo[win].conceallevel = math.max(vim.wo[win].conceallevel, 1)
      if snapshot and snapshot.follow then
        anchor_follow_window(thread, win)
      elseif snapshot then
        restore_window_view(thread, win, snapshot)
      end
    end
  end
end

local function prune_view_states(thread, bufnr)
  for win, _ in pairs(thread.view_state or {}) do
    if not valid_window_for_buffer(win, bufnr) then
      thread.view_state[win] = nil
    end
  end
end

local function build_fold_levels(thread)
  local levels = {}
  for _, fold in ipairs(thread.folds or {}) do
    levels[fold.start] = ">1"
    for lnum = fold.start + 1, fold.finish - 1 do
      levels[lnum] = "1"
    end
    levels[fold.finish] = "<1"
  end
  thread.fold_levels = levels
end

local function suspend_window_folds(bufnr)
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == bufnr then
      snapshots[win] = {
        foldmethod = vim.wo[win].foldmethod,
        foldenable = vim.wo[win].foldenable,
      }
      vim.wo[win].foldmethod = "manual"
      vim.wo[win].foldenable = false
    end
  end
  return snapshots
end

local function restore_suspended_folds(snapshots)
  for win, snapshot in pairs(snapshots or {}) do
    if vim.api.nvim_win_is_valid(win) then
      vim.wo[win].foldmethod = snapshot.foldmethod
      vim.wo[win].foldenable = snapshot.foldenable
    end
  end
end

local function replace_buffer_lines(bufnr, lines)
  local fold_snapshots = suspend_window_folds(bufnr)
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, lines)
  restore_suspended_folds(fold_snapshots)
  if not ok then
    error(err)
  end
end

function _G.AlmaFoldExpr(lnum)
  local thread = require("alma.state").thread_for_buf(0)
  if not thread then
    return "0"
  end
  return (thread.fold_levels and thread.fold_levels[lnum]) or "0"
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
  local snapshots = capture_window_views(thread, bufnr)
  local prompt = thread.prompt_lines or existing_prompt(thread)
  thread.prompt_lines = nil
  thread.render_index = {}
  thread.header_marks = {}
  thread.reasoning_marks = {}
  thread.stream_decoration_marks = {}
  thread.composer_token_marks = {}
  thread.folds = {}
  thread.fold_levels = {}

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

  local line = add(lines, config.get().render.prompt_marker)
  mark_header(thread, line, "user", "You", composer_meta(thread), nil)
  local prompt_start = #lines
  for _, prompt_line in ipairs(#prompt > 0 and prompt or { "" }) do
    add(lines, prompt_line)
  end
  thread.prompt_start = prompt_start
  build_fold_levels(thread)

  vim.bo[bufnr].modifiable = true
  replace_buffer_lines(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  apply_header_marks(thread, bufnr)
  apply_reasoning_marks(thread, bufnr)
  apply_stream_decoration_marks(thread, bufnr)
  apply_composer_token_marks(thread, bufnr)
  vim.bo[bufnr].modifiable = true

  local virt = {
    { "model: " .. tostring(metadata.model_label(thread.config.model) or "default"), "Comment" },
    { " / reasoning: " .. tostring(thread.config.reasoning_effort or "default"), "Comment" },
  }
  local ctx = metadata.context_label(thread)
  if ctx then
    table.insert(virt, { " / " .. tostring(ctx), "Comment" })
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
    virt_text = virt,
    virt_text_pos = "right_align",
  })

  apply_window_views(thread, bufnr, snapshots)
  prune_view_states(thread, bufnr)
end

function M.schedule(thread, delay)
  if not thread or not thread.id then
    return
  end
  local key = tostring(thread.id)
  if pending_render_timers[key] then
    return
  end
  pending_render_timers[key] = vim.defer_fn(function()
    pending_render_timers[key] = nil
    M.render(thread)
  end, delay or config.get().render_debounce_ms)
end

return M
