local config = require("alma.config")
local events = require("alma.events")
local util = require("alma.util")

local M = {}

local ns = vim.api.nvim_create_namespace("alma.nvim")
local follow_threshold = 5

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
  vim.api.nvim_set_hl(0, "AlmaReasoningText", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaReasoningBorder", { default = true, link = "DiagnosticHint" })
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
  local model = block and block.request_model or request and request.spec and request.spec.model or thread.config.model
  local reasoning = block and block.request_reasoning_effort
    or request and request.spec and request.spec.reasoning_effort
    or thread.config.reasoning_effort
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

local function mark_reasoning_lines(thread, start_line, finish_line)
  if finish_line < start_line then
    return
  end
  table.insert(thread.reasoning_marks, {
    start_line = start_line,
    finish_line = finish_line,
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
  local snapshots = capture_window_views(thread, bufnr)
  local prompt = locked and { "" } or (thread.prompt_lines or existing_prompt(thread))
  thread.prompt_lines = nil
  thread.render_index = {}
  thread.header_marks = {}
  thread.reasoning_marks = {}
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
  apply_reasoning_marks(thread, bufnr)
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

  apply_window_views(thread, bufnr, snapshots)
  prune_view_states(thread, bufnr)
end

return M
