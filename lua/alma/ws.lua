local util = require("alma.util")

local bit = require("bit")

local M = {}
local Client = {}
Client.__index = Client

local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

local function base64(data)
  return ((data:gsub(".", function(x)
    local r = ""
    local byte = x:byte()
    for i = 8, 1, -1 do
      r = r .. (byte % 2 ^ i - byte % 2 ^ (i - 1) > 0 and "1" or "0")
    end
    return r
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

local function parse_url(url)
  local scheme, rest = url:match("^(wss?)://(.+)$")
  if not scheme then
    return nil, "invalid websocket url: " .. tostring(url)
  end
  local host_port, path = rest:match("^([^/]+)(/.*)$")
  path = path or "/"
  host_port = host_port or rest
  local host, port = host_port:match("^([^:]+):(%d+)$")
  host = host or host_port
  port = tonumber(port) or (scheme == "wss" and 443 or 80)
  return { scheme = scheme, host = host, port = port, path = path }
end

local function random_key()
  local bytes = {}
  math.randomseed(os.time() + math.floor(vim.uv.hrtime() % 1000000))
  for i = 1, 16 do
    bytes[i] = string.char(math.random(0, 255))
  end
  return base64(table.concat(bytes))
end

local function pack_u16(value)
  return string.char(bit.band(bit.rshift(value, 8), 0xff), bit.band(value, 0xff))
end

local function pack_u64(value)
  local high = math.floor(value / 4294967296)
  local low = value % 4294967296
  return string.char(
    bit.band(bit.rshift(high, 24), 0xff),
    bit.band(bit.rshift(high, 16), 0xff),
    bit.band(bit.rshift(high, 8), 0xff),
    bit.band(high, 0xff),
    bit.band(bit.rshift(low, 24), 0xff),
    bit.band(bit.rshift(low, 16), 0xff),
    bit.band(bit.rshift(low, 8), 0xff),
    bit.band(low, 0xff)
  )
end

local function read_u16(data, offset)
  local a, b = data:byte(offset, offset + 1)
  return a * 256 + b
end

local function read_u64(data, offset)
  local bytes = { data:byte(offset, offset + 7) }
  local value = 0
  for _, byte in ipairs(bytes) do
    value = value * 256 + byte
  end
  return value
end

local function mask_payload(payload, key)
  local out = {}
  local k = { key:byte(1, 4) }
  for i = 1, #payload do
    out[i] = string.char(bit.bxor(payload:byte(i), k[((i - 1) % 4) + 1]))
  end
  return table.concat(out)
end

local function encode_frame(payload, opcode)
  opcode = opcode or 1
  local len = #payload
  local header = string.char(bit.bor(0x80, opcode))
  if len < 126 then
    header = header .. string.char(bit.bor(0x80, len))
  elseif len <= 65535 then
    header = header .. string.char(bit.bor(0x80, 126)) .. pack_u16(len)
  else
    header = header .. string.char(bit.bor(0x80, 127)) .. pack_u64(len)
  end

  local mask = string.char(math.random(0, 255), math.random(0, 255), math.random(0, 255), math.random(0, 255))
  return header .. mask .. mask_payload(payload, mask)
end

local function decode_frames(buffer, on_frame)
  local offset = 1
  while #buffer - offset + 1 >= 2 do
    local b1, b2 = buffer:byte(offset, offset + 1)
    local fin = bit.band(b1, 0x80) ~= 0
    local opcode = bit.band(b1, 0x0f)
    local masked = bit.band(b2, 0x80) ~= 0
    local len = bit.band(b2, 0x7f)
    local header_len = 2
    if len == 126 then
      if #buffer - offset + 1 < 4 then
        break
      end
      len = read_u16(buffer, offset + 2)
      header_len = 4
    elseif len == 127 then
      if #buffer - offset + 1 < 10 then
        break
      end
      len = read_u64(buffer, offset + 2)
      header_len = 10
    end

    local mask = ""
    if masked then
      if #buffer - offset + 1 < header_len + 4 then
        break
      end
      mask = buffer:sub(offset + header_len, offset + header_len + 3)
      header_len = header_len + 4
    end

    if #buffer - offset + 1 < header_len + len then
      break
    end

    local payload = buffer:sub(offset + header_len, offset + header_len + len - 1)
    if masked then
      payload = mask_payload(payload, mask)
    end
    on_frame({ fin = fin, opcode = opcode, payload = payload })
    offset = offset + header_len + len
  end
  return buffer:sub(offset)
end

local function close_tcp(tcp)
  if not tcp then
    return
  end
  pcall(function()
    tcp:close()
  end)
end

function Client.new(opts)
  return setmetatable(vim.tbl_deep_extend("force", {
    status = "offline",
    buffer = "",
    handshake = "",
    fragments = {},
  }, opts or {}), Client)
end

function Client:_status(status, message)
  self.status = status
  if self.on_status then
    vim.schedule(function()
      self.on_status(status, message)
    end)
  end
end

function Client:_error(message)
  self.last_error = message
  if self.on_error then
    vim.schedule(function()
      self.on_error(message)
    end)
  end
  self:_status("offline", message)
end

function Client:connect()
  if self.status == "connecting" or self.status == "online" then
    return
  end

  local parsed, err = parse_url(self.url)
  if not parsed then
    self:_error(err)
    return
  end
  if parsed.scheme == "wss" then
    self:_error("wss is not supported by the built-in MVP client; use local ws:// Alma API")
    return
  end

  self.parsed = parsed
  self:_status("connecting")
  self.connect_id = {}
  local connect_id = self.connect_id
  vim.uv.getaddrinfo(parsed.host, nil, { socktype = "stream" }, function(resolve_err, addresses)
    if self.connect_id ~= connect_id or self.status ~= "connecting" then
      return
    end
    if resolve_err or not addresses or not addresses[1] then
      self:_error(resolve_err or ("could not resolve " .. parsed.host))
      return
    end
    self:_connect_addresses(addresses, 1, nil, connect_id)
  end)
end

function Client:_connect_addresses(addresses, index, last_err, connect_id)
  if self.connect_id ~= connect_id or self.status ~= "connecting" then
    return
  end

  local address = addresses[index]
  if not address then
    self:_error(last_err or ("could not connect to " .. self.parsed.host .. ":" .. self.parsed.port))
    return
  end
  if not address.addr then
    self:_connect_addresses(addresses, index + 1, last_err, connect_id)
    return
  end

  local tcp = vim.uv.new_tcp()
  if not tcp then
    self:_connect_addresses(addresses, index + 1, "could not create tcp handle", connect_id)
    return
  end

  self.tcp = tcp
  tcp:connect(address.addr, self.parsed.port, function(connect_err)
    if self.connect_id ~= connect_id or self.tcp ~= tcp or self.status ~= "connecting" then
      close_tcp(tcp)
      return
    end
    if connect_err then
      close_tcp(tcp)
      self.tcp = nil
      self:_connect_addresses(
        addresses,
        index + 1,
        string.format("%s:%d: %s", address.addr, self.parsed.port, connect_err),
        connect_id
      )
      return
    end
    self:_start_read()
    self:_write_handshake()
  end)
end

function Client:_write_handshake()
  local parsed = self.parsed
  self.key = random_key()
  local host = parsed.host .. ":" .. parsed.port
  local request = table.concat({
    "GET " .. parsed.path .. " HTTP/1.1",
    "Host: " .. host,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. self.key,
    "Sec-WebSocket-Version: 13",
    "",
    "",
  }, "\r\n")
  self.tcp:write(request)
end

function Client:_start_read()
  self.tcp:read_start(function(err, chunk)
    if err then
      self:_error(err)
      return
    end
    if not chunk then
      self:_status("offline", "websocket closed")
      return
    end
    self:_on_data(chunk)
  end)
end

function Client:_on_data(chunk)
  if self.status ~= "online" then
    self.handshake = self.handshake .. chunk
    local head, rest = self.handshake:match("^(.-\r\n\r\n)(.*)$")
    if not head then
      return
    end
    if not head:match("^HTTP/1%.1 101") and not head:match("^HTTP/1%.0 101") then
      self:_error("websocket handshake failed: " .. head:gsub("\r\n.*", ""))
      return
    end
    self:_status("online")
    if rest ~= "" then
      self:_on_data(rest)
    end
    return
  end

  self.buffer = decode_frames(self.buffer .. chunk, function(frame)
    self:_on_frame(frame)
  end)
end

function Client:_on_frame(frame)
  if frame.opcode == 1 then
    if frame.fin then
      self:_emit_text(frame.payload)
    else
      self.fragments = { frame.payload }
    end
  elseif frame.opcode == 0 then
    table.insert(self.fragments, frame.payload)
    if frame.fin then
      self:_emit_text(table.concat(self.fragments))
      self.fragments = {}
    end
  elseif frame.opcode == 8 then
    self:close()
  elseif frame.opcode == 9 then
    self:send_raw(frame.payload, 10)
  end
end

function Client:_emit_text(payload)
  local decoded = util.json_decode(payload)
  if self.on_event then
    vim.schedule(function()
      self.on_event(decoded or payload)
    end)
  end
end

function Client:send_raw(payload, opcode)
  if self.status ~= "online" or not self.tcp then
    return false, "websocket is not online"
  end
  self.tcp:write(encode_frame(payload, opcode or 1))
  return true
end

function Client:send_json(payload)
  local encoded, err = util.json_encode(payload)
  if not encoded then
    return false, err
  end
  return self:send_raw(encoded, 1)
end

function Client:close()
  if self.tcp then
    pcall(function()
      self.tcp:read_stop()
      self.tcp:shutdown()
      self.tcp:close()
    end)
  end
  self.tcp = nil
  self.connect_id = nil
  self:_status("offline", "closed")
end

M.Client = Client
M.new = Client.new

M._test = {
  encode_frame = encode_frame,
  decode_frames = decode_frames,
  parse_url = parse_url,
}

return M
