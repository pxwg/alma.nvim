local util = require("alma.util")

local M = {}

local attachments = {}

local function first_string(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return nil
end

local function first_present(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if value ~= nil then
      return value
    end
  end
  return nil
end

local function first_number(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "number" then
      return value
    end
    if type(value) == "string" and value ~= "" then
      local number = tonumber(value)
      if number then
        return number
      end
    end
  end
  return nil
end

local function normalize_thread_id(thread)
  if type(thread) == "table" then
    thread = thread.id or thread.thread_id or thread.threadId
  end
  if type(thread) ~= "string" or thread == "" then
    error("thread id is required")
  end
  return thread
end

local function attachment_kind(item)
  local kind = item.type or item.attachment_type or item.attachmentType
  if type(kind) == "string" then
    kind = kind:lower()
  end
  if kind == "file" or kind == "json" then
    return kind
  end
  if item.path then
    return "file"
  end
  local media_type = first_string(item.kind, item.media_type, item.mediaType)
  if media_type and media_type:lower():find("json", 1, true) then
    return "json"
  end
  if item.data ~= nil or item.json ~= nil or item.content ~= nil then
    return "json"
  end
  error("attachment type must be file or json")
end

local function json_id(item)
  if item.id and item.id ~= "" then
    return tostring(item.id)
  end
  local label = first_string(item.label, item.title, item.name)
  if label then
    return "json:" .. label
  end
  error("json attachments require id, title, or label")
end

local function file_id(path, item)
  if item.id and item.id ~= "" then
    return tostring(item.id)
  end
  return "file:" .. path
end

local function normalize_bool(value)
  if value == nil then
    return nil
  end
  return value ~= false
end

local function normalize_attachment(item)
  if type(item) ~= "table" then
    error("attachment must be a table")
  end

  local kind = attachment_kind(item)
  local normalized = {
    type = kind,
    once = item.once == true,
    label = first_string(item.label, item.title, item.name),
    visibility = first_string(item.visibility),
    metadata = type(item.metadata) == "table" and vim.deepcopy(item.metadata) or {},
    inline = normalize_bool(first_present(item.inline, item.inline_json, item.inlineJson)),
    file_backed = item.file_backed == true or item.fileBacked == true,
    max_inline_bytes = first_number(item.max_inline_bytes, item.maxInlineBytes),
  }

  if kind == "file" then
    if type(item.path) ~= "string" or item.path == "" then
      error("file attachments require path")
    end
    normalized.path = vim.fn.fnamemodify(item.path, ":p")
    normalized.id = file_id(normalized.path, item)
    normalized.label = normalized.label or vim.fn.fnamemodify(normalized.path, ":t")
    normalized.media_type = first_string(item.media_type, item.mediaType, item.kind)
  else
    if type(item.path) == "string" and item.path ~= "" then
      normalized.path = vim.fn.fnamemodify(item.path, ":p")
      normalized.file_backed = true
    end
    local data = item.data
    if data == nil then
      data = item.json
    end
    if data == nil then
      data = item.content
    end
    if data == nil and not normalized.path then
      error("json attachments require data, content, or path")
    end
    if data ~= nil then
      normalized.data = vim.deepcopy(data)
    end
    normalized.id = json_id(item)
    normalized.label = normalized.label or normalized.id
    normalized.media_type = first_string(item.media_type, item.mediaType, item.kind, "application/json")
  end

  return normalized
end

local function ensure_bucket(thread_id)
  local bucket = attachments[thread_id]
  if not bucket then
    bucket = { order = {}, by_id = {} }
    attachments[thread_id] = bucket
  end
  return bucket
end

local function snapshot(item)
  return vim.deepcopy(item)
end

local function compact_label(item)
  return first_string(item.label, item.title, item.name, item.id, item.path, "attachment")
end

local function sanitize_stem(value)
  value = tostring(value or "attachment"):gsub("[^%w%._%-]+", "-"):gsub("^%-+", ""):gsub("%-+$", "")
  if value == "" then
    return "attachment"
  end
  return value:sub(1, 80)
end

local function json_text(data)
  if type(data) == "string" then
    return data
  end
  local encoded, err = util.json_encode(data)
  if not encoded then
    error("json attachment is not encodable: " .. tostring(err))
  end
  return encoded
end

local function json_temp_path(item)
  local dir = vim.fn.stdpath("cache") .. "/alma/attachments"
  local ok, err = pcall(vim.fn.mkdir, dir, "p")
  if not ok then
    error("failed to create attachment cache directory: " .. tostring(err))
  end
  return dir
    .. "/"
    .. sanitize_stem(first_string(item.id, item.label, item.title, "attachment"))
    .. "-"
    .. tostring(util.now_ms())
    .. ".json"
end

local function write_json_file(item, data)
  local path = item.path
  if not path or path == "" then
    path = json_temp_path(item)
  end
  local text = json_text(data)
  local ok, result = pcall(vim.fn.writefile, { text }, path, "b")
  if not ok or result ~= 0 then
    error("failed to write json attachment file: " .. tostring(ok and result or result))
  end
  return vim.fn.fnamemodify(path, ":p")
end

local function json_uses_file(item, data)
  if item.path then
    return true
  end
  if item.file_backed == true or item.inline == false then
    return true
  end
  if item.max_inline_bytes then
    return #json_text(data) > item.max_inline_bytes
  end
  return false
end

local function finalize_context(out)
  if type(out.metadata) == "table" and not next(out.metadata) then
    out.metadata = nil
  end
  if out.label == nil then
    out.label = out.title
  end
  if out.title == nil then
    out.title = out.label
  end
  if out.mediaType == nil then
    out.mediaType = nil
  end
  return out
end

function M.attach(thread, item)
  local thread_id = normalize_thread_id(thread)
  local normalized = normalize_attachment(item)
  local bucket = ensure_bucket(thread_id)
  if not bucket.by_id[normalized.id] then
    table.insert(bucket.order, normalized.id)
  end
  bucket.by_id[normalized.id] = normalized
  return snapshot(normalized)
end

function M.detach(thread, id)
  local thread_id = normalize_thread_id(thread)
  local bucket = attachments[thread_id]
  if not bucket or not bucket.by_id[id] then
    return false
  end
  bucket.by_id[id] = nil
  for index, existing in ipairs(bucket.order) do
    if existing == id then
      table.remove(bucket.order, index)
      break
    end
  end
  if #bucket.order == 0 then
    attachments[thread_id] = nil
  end
  return true
end

function M.list(thread)
  local thread_id = normalize_thread_id(thread)
  local bucket = attachments[thread_id]
  if not bucket then
    return {}
  end
  local out = {}
  for _, id in ipairs(bucket.order) do
    local item = bucket.by_id[id]
    if item then
      table.insert(out, snapshot(item))
    end
  end
  return out
end

function M.consume(thread)
  local thread_id = normalize_thread_id(thread)
  local bucket = attachments[thread_id]
  if not bucket then
    return {}
  end

  local out = {}
  local keep_order = {}
  local keep_by_id = {}
  for _, id in ipairs(bucket.order) do
    local item = bucket.by_id[id]
    if item then
      table.insert(out, snapshot(item))
      if item.once ~= true then
        table.insert(keep_order, id)
        keep_by_id[id] = item
      end
    end
  end

  if #keep_order == 0 then
    attachments[thread_id] = nil
  else
    attachments[thread_id] = {
      order = keep_order,
      by_id = keep_by_id,
    }
  end

  return out
end

function M.to_ephemeral_context(item)
  if type(item) ~= "table" then
    error("attachment must be a table")
  end
  local kind = attachment_kind(item)
  local metadata = type(item.metadata) == "table" and vim.deepcopy(item.metadata) or {}
  local label = compact_label(item)
  local out = {
    type = kind,
    id = item.id,
    title = label,
    label = label,
    metadata = metadata,
  }
  if kind == "file" then
    out.path = item.path
    out.mediaType = item.media_type or item.mediaType
  else
    local data = first_present(item.data, item.json, item.content)
    if json_uses_file(item, data) then
      out.type = "file"
      out.path = item.path and vim.fn.fnamemodify(item.path, ":p") or write_json_file(item, data)
      out.mediaType = item.media_type or item.mediaType or "application/json"
      out.metadata = vim.tbl_deep_extend("force", metadata, {
        attachmentType = "json",
        fileBacked = true,
      })
    else
      json_text(data)
      out.content = vim.deepcopy(data)
      out.data = vim.deepcopy(data)
      out.mediaType = item.media_type or item.mediaType or "application/json"
    end
  end
  return finalize_context(out)
end

function M.to_ephemeral_context_list(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    table.insert(out, M.to_ephemeral_context(item))
  end
  return out
end

function M.consume_ephemeral_context(thread)
  return M.to_ephemeral_context_list(M.consume(thread))
end

local function message_part_filename(item, fallback_ext)
  local path = item.path
  if type(path) == "string" and path ~= "" then
    return vim.fn.fnamemodify(path, ":t")
  end
  local stem = sanitize_stem(first_string(item.id, item.label, item.title, "attachment"))
  return stem .. (fallback_ext or "")
end

function M.to_message_part(item)
  if type(item) ~= "table" then
    return nil, "attachment must be a table"
  end

  local kind = attachment_kind(item)
  local media_type = item.media_type or item.mediaType or (kind == "json" and "application/json" or "application/octet-stream")
  local data
  local filename

  if kind == "file" then
    data = util.read_file_bytes(item.path)
    filename = message_part_filename(item)
  else
    local json_data = first_present(item.data, item.json, item.content)
    if item.path then
      data = util.read_file_bytes(item.path)
      filename = message_part_filename(item, ".json")
    else
      local ok, encoded = pcall(json_text, json_data)
      if not ok then
        return nil, encoded
      end
      data = encoded
      filename = message_part_filename(item, ".json")
    end
  end

  if not data then
    return nil, "unable to read attachment " .. tostring(item.path or item.id)
  end

  return {
    type = "file",
    mediaType = media_type,
    url = "data:" .. media_type .. ";base64," .. util.base64_encode(data),
    filename = filename,
    metadata = {
      attachmentId = item.id,
      attachmentLabel = compact_label(item),
      source = "alma.context",
    },
  }
end

function M.to_message_parts(items)
  local parts = {}
  local warnings = {}
  for _, item in ipairs(items or {}) do
    local part, err = M.to_message_part(item)
    if part then
      table.insert(parts, part)
    elseif err then
      table.insert(warnings, err)
    end
  end
  return parts, warnings
end

function M.compact_metadata(items)
  local labels = {}
  local compact_items = {}
  for _, item in ipairs(items or {}) do
    local label = compact_label(item)
    table.insert(labels, label)
    local compact = {
      id = item.id,
      type = item.type,
      label = label,
      mediaType = item.media_type or item.mediaType,
      once = item.once == true or nil,
    }
    if item.type == "file" or item.path then
      compact.filename = vim.fn.fnamemodify(item.path or "", ":t")
    end
    if item.type == "json" and (item.path or item.file_backed == true or item.inline == false) then
      compact.fileBacked = true
    end
    table.insert(compact_items, compact)
  end
  return {
    count = #compact_items,
    labels = labels,
    items = compact_items,
  }
end

function M.apply_compact_metadata(spec, items)
  if type(spec) ~= "table" then
    return nil
  end
  local summary = M.compact_metadata(items)
  if summary.count == 0 then
    return summary
  end
  spec.metadata = spec.metadata or {}
  spec.metadata.attachments = summary.items
  spec.metadata.attachment_count = summary.count
  spec.metadata.attachmentCount = summary.count
  spec.metadata.attachment_labels = summary.labels
  spec.metadata.attachmentLabels = summary.labels
  return summary
end

function M.clear(thread)
  if thread == nil then
    attachments = {}
    return
  end
  attachments[normalize_thread_id(thread)] = nil
end

function M._reset()
  M.clear()
end

return M
