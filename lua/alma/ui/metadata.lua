local tokens = require("alma.ui.tokens")
local util = require("alma.util")

local M = {}

local function first_text(...)
  for index = 1, select("#", ...) do
    local value = select(index, ...)
    if type(value) == "string" and value ~= "" then
      return value
    end
  end
  return ""
end

local function metadata_of(item)
  if type(item) ~= "table" then
    return {}
  end
  local msg = type(item.message) == "table" and item.message or {}
  return vim.tbl_deep_extend(
    "force",
    {},
    msg.metadata or {},
    msg.userMessageMetadata or {},
    item.metadata or {},
    item.userMessageMetadata or {}
  )
end

local function normalize(value)
  if type(value) ~= "string" then
    return nil
  end
  value = util.trim(value)
  if value == "" then
    return nil
  end
  return value
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

local function attachment_meta(block)
  if type(block) ~= "table" then
    return {}
  end
  local source = block
  local meta = type(block.metadata) == "table" and block.metadata or {}
  local count = first_number(source.attachment_count, source.attachmentCount, meta.attachment_count, meta.attachmentCount)
  if not count or count <= 0 then
    return {}
  end
  local labels = source.attachment_labels or source.attachmentLabels or meta.attachment_labels or meta.attachmentLabels
  local out = {}
  if type(labels) == "table" then
    local limit = math.min(#labels, 2)
    for index = 1, limit do
      local label = normalize(labels[index])
      if label then
        table.insert(out, label)
      end
    end
  end
  local remaining = count - #out
  if remaining > 0 then
    table.insert(out, tostring(remaining) .. (remaining == 1 and " attachment" or " attachments"))
  elseif count == 1 and #out == 0 then
    table.insert(out, "1 attachment")
  end
  return out
end

function M.model_label(value)
  value = normalize(value)
  if not value then
    return nil
  end
  return value:match("([^:]+)$") or value
end

function M.from_metadata(metadata)
  if type(metadata) ~= "table" then
    return nil
  end
  local legacy = tokens.extract_selectors(first_text(metadata.original_text, metadata.originalText))
  local model = normalize(first_text(
    metadata.request_model,
    metadata.requestModel,
    metadata.requestModelId,
    metadata.ephemeralModel,
    metadata.modelOverride == true and legacy.model or nil,
    metadata.model,
    metadata.modelId,
    legacy.model
  ))
  local reasoning = normalize(first_text(
    metadata.request_reasoning_effort,
    metadata.requestReasoningEffort,
    metadata.reasoningOverride == true and legacy.reasoning_effort or nil,
    metadata.reasoning_effort,
    metadata.reasoningEffort,
    legacy.reasoning_effort
  ))
  if not model and not reasoning then
    return nil
  end
  return {
    model = model,
    reasoning_effort = reasoning,
    model_override = metadata.modelOverride == true,
    reasoning_override = metadata.reasoningOverride == true,
  }
end

function M.from_message(item)
  if type(item) ~= "table" then
    return nil
  end
  return M.from_metadata(metadata_of(item))
end

function M.from_request(request)
  if type(request) ~= "table" then
    return nil
  end
  local spec = request.spec or request
  local payload = request.payload and request.payload.data or request.data or {}
  local payload_metadata = type(payload.userMessageMetadata) == "table" and payload.userMessageMetadata or {}
  local spec_metadata = type(spec.metadata) == "table" and spec.metadata or {}
  local metadata = vim.tbl_deep_extend("force", {}, payload_metadata, spec_metadata)
  local from_metadata = M.from_metadata(metadata) or {}
  local model = normalize(first_text(spec.model, payload.model, payload.ephemeralModel, from_metadata.model))
  local reasoning = normalize(first_text(
    spec.reasoning_effort,
    payload.reasoningEffort,
    payload.reasoning_effort,
    from_metadata.reasoning_effort
  ))
  if not model and not reasoning then
    return nil
  end
  return {
    model = model,
    reasoning_effort = reasoning,
    model_override = spec.model_override == true or from_metadata.model_override == true,
    reasoning_override = spec.reasoning_override == true or from_metadata.reasoning_override == true,
  }
end

function M.from_options(options)
  if type(options) ~= "table" then
    return nil
  end
  local model = normalize(first_text(options.model, options.request_model, options.requestModel))
  local reasoning = normalize(first_text(options.reasoning_effort, options.reasoningEffort))
  if not model and not reasoning then
    return nil
  end
  return {
    model = model,
    reasoning_effort = reasoning,
  }
end

function M.from_block(block)
  if type(block) ~= "table" then
    return nil
  end
  local direct = {
    model = block.request_model or block.model,
    request_model = block.request_model,
    requestModel = block.requestModel,
    reasoning_effort = block.request_reasoning_effort or block.reasoning_effort,
    reasoningEffort = block.request_reasoning_effort or block.reasoningEffort,
    modelOverride = block.model_override,
    reasoningOverride = block.reasoning_override,
  }
  local from_direct = M.from_metadata(direct)
  if from_direct then
    return from_direct
  end
  return M.from_metadata(block.metadata) or M.from_message(block.raw)
end

function M.resolve(thread, opts)
  opts = opts or {}
  local resolved = M.from_block(opts.block) or M.from_request(opts.request)
  if resolved or opts.include_current_request == false then
    return resolved
  end
  return M.from_request(thread and thread.pending_request)
end

function M.apply_to_block(block, request_metadata)
  if not block then
    return block
  end
  request_metadata = M.from_metadata(block.metadata) or M.from_message(block.raw) or request_metadata
  if not request_metadata then
    return block
  end
  block.request_model = request_metadata.model
  block.request_reasoning_effort = request_metadata.reasoning_effort
  block.model_override = request_metadata.model_override
  block.reasoning_override = request_metadata.reasoning_override
  return block
end

function M.request_labels(request_metadata)
  local labels = {}
  if not request_metadata then
    return labels
  end
  local model_name = M.model_label(request_metadata.model)
  if model_name then
    table.insert(labels, model_name)
  end
  if request_metadata.reasoning_effort then
    table.insert(labels, "effort " .. tostring(request_metadata.reasoning_effort))
  end
  return labels
end

function M.composer_labels(thread, request)
  local current_request = request or thread and thread.pending_request
  return M.request_labels(M.from_request(current_request) or M.from_options(thread and thread.config))
end

function M.user_labels(thread, block, request)
  local request_metadata = M.resolve(thread, {
    block = block,
    request = request,
    include_current_request = false,
  })
  local labels = M.request_labels(request_metadata)
  util.list_extend(labels, attachment_meta(block))
  return labels
end

function M.assistant_labels(thread, block, request)
  local request_metadata = M.resolve(thread, {
    block = block,
    request = request,
    include_current_request = false,
  })
  local labels = M.request_labels(request_metadata)
  if block and block.state and block.state ~= "" and block.state ~= "done" then
    table.insert(labels, tostring(block.state))
  end
  return labels
end

function M.context_label(thread, block)
  if block then
    local remaining = first_number(block.context_remaining, block.contextRemaining, block.remaining_context)
    if remaining then
      return "ctx remaining " .. tostring(remaining)
    end
    local context_count = first_number(block.context_count, block.contextCount)
    if context_count and context_count > 0 then
      return "ctx " .. tostring(context_count)
    end
  end

  local usage = thread and thread.context_usage
  if type(usage) ~= "table" then
    return nil
  end
  local remaining = first_number(
    usage.remaining,
    usage.remainingTokens,
    usage.contextRemaining,
    usage.tokensRemaining,
    usage.available,
    usage.availableTokens
  )
  if remaining then
    return "ctx remaining " .. tostring(remaining)
  end
  local used = first_number(usage.used, usage.tokens, usage.inputTokens, usage.usedTokens)
  local total = first_number(usage.total, usage.limit, usage.max, usage.maxTokens, usage.contextWindow)
  if used and total then
    return "ctx " .. tostring(used) .. "/" .. tostring(total)
  end
  if used then
    return "ctx used " .. tostring(used)
  end
  return nil
end

return M
