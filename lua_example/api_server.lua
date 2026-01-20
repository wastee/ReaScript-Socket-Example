local json = (function()
  --
  -- json.lua
  --
  -- Copyright (c) 2020 rxi
  --
  -- Permission is hereby granted, free of charge, to any person obtaining a copy of
  -- this software and associated documentation files (the "Software"), to deal in
  -- the Software without restriction, including without limitation the rights to
  -- use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies
  -- of the Software, and to permit persons to whom the Software is furnished to do
  -- so, subject to the following conditions:
  --
  -- The above copyright notice and this permission notice shall be included in all
  -- copies or substantial portions of the Software.
  --
  -- THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  -- IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  -- FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  -- AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  -- LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  -- OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
  -- SOFTWARE.
  --

  local json = { _version = "0.1.2" }

  json.null = {}

  -------------------------------------------------------------------------------
  -- Encode
  -------------------------------------------------------------------------------

  local encode

  local escape_char_map = {
    ["\\"] = "\\",
    ["\""] = "\"",
    ["\b"] = "b",
    ["\f"] = "f",
    ["\n"] = "n",
    ["\r"] = "r",
    ["\t"] = "t",
  }

  local escape_char_map_inv = { ["/"] = "/" }
  for k, v in pairs(escape_char_map) do
    escape_char_map_inv[v] = k
  end

  local function escape_char(c)
    return "\\" .. (escape_char_map[c] or string.format("u%04x", c:byte()))
  end

  local function encode_nil(_)
    return "null"
  end

  local function encode_table(val, stack)
    local res = {}
    stack = stack or {}

    -- Circular reference?
    if stack[val] then error("circular reference") end

    stack[val] = true

    if rawget(val, 1) ~= nil or next(val) == nil then
      -- Treat as array -- check keys are valid and it is not sparse
      local n = 0
      for k in pairs(val) do
        if type(k) ~= "number" then
          error("invalid table: mixed or invalid key types")
        end
        n = n + 1
      end
      if n ~= #val then
        error("invalid table: sparse array")
      end
      -- Encode
      for _, v in ipairs(val) do
        table.insert(res, encode(v, stack))
      end
      stack[val] = nil
      return "[" .. table.concat(res, ",") .. "]"

    else
      -- Treat as an object
      for k, v in pairs(val) do
        if type(k) ~= "string" then
          error("invalid table: mixed or invalid key types")
        end
        table.insert(res, encode(k, stack) .. ":" .. encode(v, stack))
      end
      stack[val] = nil
      return "{" .. table.concat(res, ",") .. "}"
    end
  end

  local function encode_string(val)
    return '"' .. val:gsub('[%z\1-\31\\"]', escape_char) .. '"'
  end

  local function encode_number(val)
    -- Check for NaN, -inf and inf
    if val ~= val or val <= -math.huge or val >= math.huge then
      error("unexpected number value '" .. tostring(val) .. "'")
    end
    return string.format("%.14g", val)
  end

  local type_func_map = {
    ["nil"] = encode_nil,
    ["table"] = encode_table,
    ["string"] = encode_string,
    ["number"] = encode_number,
    ["boolean"] = tostring,
  }

  encode = function(val, stack)
    if val == json.null then
      return "null"
    end

    local t = type(val)
    local f = type_func_map[t]
    if f then
      return f(val, stack)
    end
    error("unexpected type '" .. t .. "'")
  end

  function json.encode(val)
    return (encode(val))
  end

  -------------------------------------------------------------------------------
  -- Decode
  -------------------------------------------------------------------------------

  local parse

  local function create_set(...)
    local res = {}
    for i = 1, select("#", ...) do
      res[select(i, ...)] = true
    end
    return res
  end

  local space_chars = create_set(" ", "\t", "\r", "\n")
  local delim_chars = create_set(" ", "\t", "\r", "\n", "]", "}", ",")
  local escape_chars = create_set("\\", "/", '"', "b", "f", "n", "r", "t", "u")
  local literals = create_set("true", "false", "null")

  local literal_map = {
    ["true"] = true,
    ["false"] = false,
    ["null"] = json.null,
  }

  local function next_char(str, idx, set, negate)
    for i = idx, #str do
      if set[str:sub(i, i)] ~= negate then
        return i
      end
    end
    return #str + 1
  end

  local function decode_error(str, idx, msg)
    local line_count = 1
    local col_count = 1
    for i = 1, idx - 1 do
      col_count = col_count + 1
      if str:sub(i, i) == "\n" then
        line_count = line_count + 1
        col_count = 1
      end
    end
    error(string.format("%s at line %d col %d", msg, line_count, col_count))
  end

  local function codepoint_to_utf8(n)
    -- http://scripts.sil.org/cms/scripts/page.php?site_id=nrsi&id=iws-appendixa
    local f = math.floor
    if n <= 0x7f then
      return string.char(n)
    elseif n <= 0x7ff then
      return string.char(f(n / 64) + 192, n % 64 + 128)
    elseif n <= 0xffff then
      return string.char(f(n / 4096) + 224, f(n % 4096 / 64) + 128, n % 64 + 128)
    elseif n <= 0x10ffff then
      return string.char(
        f(n / 262144) + 240,
        f(n % 262144 / 4096) + 128,
        f(n % 4096 / 64) + 128,
        n % 64 + 128
      )
    end
    error(string.format("invalid unicode codepoint '%x'", n))
  end

  local function parse_unicode_escape(s)
    local n1 = tonumber(s:sub(1, 4), 16)
    local n2 = tonumber(s:sub(7, 10), 16)
    -- Surrogate pair?
    if n2 then
      return codepoint_to_utf8((n1 - 0xd800) * 0x400 + (n2 - 0xdc00) + 0x10000)
    else
      return codepoint_to_utf8(n1)
    end
  end

  local function parse_string(str, i)
    local res = ""
    local j = i + 1
    local k = j

    while j <= #str do
      local x = str:byte(j)

      if x < 32 then
        decode_error(str, j, "control character in string")

      elseif x == 92 then -- `\`: Escape
        res = res .. str:sub(k, j - 1)
        j = j + 1
        local c = str:sub(j, j)
        if c == "u" then
          local hex = str:match("^[dD][89aAbB]%x%x\\u%x%x%x%x", j + 1)
            or str:match("^%x%x%x%x", j + 1)
            or decode_error(str, j - 1, "invalid unicode escape in string")
          res = res .. parse_unicode_escape(hex)
          j = j + #hex
        else
          if not escape_chars[c] then
            decode_error(str, j - 1, "invalid escape char '" .. c .. "' in string")
          end
          res = res .. escape_char_map_inv[c]
        end
        k = j + 1

      elseif x == 34 then -- `"`: End of string
        res = res .. str:sub(k, j - 1)
        return res, j + 1
      end

      j = j + 1
    end

    decode_error(str, i, "expected closing quote for string")
  end

  local function parse_number(str, i)
    local x = next_char(str, i, delim_chars)
    local s = str:sub(i, x - 1)
    local n = tonumber(s)
    if not n then
      decode_error(str, i, "invalid number '" .. s .. "'")
    end
    return n, x
  end

  local function parse_literal(str, i)
    local x = next_char(str, i, delim_chars)
    local word = str:sub(i, x - 1)
    if not literals[word] then
      decode_error(str, i, "invalid literal '" .. word .. "'")
    end
    return literal_map[word], x
  end

  local function parse_array(str, i)
    local res = {}
    local n = 1
    i = i + 1
    while true do
      local x
      i = next_char(str, i, space_chars, true)
      -- Empty / end of array?
      if str:sub(i, i) == "]" then
        i = i + 1
        break
      end
      -- Read token
      x, i = parse(str, i)
      res[n] = x
      n = n + 1
      -- Next token
      i = next_char(str, i, space_chars, true)
      local chr = str:sub(i, i)
      i = i + 1
      if chr == "]" then break end
      if chr ~= "," then decode_error(str, i, "expected ']' or ','") end
    end
    return res, i
  end

  local function parse_object(str, i)
    local res = {}
    i = i + 1
    while true do
      local key, val
      i = next_char(str, i, space_chars, true)
      -- Empty / end of object?
      if str:sub(i, i) == "}" then
        i = i + 1
        break
      end
      -- Read key
      if str:sub(i, i) ~= '"' then
        decode_error(str, i, "expected string for key")
      end
      key, i = parse(str, i)
      -- Read ':' delimiter
      i = next_char(str, i, space_chars, true)
      if str:sub(i, i) ~= ":" then
        decode_error(str, i, "expected ':' after key")
      end
      i = next_char(str, i + 1, space_chars, true)
      -- Read value
      val, i = parse(str, i)
      -- Set
      res[key] = val
      -- Next token
      i = next_char(str, i, space_chars, true)
      local chr = str:sub(i, i)
      i = i + 1
      if chr == "}" then break end
      if chr ~= "," then decode_error(str, i, "expected '}' or ','") end
    end
    return res, i
  end

  local char_func_map = {
    ['"'] = parse_string,
    ["0"] = parse_number,
    ["1"] = parse_number,
    ["2"] = parse_number,
    ["3"] = parse_number,
    ["4"] = parse_number,
    ["5"] = parse_number,
    ["6"] = parse_number,
    ["7"] = parse_number,
    ["8"] = parse_number,
    ["9"] = parse_number,
    ["-"] = parse_number,
    ["t"] = parse_literal,
    ["f"] = parse_literal,
    ["n"] = parse_literal,
    ["["] = parse_array,
    ["{"] = parse_object,
  }

  parse = function(str, idx)
    local chr = str:sub(idx, idx)
    local f = char_func_map[chr]
    if f then
      return f(str, idx)
    end
    decode_error(str, idx, "unexpected character '" .. chr .. "'")
  end

  function json.decode(str)
    if type(str) ~= "string" then
      error("expected argument of type string, got " .. type(str))
    end
    local res, idx = parse(str, next_char(str, 1, space_chars, true))
    idx = next_char(str, idx, space_chars, true)
    if idx <= #str then
      decode_error(str, idx, "trailing garbage")
    end
    return res
  end

  return json
end)()

-- Server Code Start -----------------------------------------------------------------------------

local os_name = reaper.GetOS()
local ext = os_name:match("Win") and "dll" or (os_name:match("OSX") and "so" or "so.linux")
local socket_path = reaper.GetResourcePath() .. "/Scripts/Daniel Lumertz Scripts/LUA Sockets/socket module/?." .. ext
package.cpath = package.cpath .. ";" .. socket_path
package.path = package.path .. ";" .. socket_path:gsub("%?%..*$", "?.lua")

local socket = require("socket")
local HOST, PORT = "127.0.0.1", 9999

local function pack_u32le(n) return string.pack("<I4", n) end
local function unpack_u32le(s) return string.unpack("<I4", s) end

local Server = {}
Server.__index = Server

function Server.new(host, port)
  local self = setmetatable({}, Server)
  self.host = host or HOST
  self.port = port or PORT

  self._listen = assert(socket.bind(self.host, self.port, 5))
  self._listen:settimeout(0)

  self._conn = nil
  self._recv_buf = ""
  self._send_buf = ""
  self._expect_len = nil
  self._holding = false

  return self
end

function Server:_reset()
  self._holding = false
  if self._conn then pcall(function() self._conn:close() end) end
  self._conn = nil
  self._recv_buf = ""
  self._send_buf = ""
  self._expect_len = nil
end

function Server:_send(obj)
  local payload = json.encode(obj)
  self._send_buf = self._send_buf .. pack_u32le(#payload) .. payload
end

function Server:_flush()
  if not self._conn or self._send_buf == "" then return end

  local sent, err = self._conn:send(self._send_buf)
  if sent and sent > 0 then
    self._send_buf = self._send_buf:sub(sent + 1)
    return
  end

  if err ~= "timeout" then self:_reset() end
end

function Server:_result(id, value)
  if value == nil then value = json.null end
  self:_send({ id = id, type = "result", value = value })
end

function Server:_error(id, traceback)
  self:_send({ id = id, type = "error", traceback = traceback })
end

function Server:_call(req)
  local fn = reaper[req.name]
  if type(fn) ~= "function" then error("function not found: " .. tostring(req.name)) end

  local args = req.args or {}
  for i = 1, #args do
    if args[i] == json.null then args[i] = nil end
  end

  local rets = table.pack(fn(table.unpack(args)))
  local value
  if rets.n == 0 then
    value = json.null
  elseif rets.n == 1 then
    value = rets[1] == nil and json.null or rets[1]
  else
    value = {}
    for i = 1, rets.n do
      value[i] = rets[i] == nil and json.null or rets[i]
    end
  end

  self:_result(req.id, value)
end

function Server:_control(req)
  local cmd = req.cmd
  if cmd == "HOLD" then
    self._holding = true
    self:_result(req.id, json.null)
    self:_flush()
    self:_hold_loop()
  elseif cmd == "RELEASE" then
    self._holding = false
    self:_result(req.id, json.null)
  else
    error("unknown control cmd: " .. tostring(cmd))
  end
end

function Server:_handle(body)
  local request_id = nil
  local ok, tb = xpcall(function()
    local req = json.decode(body)
    if type(req) ~= "table" then error("request must be an object") end

    request_id = req.id
    if req.type == "call" then
      self:_call(req)
    elseif req.type == "control" then
      self:_control(req)
    else
      error("unsupported request type: " .. tostring(req.type))
    end
  end, function(e) return debug.traceback(e, 2) end)

  if not ok then self:_error(request_id, tb) end
end

function Server:_recv_exact(n)
  local buf, got = {}, 0
  while got < n do
    local chunk, err, partial = self._conn:receive(n - got)
    if chunk then
      table.insert(buf, chunk)
      got = got + #chunk
    elseif partial and #partial > 0 then
      table.insert(buf, partial)
      got = got + #partial
    elseif err == "timeout" then
    else
      return nil, err or "receive failed"
    end
  end
  return table.concat(buf)
end

function Server:_recv_message_blocking()
  local hdr, err = self:_recv_exact(4)
  if not hdr then return nil, err end
  local len = unpack_u32le(hdr)
  local body, err2 = self:_recv_exact(len)
  if not body then return nil, err2 end
  return body
end

function Server:_send_all_blocking(data)
  local idx = 1
  while idx <= #data do
    local sent, err = self._conn:send(data, idx)
    if sent and sent > 0 then
      idx = idx + sent
    elseif err == "timeout" then
    else
      return nil, err or "send failed"
    end
  end
  return true
end

function Server:_hold_loop()
  local conn = self._conn
  if not conn then return end

  conn:settimeout(0.1)
  while self._holding and self._conn == conn do
    local body, err = self:_recv_message_blocking()
    if not body then self:_reset() return end

    self:_handle(body)

    if self._send_buf ~= "" then
      local ok = self:_send_all_blocking(self._send_buf)
      self._send_buf = ""
      if not ok then self:_reset() return end
    end
  end

  if self._conn then self._conn:settimeout(0) end
end

function Server:run()
  if not self._conn then
    local conn = self._listen:accept()
    if conn then
      conn:settimeout(0)
      self._conn = conn
    end
  end

  local conn = self._conn
  if conn then
    local data, err, partial = conn:receive(4096)
    if data and #data > 0 then
      self._recv_buf = self._recv_buf .. data
    elseif partial and #partial > 0 then
      self._recv_buf = self._recv_buf .. partial
    elseif err == "closed" then
      self:_reset()
      return
    end
  end

  while self._conn do
    if not self._expect_len then
      if #self._recv_buf < 4 then break end
      self._expect_len = unpack_u32le(self._recv_buf:sub(1, 4))
      self._recv_buf = self._recv_buf:sub(5)
    end

    if #self._recv_buf < self._expect_len then break end

    local body = self._recv_buf:sub(1, self._expect_len)
    self._recv_buf = self._recv_buf:sub(self._expect_len + 1)
    self._expect_len = nil

    self:_handle(body)
  end

  self:_flush()
end

local server = Server.new(HOST, PORT)

local function loop()
  server:run()
  reaper.defer(loop)
end

loop()
