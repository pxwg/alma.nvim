local M = {}

function M.now_ms()
  return math.floor(vim.uv.hrtime() / 1000000)
end

function M.trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

function M.is_blank(value)
  return M.trim(value) == ""
end

function M.split_lines(value)
  value = tostring(value or "")
  if value == "" then
    return {}
  end
  local lines = vim.split(value:gsub("\r\n", "\n"):gsub("\r", "\n"), "\n", { plain = true })
  if lines[#lines] == "" then
    table.remove(lines, #lines)
  end
  return lines
end

function M.to_lines(value)
  if type(value) == "table" then
    local ok, encoded = pcall(vim.inspect, value)
    return M.split_lines(ok and encoded or tostring(value))
  end
  return M.split_lines(value)
end

function M.json_encode(value)
  local ok, encoded = pcall(vim.json.encode, value)
  if ok then
    return encoded
  end
  return nil, encoded
end

function M.json_decode(value)
  if type(value) ~= "string" or value == "" then
    return nil, "empty json"
  end
  local ok, decoded = pcall(vim.json.decode, value, { luanil = { object = true, array = true } })
  if ok then
    return decoded
  end
  return nil, decoded
end

function M.notify(message, level)
  if require("alma.config").get().notify == false then
    return
  end
  vim.schedule(function()
    vim.notify(message, level or vim.log.levels.INFO, { title = "alma.nvim" })
  end)
end

function M.short_id(value)
  value = tostring(value or "")
  if #value <= 12 then
    return value
  end
  return value:sub(1, 6) .. "..." .. value:sub(-4)
end

function M.truthy(value)
  return value == true or value == 1 or value == "true"
end

function M.list_extend(dst, src)
  dst = dst or {}
  for _, item in ipairs(src or {}) do
    table.insert(dst, item)
  end
  return dst
end

function M.tbl_values(tbl)
  local values = {}
  for _, value in pairs(tbl or {}) do
    table.insert(values, value)
  end
  return values
end

function M.dedup(list)
  local seen = {}
  local out = {}
  for _, value in ipairs(list or {}) do
    if value ~= nil and value ~= "" and not seen[value] then
      seen[value] = true
      table.insert(out, value)
    end
  end
  return out
end

function M.read_buf_text(bufnr, max_bytes)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return ""
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local text = table.concat(lines, "\n")
  if max_bytes and #text > max_bytes then
    return text:sub(1, max_bytes) .. "\n[alma.nvim: truncated]"
  end
  return text
end

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function M.base64_encode(data)
  data = tostring(data or "")
  return ((data:gsub(".", function(x)
    local bits = ""
    local byte = x:byte()
    for i = 8, 1, -1 do
      bits = bits .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
    end
    return bits
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then
      return ""
    end
    local c = 0
    for i = 1, 6 do
      c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0)
    end
    return b64chars:sub(c + 1, c + 1)
  end) .. ({ "", "==", "=" })[#data % 3 + 1])
end

function M.read_file_bytes(path)
  local fd, open_err = vim.uv.fs_open(path, "r", 438)
  if not fd then
    return nil, open_err
  end
  local stat, stat_err = vim.uv.fs_fstat(fd)
  if not stat then
    vim.uv.fs_close(fd)
    return nil, stat_err
  end
  local data, read_err = vim.uv.fs_read(fd, stat.size, 0)
  vim.uv.fs_close(fd)
  return data, read_err
end

function M.open_or_focus_buf(bufnr)
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  vim.api.nvim_set_current_buf(bufnr)
  return true
end

function M.version_at_least(major, minor, patch)
  local v = vim.version()
  if v.major ~= major then
    return v.major > major
  end
  if v.minor ~= minor then
    return v.minor > minor
  end
  return v.patch >= patch
end

return M
