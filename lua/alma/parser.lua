local config = require("alma.config")
local tokens = require("alma.ui.tokens")
local util = require("alma.util")

local M = {}

local function inherit_request_selection(value)
  if type(value) == "table" then
    return vim.deepcopy(value)
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return {}
end

local function dedup_request_selection(value)
  if type(value) == "table" then
    return util.dedup(value)
  end
  if type(value) == "string" and value ~= "" then
    return value
  end
  return {}
end

local function payload_tool_selection(value)
  if type(value) == "table" then
    return value
  end
  if value == "__auto__" or value == "auto" then
    return nil
  end
  if type(value) == "string" and value ~= "" then
    return { value }
  end
  return {}
end

local function has_request_selection(value)
  if type(value) == "table" then
    return #value > 0
  end
  return type(value) == "string" and value ~= ""
end

local function current_metadata(thread)
  local bufnr = vim.api.nvim_get_current_buf()
  return {
    source = "alma_nvim",
    bufnr = bufnr,
    cwd = thread and thread.cwd or config.resolve_cwd(bufnr),
    workspaceId = thread and thread.workspace_id or nil,
    original_text = nil,
  }
end

local image_mime_by_ext = {
  png = "image/png",
  jpg = "image/jpeg",
  jpeg = "image/jpeg",
  webp = "image/webp",
  gif = "image/gif",
  bmp = "image/bmp",
  tiff = "image/tiff",
  tif = "image/tiff",
  heic = "image/heic",
}

local function mime_for_path(path)
  local ext = tostring(path or ""):match("%.([^.]+)$")
  return ext and image_mime_by_ext[ext:lower()] or "application/octet-stream"
end

local function uri_decode(value)
  return tostring(value or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end)
end

local function resolve_image_path(location, thread)
  location = uri_decode(location)
  if location:match("^file://") then
    location = location:gsub("^file://", "")
  end
  if location:match("^/") then
    return vim.fn.fnamemodify(location, ":p")
  end
  local base = thread and thread.cwd or config.resolve_cwd(0)
  return vim.fn.fnamemodify(base .. "/" .. location, ":p")
end

local function image_part_from_markdown(alt, location, thread)
  if location:match("^data:image/") then
    local media_type, data = location:match("^data:([^;]+);base64,(.+)$")
    if media_type and data then
      return {
        type = "file",
        mediaType = media_type,
        url = location,
        filename = alt ~= "" and alt or "image.png",
      }
    end
    return nil, "Unsupported data URI image: " .. location:sub(1, 32)
  end
  if location:match("^https?://") then
    return {
      type = "file",
      mediaType = mime_for_path(location),
      url = location,
      filename = alt ~= "" and alt or vim.fn.fnamemodify(location, ":t"),
    }
  end

  local path = resolve_image_path(location, thread)
  local data, err = util.read_file_bytes(path)
  if not data then
    return nil, "Unable to read image " .. location .. ": " .. tostring(err)
  end
  local media_type = mime_for_path(path)
  return {
    type = "file",
    mediaType = media_type,
    url = "data:" .. media_type .. ";base64," .. util.base64_encode(data),
    filename = alt ~= "" and alt or vim.fn.fnamemodify(path, ":t"),
  }
end

local function extract_markdown_images(text, thread)
  local images = {}
  local warnings = {}
  local display_text = text
  local prompt_text = text:gsub("!%[([^%]]*)%]%(([^%)]+)%)", function(alt, location)
    local part, err = image_part_from_markdown(alt, vim.trim(location), thread)
    if part then
      table.insert(images, part)
      return ""
    end
    table.insert(warnings, err)
    return "![" .. alt .. "](" .. location .. ")"
  end)
  return prompt_text, display_text, images, warnings
end

local function context_for_token(token)
  local bufnr = vim.api.nvim_get_current_buf()
  if token == ">buffer" then
    return {
      type = "buffer",
      bufnr = bufnr,
      name = vim.api.nvim_buf_get_name(bufnr),
      text = util.read_buf_text(bufnr, 20000),
    }
  end
  if token == ">selection" then
    local start_pos = vim.fn.getpos("'<")
    local end_pos = vim.fn.getpos("'>")
    if start_pos[2] > 0 and end_pos[2] >= start_pos[2] then
      local lines = vim.api.nvim_buf_get_lines(bufnr, start_pos[2] - 1, end_pos[2], false)
      return {
        type = "selection",
        bufnr = bufnr,
        name = vim.api.nvim_buf_get_name(bufnr),
        text = table.concat(lines, "\n"),
      }
    end
    return { type = "selection", bufnr = bufnr, text = "" }
  end
  if token == ">diagnostics" then
    return {
      type = "diagnostics",
      bufnr = bufnr,
      diagnostics = vim.diagnostic.get(bufnr),
    }
  end
  if token == ">diff" then
    return { type = "diff", cwd = config.resolve_cwd(bufnr) }
  end
  local file = token:match("^>file:(.+)$")
  if file then
    return { type = "file", path = vim.fn.fnamemodify(file, ":p") }
  end
  local zk = token:match("^>zk:(.+)$")
  if zk then
    return { type = "zk", id = zk }
  end
  return nil
end

local function parse_token(token, spec, thread)
  local prefix = token:sub(1, 1)
  if prefix == "/" or prefix == "@" or prefix == "$" then
    local ok = tokens.parse_into_spec(token, spec, {
      thread = thread,
      accept_unknown_mentions = true,
    })
    return ok == true
  end

  if prefix == ">" then
    local context = context_for_token(token)
    if context then
      table.insert(spec.ephemeral_context, context)
      return true
    end
    return false
  end

  return false
end

function M.parse_input(lines, thread)
  lines = lines or {}
  local spec = {
    thread_id = thread and thread.id or nil,
    cwd = thread and thread.cwd or config.resolve_cwd(0),
    prompt = nil,
    command = nil,
    skills = inherit_request_selection(thread and thread.config.skills or {}),
    tools = inherit_request_selection(thread and thread.config.tools or {}),
    tool_groups = {},
    mcp_servers = inherit_request_selection(thread and thread.config.mcp_servers or {}),
    model = thread and thread.config.model or nil,
    model_override = false,
    reasoning_effort = thread and thread.config.reasoning_effort or nil,
    reasoning_override = false,
    temperature = nil,
    no_tools = false,
    ephemeral_context = {},
    images = {},
    display_prompt = nil,
    warnings = {},
    metadata = current_metadata(thread),
  }

  local prompt_lines = {}
  local original = table.concat(lines, "\n")
  spec.metadata.original_text = original

  for _, line in ipairs(lines) do
    local trimmed = util.trim(line)
    local token = trimmed:match("^([/@$>].*)$")
    if token then
      if not parse_token(token, spec, thread) then
        table.insert(spec.warnings, "Unknown Alma token kept in prompt: " .. token)
        table.insert(prompt_lines, line)
      end
    else
      table.insert(prompt_lines, line)
    end
  end

  spec.display_prompt = util.trim(table.concat(prompt_lines, "\n"))
  local prompt_without_images, display_prompt, images, image_warnings = extract_markdown_images(spec.display_prompt, thread)
  spec.prompt = util.trim(prompt_without_images)
  spec.display_prompt = display_prompt
  spec.images = images
  util.list_extend(spec.warnings, image_warnings)
  spec.skills = dedup_request_selection(spec.skills)
  spec.tools = dedup_request_selection(spec.tools)
  spec.mcp_servers = dedup_request_selection(spec.mcp_servers)

  local effective_model = spec.model or (thread and thread.config.model) or nil
  local effective_reasoning = spec.reasoning_effort or (thread and thread.config.reasoning_effort) or nil
  spec.metadata.model = effective_model
  spec.metadata.request_model = effective_model
  spec.metadata.requestModel = effective_model
  spec.metadata.modelOverride = spec.model_override
  spec.metadata.reasoning_effort = effective_reasoning
  spec.metadata.reasoningEffort = effective_reasoning
  spec.metadata.reasoningOverride = spec.reasoning_override
  return spec
end

function M.compile_request(thread, spec)
  local effective_model = spec.model or thread.config.model
  local effective_reasoning = spec.reasoning_effort or thread.config.reasoning_effort
  local parts = {}
  if spec.prompt ~= "" then
    table.insert(parts, { type = "text", text = spec.prompt })
  end
  for _, image in ipairs(spec.images or {}) do
    table.insert(parts, image)
  end
  local payload = {
    type = "generate_response",
    data = {
      threadId = thread.id,
      userMessage = {
        role = "user",
        parts = parts,
      },
      model = effective_model,
      reasoningEffort = effective_reasoning,
      tools = payload_tool_selection(spec.tools),
      enabledMCPServerIds = spec.mcp_servers,
      source = "alma_nvim",
      noTools = spec.no_tools,
      ephemeralModel = spec.model_override and effective_model or vim.NIL,
      userMessageMetadata = spec.metadata,
      ephemeralContext = spec.ephemeral_context,
      fromQuickChat = false,
      hummingbirdContext = vim.NIL,
    },
  }

  if has_request_selection(spec.skills) then
    -- Alma's observed handler does not document this field, but keeping it
    -- in metadata and the payload preserves per-request intent.
    payload.data.skillIds = spec.skills
    payload.data.userMessageMetadata.skillIds = spec.skills
  end

  return payload
end

return M
