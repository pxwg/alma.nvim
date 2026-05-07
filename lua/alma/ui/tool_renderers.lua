local config = require("alma.config")
local util = require("alma.util")

local M = {}

local function stringify(value)
  if value == nil then
    return ""
  end
  if type(value) == "string" then
    return value
  end
  return vim.inspect(value)
end

local function split_lines(value)
  local lines = util.split_lines(value)
  return #lines > 0 and lines or { "" }
end

local function first_line(value)
  return util.trim((tostring(value or ""):gsub("\r\n", "\n"):gsub("\r", "\n"):match("^[^\n]+") or ""))
end

local function truncate(value, limit)
  value = tostring(value or "")
  limit = limit or 96
  if #value <= limit then
    return value
  end
  return value:sub(1, limit - 1) .. "…"
end

local function table_get(tbl, ...)
  if type(tbl) ~= "table" then
    return nil
  end
  for index = 1, select("#", ...) do
    local key = select(index, ...)
    local value = tbl[key]
    if value ~= nil and value ~= "" then
      return value
    end
  end
  return nil
end

local function code_block(lines, lang, value)
  table.insert(lines, "```" .. (lang or ""))
  vim.list_extend(lines, split_lines(value))
  table.insert(lines, "```")
end

local function is_long(text)
  local opts = config.get()
  if #text > (opts.long_output_bytes or 12000) then
    return true
  end
  local _, count = text:gsub("\n", "")
  return count + 1 > (opts.long_output_lines or 80)
end

local function add_value(lines, label, value, lang)
  if value == nil then
    return false
  end
  local text = stringify(value)
  if is_long(text) then
    table.insert(lines, label .. ": [long output available with :AlmaToolDetails]")
  else
    table.insert(lines, label .. ":")
    code_block(lines, lang or "lua", text)
  end
  return true
end

local function lang_for_path(path)
  local ok, ft = pcall(vim.filetype.match, { filename = path })
  if ok and ft and ft ~= "" then
    return ft
  end
  return "text"
end

local function output_status(output)
  if type(output) ~= "table" then
    return nil
  end
  local parts = {}
  if output.exitCode ~= nil then
    table.insert(parts, "exit " .. tostring(output.exitCode))
  end
  if output.durationMs ~= nil then
    table.insert(parts, tostring(output.durationMs) .. "ms")
  end
  if output.stdout and output.stdout ~= "" then
    table.insert(parts, "stdout")
  end
  if output.stderr and output.stderr ~= "" then
    table.insert(parts, "stderr")
  end
  return #parts > 0 and table.concat(parts, " · ") or nil
end

local function generic_summary(block)
  local input = block.input
  local tool = tostring(block.tool or "unknown")
  if tool == "Bash" then
    return first_line(table_get(input, "command") or block.text)
  elseif tool == "Read" or tool == "Edit" or tool == "Write" then
    return tostring(table_get(input, "file_path", "path") or "")
  elseif tool == "Grep" or tool == "Glob" then
    return util.trim(tostring(table_get(input, "pattern") or "") .. "  " .. tostring(table_get(input, "path") or ""))
  elseif tool == "Task" then
    return tostring(table_get(input, "description", "prompt") or "")
  elseif tool == "WebFetch" or tool == "WebSearch" then
    return tostring(table_get(input, "url", "query") or "")
  end
  return first_line(stringify(input ~= nil and input or block.text))
end

local function render_bash(block)
  local lines = {}
  local input = type(block.input) == "table" and block.input or {}
  local output = type(block.output) == "table" and block.output or nil
  local command = table_get(input, "command")
  if input.description then
    table.insert(lines, "description: " .. tostring(input.description))
  end
  if output and output.cwd then
    table.insert(lines, "cwd: " .. tostring(output.cwd))
  end
  if command then
    table.insert(lines, "command:")
    code_block(lines, "bash", command)
  else
    add_value(lines, "input", block.input, "lua")
  end
  if output then
    if output.stdout and output.stdout ~= "" then
      add_value(lines, "stdout", output.stdout, "text")
    end
    if output.stderr and output.stderr ~= "" then
      add_value(lines, "stderr", output.stderr, "text")
    end
    if not output.stdout and not output.stderr then
      add_value(lines, "output", output, "lua")
    end
  elseif block.output ~= nil then
    add_value(lines, "output", block.output, "text")
  elseif block.text and block.text ~= "" then
    add_value(lines, "output", block.text, "text")
  end
  return lines
end

local function render_read(block)
  local input = type(block.input) == "table" and block.input or {}
  local output = type(block.output) == "table" and block.output or {}
  local path = table_get(input, "file_path", "path")
  local lines = {}
  if path then
    local range = ""
    if input.offset or input.limit then
      range = string.format("  offset=%s limit=%s", tostring(input.offset or 1), tostring(input.limit or "all"))
    end
    table.insert(lines, "file: " .. tostring(path) .. range)
  end
  if type(output.content) == "string" then
    code_block(lines, lang_for_path(path), output.content)
  else
    add_value(lines, "output", block.output, "lua")
  end
  return lines
end

local function unified_diff(path, old_string, new_string, start_line)
  if type(old_string) ~= "string" or type(new_string) ~= "string" then
    return nil
  end
  local old_lines = split_lines(old_string)
  local new_lines = split_lines(new_string)
  local from = tonumber(start_line) or 1
  local lines = {
    "--- a/" .. tostring(path or "unknown"),
    "+++ b/" .. tostring(path or "unknown"),
    string.format("@@ -%d,%d +%d,%d @@", from, #old_lines, from, #new_lines),
  }
  for _, line in ipairs(old_lines) do
    table.insert(lines, "-" .. line)
  end
  for _, line in ipairs(new_lines) do
    table.insert(lines, "+" .. line)
  end
  return table.concat(lines, "\n")
end

local function render_edit(block)
  local input = type(block.input) == "table" and block.input or {}
  local output = type(block.output) == "table" and block.output or {}
  local path = table_get(input, "file_path", "path") or output.file_path
  local lines = {
    "file: " .. tostring(path or "unknown"),
  }
  if output.changed ~= nil or output.replacements ~= nil or output.start_line ~= nil then
    table.insert(
      lines,
      string.format(
        "changed: %s  replacements: %s  start_line: %s",
        tostring(output.changed),
        tostring(output.replacements or "?"),
        tostring(output.start_line or "?")
      )
    )
  end
  local diff = unified_diff(path, input.old_string, input.new_string, output.start_line)
  if diff then
    table.insert(lines, "diff:")
    code_block(lines, "diff", diff)
  elseif type(output.preview) == "string" then
    table.insert(lines, "preview:")
    code_block(lines, lang_for_path(path), output.preview)
  else
    add_value(lines, "input", block.input, "lua")
    add_value(lines, "output", block.output, "lua")
  end
  return lines
end

local function render_write(block)
  local input = type(block.input) == "table" and block.input or {}
  local output = type(block.output) == "table" and block.output or {}
  local path = output.file_path or input.file_path or input.path
  local lines = { "file: " .. tostring(path or "unknown") }
  if output.bytes_written or output.updatedAt then
    table.insert(lines, "bytes: " .. tostring(output.bytes_written or "?") .. "  updated: " .. tostring(output.updatedAt or "?"))
  end
  if type(input.content) == "string" and input.content ~= "" then
    table.insert(lines, "content:")
    code_block(lines, lang_for_path(path), input.content)
  else
    add_value(lines, "output", block.output, "lua")
  end
  return lines
end

local function render_matches(lines, matches)
  for _, match in ipairs(matches or {}) do
    local file = match.file or match.path or match.filename or ""
    local line = match.line or match.lnum or ""
    local preview = match.preview or match.text or match.content or ""
    if file ~= "" or preview ~= "" then
      table.insert(lines, string.format("- %s%s%s", tostring(file), line ~= "" and (":" .. tostring(line)) or "", preview ~= "" and ("  " .. tostring(preview)) or ""))
    end
  end
end

local function render_grep(block)
  local input = type(block.input) == "table" and block.input or {}
  local output = type(block.output) == "table" and block.output or {}
  local lines = {
    "pattern: " .. tostring(input.pattern or output.pattern or ""),
    "path: " .. tostring(input.path or output.cwd or ""),
  }
  if type(output.matches) == "table" and #output.matches > 0 then
    table.insert(lines, "matches:")
    render_matches(lines, output.matches)
  elseif type(output.rawOutput) == "string" and output.rawOutput ~= "" then
    table.insert(lines, "matches:")
    code_block(lines, "text", output.rawOutput)
  else
    add_value(lines, "output", block.output, "lua")
  end
  return lines
end

local function render_glob(block)
  local input = type(block.input) == "table" and block.input or {}
  local output = type(block.output) == "table" and block.output or {}
  local lines = {
    "pattern: " .. tostring(input.pattern or output.pattern or ""),
    "path: " .. tostring(input.path or output.cwd or ""),
  }
  if type(output.matches) == "table" then
    table.insert(lines, "matches:")
    for _, match in ipairs(output.matches) do
      if type(match) == "table" then
        table.insert(lines, "- " .. tostring(match.path or match.file or match[1] or vim.inspect(match)))
      else
        table.insert(lines, "- " .. tostring(match))
      end
    end
  else
    add_value(lines, "output", block.output, "lua")
  end
  return lines
end

local function render_raw(block)
  local lines = {}
  add_value(lines, "input", block.input, "lua")
  if block.output ~= nil then
    add_value(lines, "output", block.output, "lua")
  elseif block.text and block.text ~= "" then
    add_value(lines, "output", block.text, "text")
  end
  return lines
end

local builtin_renderers = {
  Bash = render_bash,
  Read = render_read,
  Edit = render_edit,
  Write = render_write,
  Grep = render_grep,
  Glob = render_glob,
}

local function renderer_for(block)
  local opts = config.get().render and config.get().render.tool_outputs or {}
  local custom = opts.renderers and opts.renderers[block.tool]
  if type(custom) == "function" then
    return custom
  end
  if opts.mode == "raw" then
    return render_raw
  end
  return builtin_renderers[block.tool] or render_raw
end

function M.summary(block)
  local ok, summary = pcall(generic_summary, block or {})
  if ok and summary and summary ~= "" then
    return truncate(summary, 110)
  end
  return ""
end

function M.status(block)
  return output_status(block and block.output)
end

function M.render(block)
  local renderer = renderer_for(block or {})
  local ok, rendered = pcall(renderer, block or {})
  if not ok or type(rendered) ~= "table" then
    if config.get().render and config.get().render.tool_outputs and config.get().render.tool_outputs.fallback == "none" then
      return { "Tool renderer failed: " .. tostring(rendered) }
    end
    return render_raw(block or {})
  end
  return rendered
end

return M
