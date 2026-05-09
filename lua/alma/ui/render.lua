local config = require("alma.config")
local events = require("alma.events")
local metadata = require("alma.ui.metadata")
local tokens = require("alma.ui.tokens")
local tool_renderers = require("alma.ui.tool_renderers")
local util = require("alma.util")

local M = {}

local ns = vim.api.nvim_create_namespace("alma.nvim")
local follow_threshold = 5
local pending_render_timers = {}
local pending_spinner_timers = {}

local foldable_types = {}

local placeholder_types = {
  ReasoningBlock = true,
  ToolCallBlock = true,
  ToolOutputBlock = true,
  RawEventBlock = true,
  AgentTimelineBlock = true,
  QueuedBlock = true,
}

local assistant_content_types = {
  AssistantBlock = true,
  ReasoningBlock = true,
  ToolCallBlock = true,
  ToolOutputBlock = true,
  RawEventBlock = true,
  AgentTimelineBlock = true,
  QueuedBlock = true,
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
local subagent_header_groups = {
  "AlmaHeaderSubAgent1",
  "AlmaHeaderSubAgent2",
  "AlmaHeaderSubAgent3",
  "AlmaHeaderSubAgent4",
  "AlmaHeaderSubAgent5",
}

local function setup_highlights()
  vim.api.nvim_set_hl(0, "AlmaHeaderUser", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "AlmaHeaderAssistant", { default = true, link = "Title" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSubAgent1", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSubAgent2", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSubAgent3", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSubAgent4", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSubAgent5", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSubAgentRole", { default = true, link = "Type" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSubAgentId", { default = true, link = "Constant" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSection", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "AlmaHeaderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaHeaderSeparator", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaLoading", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AlmaSpinner", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AlmaReasoningText", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaReasoningBorder", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "AlmaComposerCommand", { default = true, link = "Statement" })
  vim.api.nvim_set_hl(0, "AlmaComposerMention", { default = true, link = "Identifier" })
  vim.api.nvim_set_hl(0, "AlmaComposerSelector", { default = true, link = "Constant" })
  vim.api.nvim_set_hl(0, "AlmaStreamTool", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaStreamTimeline", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "AlmaStreamRaw", { default = true, link = "DiagnosticWarn" })
  vim.api.nvim_set_hl(0, "AlmaStreamSubAgent", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "AlmaBlockPlaceholder", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaBlockPlaceholderTitle", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "AlmaBlockPlaceholderMeta", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaBlockPlaceholderHint", { default = true, link = "DiagnosticHint" })
  vim.api.nvim_set_hl(0, "AlmaCrewProgressTitle", { default = true, link = "Special" })
  vim.api.nvim_set_hl(0, "AlmaCrewProgressActive", { default = true, link = "DiagnosticInfo" })
  vim.api.nvim_set_hl(0, "AlmaCrewProgressDone", { default = true, link = "DiagnosticOk" })
  vim.api.nvim_set_hl(0, "AlmaCrewProgressError", { default = true, link = "DiagnosticError" })
  vim.api.nvim_set_hl(0, "AlmaCrewProgressPending", { default = true, link = "Comment" })
  vim.api.nvim_set_hl(0, "AlmaCrewProgressMeta", { default = true, link = "Comment" })
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

local function truncate_display(value, limit)
  value = tostring(value or "")
  limit = limit or 96
  if #value <= limit then
    return value
  end
  return value:sub(1, limit - 1) .. "…"
end

local function compact_text(value)
  return tostring(value or ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

local function line_count(value)
  value = tostring(value or "")
  if value == "" then
    return 0
  end
  local _, count = value:gsub("\n", "")
  return count + 1
end

local function virtual_block_config()
  local render_config = config.get().render or {}
  return render_config.virtual_blocks or {}
end

local function default_expanded()
  return virtual_block_config().default_expanded == true
end

local function max_virtual_lines()
  return tonumber(virtual_block_config().max_lines) or 80
end

local function max_virtual_width()
  return tonumber(virtual_block_config().max_width) or 180
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

local function list_value(value)
  return type(value) == "table" and value or {}
end

local function crew_status_symbol(status)
  status = tostring(status or ""):lower()
  if status == "completed" or status == "passed" or status == "accepted" or status == "done" then
    return "✓"
  end
  if status == "failed" or status == "cancelled" or status == "blocked" or status == "output-error" then
    return "✗"
  end
  if status == "active" or status == "running" or status == "queued" then
    return "●"
  end
  return "○"
end

local function crew_status_hl(status)
  status = tostring(status or ""):lower()
  if status == "completed" or status == "passed" or status == "accepted" or status == "done" then
    return "AlmaCrewProgressDone"
  end
  if status == "failed" or status == "cancelled" or status == "blocked" or status == "output-error" then
    return "AlmaCrewProgressError"
  end
  if status == "active" or status == "running" or status == "queued" then
    return "AlmaCrewProgressActive"
  end
  return "AlmaCrewProgressPending"
end

local function crew_phase_label(phase)
  local labels = {
    planning = "Planning",
    contracting = "Contracting",
    generating = "Building",
    evaluating = "Evaluating",
    completed = "Done",
    failed = "Failed",
  }
  return labels[tostring(phase or "")] or "Running"
end

local function crew_progress_bar(done, total, width)
  width = width or 10
  done = tonumber(done) or 0
  total = tonumber(total) or 0
  if total <= 0 then
    return string.rep("░", width)
  end
  local filled = math.max(1, math.min(width, math.floor((done / total) * width + 0.5)))
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function crew_mission_summary(mission)
  local summary = type(mission.summary) == "table" and mission.summary or {}
  if summary.totalRuns ~= nil then
    return summary
  end
  local runs = list_value(mission.runs)
  local computed = { totalRuns = #runs, completedRuns = 0, failedRuns = 0, activeRuns = 0 }
  for _, run in ipairs(runs) do
    if run.status == "completed" then
      computed.completedRuns = computed.completedRuns + 1
    elseif run.status == "failed" or run.status == "cancelled" then
      computed.failedRuns = computed.failedRuns + 1
    elseif run.status == "running" or run.status == "queued" then
      computed.activeRuns = computed.activeRuns + 1
    end
  end
  return computed
end

local function crew_active_sprint(sprints)
  for _, sprint in ipairs(list_value(sprints)) do
    if sprint.status == "active" then
      return sprint
    end
  end
  return nil
end

local function crew_sprint_progress(sprints)
  local passed = 0
  for _, sprint in ipairs(list_value(sprints)) do
    if sprint.status == "passed" then
      passed = passed + 1
    end
  end
  return passed, #list_value(sprints)
end

local function crew_regular_step(mission)
  for _, run in ipairs(list_value(mission.runs)) do
    if run.status == "running" or run.status == "queued" then
      return compact_text(first_string(run.outputSummary, run.inputSummary, run.status) or "Running", 72)
    end
  end
  for _, handoff in ipairs(list_value(mission.handoffs)) do
    if handoff.status == "pending" or handoff.status == "accepted" then
      local packet = type(handoff.packet) == "table" and handoff.packet or {}
      return compact_text(first_string(packet.goal, packet.deliverable, handoff.status) or "Handoff", 72)
    end
  end
  return nil
end

local function crew_mission_progress(mission)
  if mission.harnessMode == "sprint-harness" then
    local done, total = crew_sprint_progress(mission.sprints)
    local active = crew_active_sprint(mission.sprints)
    local step = active and string.format(
      "%s: S%s %s",
      crew_phase_label(mission.currentPhase),
      tostring(active.sprintNumber or active.number or "?"),
      compact_text(active.title or "Sprint", 56)
    ) or crew_phase_label(mission.currentPhase)
    return done, total, step, mission.currentPhase
  end
  local summary = crew_mission_summary(mission)
  local done = tonumber(summary.completedRuns) or 0
  local total = tonumber(summary.totalRuns) or #list_value(mission.runs)
  return done, total, crew_regular_step(mission), mission.status
end

local function crew_progress_virt_lines(thread)
  local lines = {}
  local missions = list_value(thread and thread.agent_crew and thread.agent_crew.missions)
  for _, mission in ipairs(missions) do
    local done, total, step, status = crew_mission_progress(mission)
    local status_hl = crew_status_hl(status or mission.status)
    local title = compact_text(mission.title or "Task", 42)
    local progress = total > 0 and string.format("%d/%d", done, total) or tostring(mission.status or status or "running")
    local chunks = {
      { "  " .. crew_status_symbol(status or mission.status) .. " ", status_hl },
      { title, "AlmaCrewProgressTitle" },
      { " [" .. crew_progress_bar(done, total) .. "] ", "AlmaCrewProgressMeta" },
      { progress, status_hl },
    }
    if step and step ~= "" then
      table.insert(chunks, { " · " .. step, "AlmaCrewProgressMeta" })
    end
    table.insert(lines, chunks)
  end

  if #lines > 0 then
    return lines
  end

  for _, task_id in ipairs(list_value(thread and thread.subagent_order)) do
    local acc = thread.subagent_streams and thread.subagent_streams[task_id]
    if acc then
      local context = acc.context or {}
      local label = first_string(
        context.subAgentName,
        context.subagentName,
        context.agentProfileName,
        context.agentName,
        context.subAgentRole,
        context.subagentRole,
        context.taskId,
        task_id
      ) or "Task"
      local done = acc.is_streaming and 0 or 1
      local status = acc.is_streaming and "running" or "done"
      local status_hl = crew_status_hl(status)
      table.insert(lines, {
        { "  " .. crew_status_symbol(status) .. " ", status_hl },
        { compact_text(label, 42), "AlmaCrewProgressTitle" },
        { " [" .. crew_progress_bar(done, 1) .. "] ", "AlmaCrewProgressMeta" },
        { status, status_hl },
      })
    end
  end
  return #lines > 0 and lines or nil
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
  parenttoolcallid = true,
  subagent = true,
  subagentid = true,
  subagentmessageid = true,
  subagentmodel = true,
  subagentname = true,
  subagentparentmessageid = true,
  subagentrole = true,
  subagenttaskid = true,
  subagenttype = true,
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

local function subagent_label_value(value)
  if type(value) ~= "string" or value == "" then
    return nil
  end
  if #value > 32 then
    return "Subagent " .. util.short_id(value)
  end
  return value
end

local function subagent_label_from(value)
  if type(value) ~= "table" then
    return nil
  end
  return subagent_label_value(first_string(
    value.subAgentName,
    value.subagentName,
    value.agentProfileName,
    value.agentName,
    value.subAgentRole,
    value.subagentRole,
    value.subAgentId,
    value.subagentId,
    value.agentProfileId,
    value.subAgentTaskId,
    value.subagentTaskId,
    value.subAgentMessageId,
    value.subagentMessageId,
    value.parentToolCallId,
    value.parent_tool_call_id,
    value.taskId,
    value.task_id
  ))
end

local function subagent_identity_from(block)
  if type(block) ~= "table" then
    return nil
  end
  local metadata_value = block.metadata or {}
  local raw = block.raw or {}
  local data = type(raw.data) == "table" and raw.data or raw
  return first_string(
    metadata_value.subAgentTaskId,
    metadata_value.subagentTaskId,
    metadata_value.subAgentMessageId,
    metadata_value.subagentMessageId,
    metadata_value.subAgentId,
    metadata_value.subagentId,
    metadata_value.parentToolCallId,
    metadata_value.parent_tool_call_id,
    metadata_value.taskId,
    raw.taskId,
    raw.task_id,
    raw.parentToolCallId,
    raw.parent_tool_call_id,
    data.taskId,
    data.task_id,
    data.parentToolCallId,
    data.parent_tool_call_id,
    data.context and data.context.taskId,
    data.context and data.context.task_id
  )
end

local function subagent_header_hl(block)
  local identity = subagent_identity_from(block) or "subagent"
  local hash = 0
  for index = 1, #identity do
    hash = hash + identity:byte(index)
  end
  return subagent_header_groups[(hash % #subagent_header_groups) + 1]
end

local function meta_entry(text, hl_group)
  if not text or text == "" then
    return nil
  end
  return { text = text, hl_group = hl_group }
end

local function append_meta_entry(labels, text, hl_group)
  local item = meta_entry(text, hl_group)
  if item then
    table.insert(labels, item)
  end
end

local function subagent_values(block)
  local raw = block and block.raw or {}
  local data = type(raw.data) == "table" and raw.data or raw
  local raw_context = type(raw.context) == "table" and raw.context or {}
  local data_context = type(data.context) == "table" and data.context or {}
  return block and block.metadata or {}, raw_context, data_context, data
end

local function subagent_title_label(block)
  local block_metadata, raw_context, data_context, data = subagent_values(block)
  return subagent_label_from(block_metadata)
    or subagent_label_from(raw_context)
    or subagent_label_from(data_context)
    or subagent_label_from(data)
    or "Subagent"
end

local function assistant_title(block)
  if not block_has_subagent_signal(block) then
    return "Alma"
  end
  return "Alma " .. subagent_title_label(block)
end

local function subagent_meta(block)
  local labels = {}
  local block_metadata, raw_context, data_context, data = subagent_values(block)
  local title_label = subagent_title_label(block)
  local status = first_string(block and block.state)
  local role = first_string(
    block_metadata.subAgentRole,
    block_metadata.subagentRole,
    raw_context.subAgentRole,
    raw_context.subagentRole,
    data_context.subAgentRole,
    data_context.subagentRole,
    block_metadata.agentProfileName,
    raw_context.agentProfileName,
    data_context.agentProfileName,
    data.agentProfileName
  )
  local agent_type = first_string(
    block_metadata.subAgentType,
    block_metadata.subagentType,
    raw_context.subAgentType,
    raw_context.subagentType,
    data_context.subAgentType,
    data_context.subagentType,
    block_metadata.agentProfileId,
    raw_context.agentProfileId,
    data_context.agentProfileId,
    data.agentProfileId
  )
  local task_id = first_string(
    block_metadata.subAgentTaskId,
    block_metadata.subagentTaskId,
    block_metadata.subAgentMessageId,
    block_metadata.subagentMessageId,
    block_metadata.parentToolCallId,
    block_metadata.parent_tool_call_id,
    block_metadata.taskId,
    raw_context.taskId,
    raw_context.task_id,
    raw_context.parentToolCallId,
    raw_context.parent_tool_call_id,
    data_context.taskId,
    data_context.task_id,
    data_context.parentToolCallId,
    data_context.parent_tool_call_id,
    data.taskId,
    data.task_id,
    data.parentToolCallId,
    data.parent_tool_call_id
  )

  append_meta_entry(labels, status, status == "streaming" and "AlmaHeaderSubAgentRole" or "AlmaHeaderMeta")
  if role and role ~= title_label then
    append_meta_entry(labels, role, "AlmaHeaderSubAgentRole")
  end
  append_meta_entry(labels, agent_type, "AlmaHeaderSubAgentId")
  if task_id then
    append_meta_entry(labels, "task " .. util.short_id(task_id), "AlmaHeaderSubAgentId")
  end
  return labels
end

local function assistant_meta(thread, block)
  if block_has_subagent_signal(block) then
    return subagent_meta(block)
  end
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

local function header_title_hl(mark)
  if mark.kind == "subagent" then
    return subagent_header_hl(mark.block)
  end
  return header_hl(mark.kind)
end

local function meta_chunk(item)
  if type(item) == "table" then
    return tostring(item.text or item[1] or ""), item.hl_group or item.hl or "AlmaHeaderMeta"
  end
  return tostring(item or ""), "AlmaHeaderMeta"
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

local function mark_spinner(thread, line)
  thread.spinner_mark = { line = line }
  thread.spinner_marks = { line }
end

local function placeholder_hint_key(block)
  if placeholder_types[block.type] then
    return "placeholder"
  end
  return nil
end

local function mark_placeholder(thread, line, key, block, title, meta, body_lines, decoration)
  thread.placeholder_marks = thread.placeholder_marks or {}
  thread.placeholder_index = thread.placeholder_index or {}
  thread.placeholder_hint_seen = thread.placeholder_hint_seen or {}
  local expanded = thread.expanded_blocks and thread.expanded_blocks[key]
  if expanded == nil then
    expanded = default_expanded()
  end
  local hint_key = placeholder_hint_key(block)
  local show_hint = true
  if hint_key then
    show_hint = not thread.placeholder_hint_seen[hint_key]
    thread.placeholder_hint_seen[hint_key] = true
  end
  local mark = {
    line = line,
    key = key,
    block = block,
    title = title,
    meta = meta or {},
    body_lines = body_lines or {},
    expanded = expanded,
    decoration = decoration,
    show_hint = show_hint,
  }
  table.insert(thread.placeholder_marks, mark)
  thread.placeholder_index[line] = mark
  thread.render_index[line] = block
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

local function narrowest_buffer_text_width(bufnr)
  local width = vim.o.columns
  local found = false
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      width = math.min(width, window_text_width(win))
      found = true
    end
  end
  return math.max(20, found and width or vim.o.columns)
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
  local chunks = { { title, header_title_hl(mark) } }
  if mark.meta and #mark.meta > 0 then
    table.insert(chunks, { " ", "AlmaHeaderMeta" })
    for index, item in ipairs(mark.meta) do
      local text, hl_group = meta_chunk(item)
      if text ~= "" then
        if index > 1 then
          table.insert(chunks, { " · ", "AlmaHeaderMeta" })
        end
        table.insert(chunks, { text, hl_group })
      end
    end
    table.insert(chunks, { " ", "AlmaHeaderMeta" })
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

local function placeholder_virt_text(mark)
  local icon = mark.expanded and "▾ " or "▸ "
  local chunks = {
    { icon, mark.decoration and mark.decoration.hl_group or "AlmaBlockPlaceholder" },
    { tostring(mark.title or "Block"), "AlmaBlockPlaceholderTitle" },
  }
  for _, item in ipairs(mark.meta or {}) do
    local text = type(item) == "table" and (item.text or item[1]) or item
    if text and text ~= "" then
      table.insert(chunks, { " · " .. tostring(text), "AlmaBlockPlaceholderMeta" })
    end
  end
  if mark.show_hint ~= false then
    table.insert(chunks, { mark.expanded and " · za collapse" or " · za expand", "AlmaBlockPlaceholderHint" })
  end
  return chunks
end

local function virtual_body_lines(mark)
  if not mark.expanded then
    return nil
  end
  local limit = max_virtual_lines()
  local width = max_virtual_width()
  local lines = {}
  for index, line in ipairs(mark.body_lines or {}) do
    if index > limit then
      table.insert(lines, { { "  … truncated, use :AlmaToolDetails for full content", "AlmaBlockPlaceholderHint" } })
      break
    end
    table.insert(lines, {
      { "  │ ", mark.decoration and mark.decoration.hl_group or "AlmaBlockPlaceholder" },
      { truncate_display(line, width), "AlmaBlockPlaceholder" },
    })
  end
  if #lines == 0 then
    table.insert(lines, { { "  │ (empty)", "AlmaBlockPlaceholderMeta" } })
  end
  return lines
end

local function apply_placeholder_marks(thread, bufnr)
  for _, mark in ipairs(thread.placeholder_marks or {}) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, {
      conceal = "",
      virt_text = placeholder_virt_text(mark),
      virt_text_pos = "overlay",
      virt_lines = virtual_body_lines(mark),
      priority = 1900,
      strict = false,
    })
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

local spinner_virt_text

local function apply_spinner_mark(thread, bufnr, mark)
  if not mark or not mark.line then
    return
  end
  local lnum = mark.line
  if lnum < 1 or lnum > vim.api.nvim_buf_line_count(bufnr) then
    return
  end
  mark.virt_text = spinner_virt_text(thread)
  local opts = {
    conceal = "",
    virt_text = mark.virt_text,
    virt_text_pos = "overlay",
    priority = 1800,
    strict = false,
  }
  if mark.extmark_id then
    opts.id = mark.extmark_id
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, lnum - 1, 0, opts)
  if not ok and opts.id then
    opts.id = nil
    id = vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, opts)
  elseif not ok then
    error(id)
  end
  mark.extmark_id = id
end

local function apply_spinner_marks(thread, bufnr)
  local mark = thread.spinner_mark
  if not mark then
    return
  end
  apply_spinner_mark(thread, bufnr, mark)
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

local function mark_crew_progress(thread, line)
  local virt_lines = crew_progress_virt_lines(thread)
  if virt_lines and #virt_lines > 0 then
    thread.crew_progress_mark = { line = line, virt_lines = virt_lines }
  end
end

local function apply_crew_progress_mark(thread, bufnr)
  local mark = thread.crew_progress_mark
  if not mark or not mark.line or not mark.virt_lines then
    return
  end
  if mark.line < 1 or mark.line > vim.api.nvim_buf_line_count(bufnr) then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, {
    virt_lines = mark.virt_lines,
    virt_lines_above = false,
    priority = 1250,
    strict = false,
  })
end

local function tool_summary(block)
  return tool_renderers.summary(block)
end

local function output_summary(block)
  return tool_renderers.status(block)
end

local render_block
local assistant_group_id

local function tool_title(block)
  local title = tostring(block.tool or "unknown")
  if block.state then
    title = title .. " [" .. tostring(block.state) .. "]"
  end
  return title
end

local function block_key(block, opts)
  local parts = {
    tostring(opts and opts.block_index or ""),
    tostring(block.type or "Block"),
    tostring(block.message_id or ""),
    tostring(block.tool_call_id or ""),
    tostring(block.tool or ""),
    tostring(block.title or ""),
    tostring(block.state or ""),
  }
  return table.concat(parts, ":")
end

local function placeholder_expanded(thread, key)
  local expanded = thread.expanded_blocks and thread.expanded_blocks[key]
  if expanded == nil then
    return default_expanded()
  end
  return expanded == true
end

local function placeholder_meta(block)
  if block.type == "ReasoningBlock" then
    local text = events.block_text(block)
    if text == "" then
      return { "empty" }
    end
    if #text > 20000 then
      return { string.format("%.1f KB", #text / 1024) }
    end
    return { tostring(line_count(text)) .. " lines" }
  end
  if block.type == "ToolCallBlock" or block.type == "ToolOutputBlock" then
    local meta = {}
    local summary = truncate_display(compact_text(tool_summary(block)), 88)
    local status = output_summary(block)
    if summary ~= "" then
      table.insert(meta, summary)
    end
    if status then
      table.insert(meta, status)
    end
    if block.tool_call_id then
      table.insert(meta, "id " .. truncate_display(block.tool_call_id, 18))
    end
    return meta
  end
  if block.type == "AgentTimelineBlock" then
    local summary = truncate_display(compact_text(events.block_text(block)), 88)
    return summary ~= "" and { summary } or {}
  end
  if block.type == "QueuedBlock" then
    return { "waiting for current response" }
  end
  if block.type == "RawEventBlock" then
    return { "debug event" }
  end
  return {}
end

local function placeholder_title(block)
  if block.type == "ReasoningBlock" then
    return "Reasoning" .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "ToolCallBlock" or block.type == "ToolOutputBlock" then
    return tool_title(block)
  end
  if block.type == "AgentTimelineBlock" then
    return "Agent Timeline: " .. tostring(block.title or "event")
  end
  if block.type == "QueuedBlock" then
    return "Queued Request" .. (block.state and (" [" .. block.state .. "]") or "")
  end
  if block.type == "RawEventBlock" then
    return "Raw Event: " .. tostring(block.title or "unknown")
  end
  return tostring(block.type or "Block")
end

local function placeholder_body_lines(block)
  if block.type == "ReasoningBlock" then
    return util.split_lines(events.block_text(block))
  end
  if block.type == "ToolCallBlock" or block.type == "ToolOutputBlock" then
    local body = {}
    if block.tool_call_id then
      table.insert(body, "tool_call_id: " .. tostring(block.tool_call_id))
    end
    for _, rendered_line in ipairs(tool_renderers.render(block)) do
      table.insert(body, rendered_line)
    end
    return body
  end
  if block.type == "RawEventBlock" then
    return util.split_lines(vim.inspect(block.raw or block))
  end
  return util.split_lines(events.block_text(block))
end

local function render_placeholder(thread, lines, block, opts)
  local key = block_key(block, opts)
  local expanded = placeholder_expanded(thread, key)
  local body_lines = expanded and placeholder_body_lines(block) or {}
  local decoration = stream_decoration_for_block(block)
  local line = add(lines, " ")
  mark_placeholder(thread, line, key, block, placeholder_title(block), placeholder_meta(block), body_lines, decoration)
  if decoration then
    mark_stream_decoration(thread, line, line, decoration, block)
  end
end

render_block = function(thread, lines, block, opts)
  opts = opts or {}
  local start = #lines + 1
  if block.type == "UserBlock" then
    local line = add(lines, "## You")
    mark_header(thread, line, "user", "You", user_meta(thread, block), block)
    add(lines, "")
    add_text(lines, block.text)
  elseif block.type == "AssistantBlock" then
    local is_subagent_block = block_has_subagent_signal(block)
    if not opts.assistant_body then
      local title = assistant_title(block)
      local header_kind = is_subagent_block and "subagent" or "assistant"
      local line = add(lines, "## " .. title)
      mark_header(thread, line, header_kind, title, assistant_meta(thread, block), block)
      add(lines, "")
    end
    if not is_subagent_block then
      add_text(lines, block.text)
    end
  elseif placeholder_types[block.type] then
    if block_has_subagent_signal(block) then
      if not opts.assistant_body then
        local title = assistant_title(block)
        local line = add(lines, "## " .. title)
        mark_header(thread, line, "subagent", title, assistant_meta(thread, block), block)
      end
    else
      render_placeholder(thread, lines, block, opts)
    end
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
  if stream_decoration and not placeholder_types[block.type] then
    local decoration_start = finish > start and start + 1 or start
    mark_stream_decoration(thread, decoration_start, finish, stream_decoration, block)
  end
  add(lines, "")
end

assistant_group_id = function(block)
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
  local title = assistant_title(first_block)
  local is_subagent_group = block_has_subagent_signal(first_block)
  local header_kind = is_subagent_group and "subagent" or "assistant"
  local line = add(lines, "## " .. title)
  mark_header(thread, line, header_kind, title, assistant_meta(thread, first_block), first_block)
  add(lines, "")

  if is_subagent_group then
    while index <= #blocks and assistant_group_id(blocks[index]) == group_id do
      index = index + 1
    end
    return index
  end

  while index <= #blocks and assistant_group_id(blocks[index]) == group_id do
    render_block(thread, lines, blocks[index], { assistant_body = true, block_index = index })
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

local spinner_frames = {
  "▰▱▱▱▱",
  "▰▰▱▱▱",
  "▰▰▰▱▱",
  "▰▰▰▰▱",
  "▰▰▰▰▰",
  "▱▰▰▰▰",
  "▱▱▰▰▰",
  "▱▱▱▰▰",
  "▱▱▱▱▰",
}

local busy_generations = {
  submitted = true,
  waiting_backend = true,
  streaming = true,
  tool_running = true,
  reconciling = true,
  cancelling = true,
}

local function thread_busy(thread)
  return thread and (thread.backend_generating or busy_generations[thread.generation] == true)
end

local function spinner_label(thread)
  return thread.generation == "tool_running" and "tooling"
    or thread.generation == "waiting_backend" and "waiting"
    or thread.generation == "reconciling" and "syncing"
    or thread.generation == "cancelling" and "stopping"
    or "streaming"
end

spinner_virt_text = function(thread)
  local index = (math.floor(util.now_ms() / 140) % #spinner_frames) + 1
  return { { spinner_frames[index] .. "  Alma " .. spinner_label(thread), "AlmaSpinner" } }
end

local function spinner_placeholder_line()
  return " "
end

local function schedule_spinner_tick(thread)
  if not thread or not thread.id or not thread_busy(thread) then
    return
  end
  local key = tostring(thread.id)
  if pending_spinner_timers[key] then
    return
  end
  pending_spinner_timers[key] = vim.defer_fn(function()
    pending_spinner_timers[key] = nil
    M.update_spinner(thread)
  end, 140)
end

function M.update_spinner(thread)
  if not thread or not thread.bufnr or not vim.api.nvim_buf_is_valid(thread.bufnr) then
    return
  end
  if not thread_busy(thread) then
    return
  end
  if not thread.spinner_mark then
    return
  end
  apply_spinner_mark(thread, thread.bufnr, thread.spinner_mark)
  schedule_spinner_tick(thread)
end

local function header(thread)
  return { "# Alma: " .. tostring(thread.title or thread.id) }
end

local function status_chunks_fit(chunks, available_width)
  if not chunks or #chunks == 0 then
    return nil
  end
  if chunks_width(chunks) <= available_width then
    return chunks
  end
  return nil
end

local function workspace_label(thread)
  local workspace = thread and thread.workspace or {}
  local path = workspace.path or thread and thread.cwd
  return workspace.name or (path and vim.fn.fnamemodify(path, ":t")) or workspace.id
end

local function thread_workspace_virt_text(thread, bufnr, title_line)
  local label = workspace_label(thread)
  if not label or label == "" then
    return nil
  end
  local candidates = {
    { { tostring(label), "Comment" } },
  }
  local available = narrowest_buffer_text_width(bufnr) - vim.fn.strdisplaywidth(title_line or "") - 2
  for _, chunks in ipairs(candidates) do
    local fit = status_chunks_fit(chunks, available)
    if fit then
      return fit
    end
  end
  return nil
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

local function capture_prompt_anchor(thread, win)
  if not thread.prompt_start then
    return nil
  end
  local info = window_info(win)
  if not info then
    return nil
  end
  local top = info.topline or 1
  local bottom = info.botline or top + vim.api.nvim_win_get_height(win) - 1
  local prompt_line = thread.prompt_start
  if prompt_line < top or prompt_line > bottom then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
  cursor = ok and cursor or { prompt_line + 1, 0 }
  return {
    prompt_row = prompt_line - top,
    cursor_delta = cursor[1] - prompt_line,
    cursor_col = cursor[2] or 0,
  }
end

local function restore_prompt_anchor(thread, win, snapshot)
  if not snapshot or not snapshot.prompt_anchor or not thread.prompt_start then
    restore_window_view(thread, win, snapshot)
    return
  end
  local bufnr = thread.bufnr
  if not valid_window_for_buffer(win, bufnr) then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local anchor = snapshot.prompt_anchor
  local view = vim.deepcopy(snapshot.view or {})
  local lnum = clamp_lnum(thread.prompt_start + anchor.cursor_delta, line_count)
  local col = line_col(bufnr, lnum, anchor.cursor_col)
  view.lnum = lnum
  view.col = col
  view.curswant = col
  view.topline = clamp_lnum(thread.prompt_start - anchor.prompt_row, line_count)
  view.leftcol = view.leftcol or 0
  view.skipcol = view.skipcol or 0
  with_programmatic_view(thread, win, function()
    vim.api.nvim_win_set_cursor(win, { lnum, col })
    vim.api.nvim_win_call(win, function()
      vim.fn.winrestview(view)
    end)
    vim.api.nvim_win_set_cursor(win, { lnum, col })
  end)
end

local function capture_window_views(thread, bufnr)
  local snapshots = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_window_for_buffer(win, bufnr) then
      local prompt_anchor = capture_prompt_anchor(thread, win)
      local state = view_state_for_win(thread, win)
      state.follow = prompt_anchor ~= nil
      state.suspended_by_user = prompt_anchor == nil
      snapshots[win] = {
        view = save_window_view(win),
        prompt_anchor = prompt_anchor,
      }
    end
  end
  return snapshots
end

local function apply_window_views(thread, bufnr, snapshots)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if valid_window_for_buffer(win, bufnr) then
      local snapshot = snapshots[win]
      require("alma.buffers").apply_window_options(win, bufnr)
      if snapshot and snapshot.prompt_anchor then
        restore_prompt_anchor(thread, win, snapshot)
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

local function changed_line_range(current, lines)
  local current_count = #current
  local next_count = #lines
  local prefix = 0
  local prefix_limit = math.min(current_count, next_count)
  while prefix < prefix_limit and current[prefix + 1] == lines[prefix + 1] do
    prefix = prefix + 1
  end
  if prefix == current_count and prefix == next_count then
    return nil
  end

  local suffix = 0
  local current_suffix_limit = current_count - prefix
  local next_suffix_limit = next_count - prefix
  while
    suffix < current_suffix_limit
    and suffix < next_suffix_limit
    and current[current_count - suffix] == lines[next_count - suffix]
  do
    suffix = suffix + 1
  end

  local replacement = {}
  for index = prefix + 1, next_count - suffix do
    table.insert(replacement, lines[index])
  end
  return prefix, current_count - suffix, replacement
end

local function replace_buffer_lines(bufnr, lines)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local start_line, end_line, replacement = changed_line_range(current, lines)
  if not start_line then
    return false
  end

  local fold_snapshots = suspend_window_folds(bufnr)
  local previous_undolevels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, start_line, end_line, false, replacement)
  vim.bo[bufnr].undolevels = previous_undolevels
  restore_suspended_folds(fold_snapshots)
  if not ok then
    error(err)
  end
  return true
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
  thread.placeholder_index = {}
  thread.placeholder_marks = {}
  thread.placeholder_hint_seen = {}
  thread.header_marks = {}
  thread.reasoning_marks = {}
  thread.stream_decoration_marks = {}
  thread.spinner_mark = nil
  thread.spinner_marks = {}
  thread.composer_token_marks = {}
  thread.crew_progress_mark = nil
  thread.folds = {}
  thread.fold_levels = {}

  local lines = {}
  local title_line = nil
  for _, line in ipairs(header(thread)) do
    title_line = title_line or line
    add(lines, line)
  end
  add(lines, "")

  local blocks = M.select_render_tree(thread)
  local index = 1
  while index <= #blocks do
    if assistant_group_id(blocks[index]) then
      index = render_assistant_group(thread, lines, blocks, index)
    else
      render_block(thread, lines, blocks[index], { block_index = index })
      index = index + 1
    end
  end

  if thread_busy(thread) then
    local line = add(lines, spinner_placeholder_line())
    mark_spinner(thread, line)
    add(lines, "")
  end

  local line = add(lines, config.get().render.prompt_marker)
  mark_header(thread, line, "user", "You", composer_meta(thread), nil)
  add(lines, "")
  local prompt_start = #lines
  for _, prompt_line in ipairs(#prompt > 0 and prompt or { "" }) do
    add(lines, prompt_line)
  end
  thread.prompt_start = prompt_start
  mark_crew_progress(thread, #lines)
  build_fold_levels(thread)

  vim.bo[bufnr].modifiable = true
  replace_buffer_lines(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  apply_header_marks(thread, bufnr)
  apply_placeholder_marks(thread, bufnr)
  apply_reasoning_marks(thread, bufnr)
  apply_stream_decoration_marks(thread, bufnr)
  apply_spinner_marks(thread, bufnr)
  apply_composer_token_marks(thread, bufnr)
  apply_crew_progress_mark(thread, bufnr)
  vim.bo[bufnr].modifiable = true

  local virt = thread_workspace_virt_text(thread, bufnr, title_line)
  if virt then
    vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
      virt_text = virt,
      virt_text_pos = "right_align",
    })
  end

  apply_window_views(thread, bufnr, snapshots)
  prune_view_states(thread, bufnr)
  if thread_busy(thread) then
    schedule_spinner_tick(thread)
  end
end

function M.toggle_under_cursor()
  local thread = require("alma.state").thread_for_buf(0)
  if not thread then
    util.notify("Current buffer is not an Alma thread buffer", vim.log.levels.ERROR)
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local mark = thread.placeholder_index and thread.placeholder_index[lnum]
  if not mark then
    util.notify("No expandable Alma block under cursor", vim.log.levels.WARN)
    return
  end
  thread.expanded_blocks = thread.expanded_blocks or {}
  thread.expanded_blocks[mark.key] = not placeholder_expanded(thread, mark.key)
  M.render(thread)
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
