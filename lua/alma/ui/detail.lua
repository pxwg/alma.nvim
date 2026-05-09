local events = require("alma.events")
local rest = require("alma.rest")
local state = require("alma.state")
local util = require("alma.util")

local M = {}

local function block_under_cursor()
  local thread = state.thread_for_buf(0)
  if not thread then
    return nil, nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  for line = lnum, 1, -1 do
    if thread.render_index[line] then
      return thread.render_index[line], thread
    end
  end
  return nil, thread
end

local function scratch(name, filetype, lines)
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "wipe"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].filetype = filetype or ""
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_set_current_buf(bufnr)
  return bufnr
end

local function block_detail_lines(block)
  if not block then
    return { "No Alma block under cursor." }
  end
  if block.type == "ToolCallBlock" then
    local lines = {
      "tool: " .. tostring(block.tool or "unknown"),
      "state: " .. tostring(block.state or "unknown"),
      "",
      "input:",
    }
    util.list_extend(lines, util.to_lines(block.input))
    table.insert(lines, "")
    table.insert(lines, "output:")
    util.list_extend(lines, util.to_lines(block.output or block.text))
    return lines
  end
  return util.to_lines(events.block_text(block))
end

function M.open_under_cursor()
  local block = block_under_cursor()
  scratch("alma://detail", "text", block_detail_lines(block))
end

local function extract_locations(text)
  local items = {}
  for line in tostring(text or ""):gmatch("[^\n]+") do
    local file, lnum, col = line:match("([^:%s]+):(%d+):(%d+)")
    if not file then
      file, lnum = line:match("([^:%s]+):(%d+)")
    end
    if file and lnum then
      table.insert(items, {
        filename = vim.fn.fnamemodify(file, ":p"),
        lnum = tonumber(lnum),
        col = tonumber(col) or 1,
        text = line,
      })
    end
  end
  return items
end

function M.quickfix_under_cursor()
  local block, thread = block_under_cursor()
  if not block then
    util.notify("No Alma block under cursor", vim.log.levels.WARN)
    return
  end
  local items = extract_locations(events.block_text(block))
  if #items == 0 then
    util.notify("No file locations found in Alma block", vim.log.levels.WARN)
    return
  end
  vim.fn.setqflist({}, " ", {
    title = "Alma " .. util.short_id(thread.id),
    items = items,
  })
  vim.cmd.copen()
end

function M.quickfix_thread()
  local thread = state.thread_for_buf(0)
  if not thread then
    util.notify("Current buffer is not an Alma thread buffer", vim.log.levels.ERROR)
    return
  end
  local items = {}
  for _, block in ipairs(thread.blocks or {}) do
    util.list_extend(items, extract_locations(events.block_text(block)))
  end
  if #items == 0 then
    util.notify("No file locations found in Alma thread", vim.log.levels.WARN)
    return
  end
  vim.fn.setqflist({}, " ", {
    title = "Alma " .. util.short_id(thread.id),
    items = items,
  })
  vim.cmd.copen()
end

local function looks_like_diff(text)
  text = tostring(text or "")
  return text:find("\ndiff %-%-git ") or text:find("^diff %-%-git ") or text:find("\n%-%-%- ") or text:find("^%-%-%- ")
end

function M.diff_under_cursor()
  local block = block_under_cursor()
  if not block then
    util.notify("No Alma block under cursor", vim.log.levels.WARN)
    return
  end
  local text = events.block_text(block)
  if not looks_like_diff(text) then
    util.notify("No patch-like output found in Alma block", vim.log.levels.WARN)
    return
  end
  local bufnr = scratch("alma://diff", "diff", util.split_lines(text))
  vim.api.nvim_buf_call(bufnr, function()
    vim.cmd.diffthis()
  end)
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

local function as_list(value)
  return type(value) == "table" and value or {}
end

local function compact_text(value, limit)
  local text = util.trim(tostring(value or ""):gsub("%s+", " "))
  limit = limit or 120
  if #text <= limit then
    return text
  end
  return text:sub(1, limit - 1) .. "…"
end

local function status_symbol(status)
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
  if status == "skipped" then
    return "↷"
  end
  return "○"
end

local function phase_label(phase)
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

local function progress_bar(done, total, width)
  width = width or 16
  done = tonumber(done) or 0
  total = tonumber(total) or 0
  if total <= 0 then
    return string.rep("░", width)
  end
  local filled = math.max(1, math.min(width, math.floor((done / total) * width + 0.5)))
  return string.rep("█", filled) .. string.rep("░", width - filled)
end

local function branch_prefix(index, total)
  return index == total and "└─ " or "├─ "
end

local function child_prefix(index, total)
  return index == total and "   " or "│  "
end

local function add_bullet(lines, prefix, label, value)
  if value and value ~= "" then
    table.insert(lines, prefix .. "- " .. label .. ": " .. tostring(value))
  end
end

local function count_passed_grades(evaluation)
  local passed = 0
  local grades = as_list(evaluation and evaluation.grades)
  for _, grade in ipairs(grades) do
    if grade.passed == true or grade.passed == 1 then
      passed = passed + 1
    end
  end
  return passed, #grades
end

local function group_by_id(items, key)
  local grouped = {}
  for _, item in ipairs(as_list(items)) do
    local id = item[key]
    if id then
      grouped[id] = grouped[id] or {}
      table.insert(grouped[id], item)
    end
  end
  return grouped
end

local function latest_item(items)
  items = as_list(items)
  return items[#items]
end

local function mission_summary(mission)
  local summary = type(mission.summary) == "table" and mission.summary or {}
  if summary.totalRuns ~= nil then
    return summary
  end
  local runs = as_list(mission.runs)
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

local function active_sprint(sprints)
  for _, sprint in ipairs(as_list(sprints)) do
    if sprint.status == "active" then
      return sprint
    end
  end
  return nil
end

local function render_evaluation(lines, prefix, evaluation)
  if not evaluation then
    return
  end
  local passed, total = count_passed_grades(evaluation)
  local status = (evaluation.overallPassed == true or evaluation.overallPassed == 1) and "passed" or "needs work"
  table.insert(lines, string.format("%sEvaluation: Attempt %s · %d/%d · %s", prefix, tostring(evaluation.attemptNumber or "?"), passed, total, status))
  if evaluation.feedbackSummary and evaluation.feedbackSummary ~= "" then
    table.insert(lines, prefix .. compact_text(evaluation.feedbackSummary, 140))
  end
end

local function render_contract(lines, prefix, contract)
  if not contract or #as_list(contract.criteria) == 0 then
    return
  end
  table.insert(lines, prefix .. "Contract")
  for _, criterion in ipairs(as_list(contract.criteria)) do
    table.insert(lines, string.format(
      "%s- %s %s",
      prefix,
      tostring(criterion.id or "criterion"),
      compact_text(criterion.description, 130)
    ))
  end
end

local function render_sprint(lines, sprint, contracts, evaluations, index, total)
  local status = tostring(sprint.status or "pending")
  local prefix = branch_prefix(index, total)
  local child = child_prefix(index, total)
  local sprint_number = sprint.sprintNumber or sprint.number or index
  local criteria_count = 0
  local active_contract = nil
  for _, contract in ipairs(as_list(contracts)) do
    if contract.status == "agreed" then
      active_contract = contract
      break
    end
    active_contract = active_contract or contract
  end
  if active_contract then
    criteria_count = #as_list(active_contract.criteria)
  end

  table.insert(lines, string.format(
    "%s%s S%s %s [%s]",
    prefix,
    status_symbol(status),
    tostring(sprint_number),
    compact_text(sprint.title or "Sprint", 80),
    status
  ))

  local meta = {}
  if criteria_count > 0 then
    table.insert(meta, tostring(criteria_count) .. " criteria")
  end
  if #as_list(evaluations) > 0 then
    table.insert(meta, tostring(#as_list(evaluations)) .. " attempt" .. (#as_list(evaluations) > 1 and "s" or ""))
  end
  if #meta > 0 then
    table.insert(lines, child .. "   " .. table.concat(meta, " · "))
  end

  if status == "active" then
    render_contract(lines, child .. "   ", active_contract)
    if #as_list(evaluations) > 0 then
      render_evaluation(lines, child .. "   ", latest_item(evaluations))
    else
      table.insert(lines, child .. "   ↻ Building...")
    end
  end
end

local function render_harness_mission(lines, mission)
  local sprints = as_list(mission.sprints)
  local contracts_by_sprint = group_by_id(mission.contracts, "sprintId")
  local evaluations_by_sprint = group_by_id(mission.evaluations, "sprintId")
  local passed = 0
  for _, sprint in ipairs(sprints) do
    if sprint.status == "passed" then
      passed = passed + 1
    end
  end
  local active = active_sprint(sprints)

  table.insert(lines, "## ⚡ " .. compact_text(mission.title or "Sprint Harness", 100))
  table.insert(lines, "")
  add_bullet(lines, "", "mode", "Sprint Harness")
  add_bullet(lines, "", "phase", phase_label(mission.currentPhase))
  add_bullet(lines, "", "progress", string.format("%d/%d sprints  %s", passed, #sprints, progress_bar(passed, #sprints)))
  if active then
    add_bullet(lines, "", "current", string.format("%s: S%s %s", phase_label(mission.currentPhase), tostring(active.sprintNumber or active.number or "?"), compact_text(active.title or "Sprint", 80)))
  end
  table.insert(lines, "")

  if #sprints == 0 and mission.currentPhase == "planning" then
    table.insert(lines, "● Planning...")
  else
    for index, sprint in ipairs(sprints) do
      render_sprint(lines, sprint, contracts_by_sprint[sprint.id] or {}, evaluations_by_sprint[sprint.id] or {}, index, #sprints)
    end
  end
  table.insert(lines, "")
end

local function timeline_items(mission)
  local items = {}
  for _, handoff in ipairs(as_list(mission.handoffs)) do
    table.insert(items, { type = "handoff", createdAt = handoff.createdAt or "", payload = handoff })
  end
  for _, run in ipairs(as_list(mission.runs)) do
    table.insert(items, { type = "run", createdAt = run.createdAt or "", payload = run })
  end
  table.sort(items, function(left, right)
    return tostring(left.createdAt) < tostring(right.createdAt)
  end)
  return items
end

local function render_handoff_item(lines, item, index, total)
  local handoff = item.payload or {}
  local packet = type(handoff.packet) == "table" and handoff.packet or {}
  local prefix = branch_prefix(index, total)
  local child = child_prefix(index, total)
  table.insert(lines, string.format("%s%s Handoff [%s] %s", prefix, status_symbol(handoff.status), tostring(handoff.status or "pending"), compact_text(packet.goal or "Handoff", 100)))
  add_bullet(lines, child .. "   ", "deliverable", compact_text(packet.deliverable, 120))
  add_bullet(lines, child .. "   ", "write back", packet.writeBack)
  add_bullet(lines, child .. "   ", "result", compact_text(handoff.resultSummary, 120))
end

local function render_run_item(lines, item, index, total)
  local run = item.payload or {}
  local prefix = branch_prefix(index, total)
  local child = child_prefix(index, total)
  local summary = first_string(run.outputSummary, run.inputSummary, "Run")
  table.insert(lines, string.format("%s%s Run [%s] %s", prefix, status_symbol(run.status), tostring(run.status or "pending"), compact_text(summary, 110)))
  add_bullet(lines, child .. "   ", "result", compact_text(run.outputSummary, 120))
end

local function render_regular_mission(lines, mission)
  local summary = mission_summary(mission)
  table.insert(lines, "## " .. compact_text(mission.title or "Mission", 100))
  table.insert(lines, "")
  add_bullet(lines, "", "status", mission.status)
  add_bullet(lines, "", "objective", compact_text(mission.objective, 160))
  add_bullet(lines, "", "progress", string.format(
    "%s running · %s done · %s handoffs",
    tostring(summary.activeRuns or 0),
    tostring(summary.completedRuns or 0),
    tostring(#as_list(mission.handoffs))
  ))
  table.insert(lines, "")

  local items = timeline_items(mission)
  for index, item in ipairs(items) do
    if item.type == "handoff" then
      render_handoff_item(lines, item, index, #items)
    else
      render_run_item(lines, item, index, #items)
    end
  end
  table.insert(lines, "")
end

local function render_api_agent_crew(data, opts)
  opts = opts or {}
  local missions = as_list(data and data.missions)
  local totals = { missions = #missions, runs = 0, active = 0 }
  for _, mission in ipairs(missions) do
    local summary = mission_summary(mission)
    totals.runs = totals.runs + (tonumber(summary.totalRuns) or #as_list(mission.runs))
    totals.active = totals.active + (tonumber(summary.activeRuns) or 0)
  end

  local title = opts.thread and (opts.thread.title or opts.thread.id) or "current thread"
  local lines = {
    "# Alma Agent Crew: " .. tostring(title),
    "",
    string.format("Crew · %d missions, %d runs, %d active", totals.missions, totals.runs, totals.active),
    "",
  }
  if #missions == 0 then
    table.insert(lines, "No agent crew timeline for this thread yet.")
    return lines
  end

  for _, mission in ipairs(missions) do
    if mission.harnessMode == "sprint-harness" then
      render_harness_mission(lines, mission)
    else
      render_regular_mission(lines, mission)
    end
  end
  return lines
end

local function subagent_label(context, fallback)
  return first_string(
    context.subAgentName,
    context.subagentName,
    context.agentProfileName,
    context.agentName,
    context.subAgentRole,
    context.subagentRole,
    context.subAgentType,
    context.subagentType,
    context.agentProfileId,
    fallback
  ) or "Task"
end

local function subagent_part_summary(parts)
  local tool_count = 0
  local tools = {}
  local seen_tools = {}
  for _, part in ipairs(parts or {}) do
    local typ = tostring(part.type or "text")
    if vim.startswith(typ, "tool") then
      tool_count = tool_count + 1
      local name = first_string(part.toolName, part.tool_name, part.name, part.tool, typ:gsub("^tool%-", ""), "tool")
      local state_text = part.state and (" [" .. tostring(part.state) .. "]") or ""
      local label = name .. state_text
      if not seen_tools[label] then
        seen_tools[label] = true
        table.insert(tools, label)
      end
    end
  end
  return tool_count, table.concat(tools, ", ")
end

local function render_local_agent_crew(thread, reason)
  local lines = {
    "# Alma Agent Crew: " .. tostring(thread and (thread.title or thread.id) or "current thread"),
    "",
  }
  if reason and reason ~= "" then
    table.insert(lines, "Alma crew timeline unavailable: " .. tostring(reason))
    table.insert(lines, "")
  end
  if not thread then
    table.insert(lines, "No Alma thread is active in this buffer.")
    return lines
  end
  table.insert(lines, "## Live Task Activity")
  table.insert(lines, "")
  local order = as_list(thread.subagent_order)
  if #order == 0 then
    table.insert(lines, "No delegated task activity has reported for this thread yet.")
    return lines
  end
  for index, task_id in ipairs(order) do
    local acc = thread.subagent_streams and thread.subagent_streams[task_id]
    if acc then
      local status = acc.is_streaming and "running" or "done"
      local context = acc.context or {}
      local tool_count, tools = subagent_part_summary(acc.parts)
      table.insert(lines, string.format("%s%s %s [%s]", branch_prefix(index, #order), status_symbol(status), subagent_label(context, acc.task_id), status))
      local child = child_prefix(index, #order)
      add_bullet(lines, child .. "   ", "task", util.short_id(acc.task_id))
      if tool_count > 0 then
        add_bullet(lines, child .. "   ", "tools", tools)
      end
    end
  end
  return lines
end

function M.agent_crew_lines(source, opts)
  opts = opts or {}
  if source and source.missions ~= nil then
    return render_api_agent_crew(source, opts)
  end
  return render_local_agent_crew(source or state.thread_for_buf(0), opts.reason)
end

local function replace_scratch_lines(bufnr, lines)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

function M.open_agent_crews()
  local thread = state.thread_for_buf(0)
  local bufnr = scratch("alma://agent-crews", "alma", {
    "# Alma Agent Crew: " .. tostring(thread and (thread.title or thread.id) or "current thread"),
    "",
    "Loading crew timeline...",
  })
  if not thread then
    replace_scratch_lines(bufnr, M.agent_crew_lines(nil))
    return
  end
  rest.agent_crew(thread.id, function(data, err)
    if data then
      replace_scratch_lines(bufnr, M.agent_crew_lines(data, { thread = thread }))
    else
      replace_scratch_lines(bufnr, M.agent_crew_lines(thread, { reason = err }))
      util.notify("Alma agent crew fetch failed: " .. tostring(err), vim.log.levels.WARN)
    end
  end)
end

return M
