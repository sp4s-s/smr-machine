local M = {}

local function decode_error(text, index, message)
  error(string.format("json decode error at %d: %s", index, message .. " near `" .. text:sub(index, index + 20) .. "`"))
end

local function skip_ws(text, index)
  while true do
    local ch = text:sub(index, index)
    if ch == "" then
      return index
    end
    if ch ~= " " and ch ~= "\n" and ch ~= "\r" and ch ~= "\t" then
      return index
    end
    index = index + 1
  end
end

local function decode_string(text, index)
  index = index + 1
  local out = {}
  while true do
    local ch = text:sub(index, index)
    if ch == "" then
      decode_error(text, index, "unterminated string")
    end
    if ch == '"' then
      return table.concat(out), index + 1
    end
    if ch == "\\" then
      local esc = text:sub(index + 1, index + 1)
      if esc == '"' or esc == "\\" or esc == "/" then
        out[#out + 1] = esc
        index = index + 2
      elseif esc == "b" then
        out[#out + 1] = "\b"
        index = index + 2
      elseif esc == "f" then
        out[#out + 1] = "\f"
        index = index + 2
      elseif esc == "n" then
        out[#out + 1] = "\n"
        index = index + 2
      elseif esc == "r" then
        out[#out + 1] = "\r"
        index = index + 2
      elseif esc == "t" then
        out[#out + 1] = "\t"
        index = index + 2
      elseif esc == "u" then
        local hex = text:sub(index + 2, index + 5)
        if #hex ~= 4 or not hex:match("^[0-9a-fA-F]+$") then
          decode_error(text, index, "invalid unicode escape")
        end
        local code = tonumber(hex, 16)
        if code <= 0x7F then
          out[#out + 1] = string.char(code)
        elseif code <= 0x7FF then
          out[#out + 1] = string.char(
            0xC0 + math.floor(code / 0x40),
            0x80 + (code % 0x40)
          )
        else
          out[#out + 1] = string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + (math.floor(code / 0x40) % 0x40),
            0x80 + (code % 0x40)
          )
        end
        index = index + 6
      else
        decode_error(text, index, "invalid string escape")
      end
    else
      out[#out + 1] = ch
      index = index + 1
    end
  end
end

local decode_value

local function decode_array(text, index)
  local result = {}
  index = skip_ws(text, index + 1)
  if text:sub(index, index) == "]" then
    return result, index + 1
  end
  while true do
    local value
    value, index = decode_value(text, index)
    result[#result + 1] = value
    index = skip_ws(text, index)
    local ch = text:sub(index, index)
    if ch == "]" then
      return result, index + 1
    end
    if ch ~= "," then
      decode_error(text, index, "expected `,` or `]`")
    end
    index = skip_ws(text, index + 1)
  end
end

local function decode_object(text, index)
  local result = {}
  index = skip_ws(text, index + 1)
  if text:sub(index, index) == "}" then
    return result, index + 1
  end
  while true do
    if text:sub(index, index) ~= '"' then
      decode_error(text, index, "expected string key")
    end
    local key
    key, index = decode_string(text, index)
    index = skip_ws(text, index)
    if text:sub(index, index) ~= ":" then
      decode_error(text, index, "expected `:`")
    end
    index = skip_ws(text, index + 1)
    result[key], index = decode_value(text, index)
    index = skip_ws(text, index)
    local ch = text:sub(index, index)
    if ch == "}" then
      return result, index + 1
    end
    if ch ~= "," then
      decode_error(text, index, "expected `,` or `}`")
    end
    index = skip_ws(text, index + 1)
  end
end

local function decode_number(text, index)
  local start_pos, finish = text:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", index)
  if not start_pos or not finish then
    decode_error(text, index, "invalid number")
  end
  local token = text:sub(index, finish)
  local value = tonumber(token)
  if value == nil then
    decode_error(text, index, "invalid number")
  end
  return value, finish + 1
end

decode_value = function(text, index)
  index = skip_ws(text, index)
  local ch = text:sub(index, index)
  if ch == '"' then
    return decode_string(text, index)
  end
  if ch == "{" then
    return decode_object(text, index)
  end
  if ch == "[" then
    return decode_array(text, index)
  end
  if ch == "-" or ch:match("%d") then
    return decode_number(text, index)
  end
  if text:sub(index, index + 3) == "true" then
    return true, index + 4
  end
  if text:sub(index, index + 4) == "false" then
    return false, index + 5
  end
  if text:sub(index, index + 3) == "null" then
    return nil, index + 4
  end
  decode_error(text, index, "unexpected token")
end

function M.decode(text)
  local value, index = decode_value(text, 1)
  index = skip_ws(text, index)
  if index <= #text then
    decode_error(text, index, "trailing data")
  end
  return value
end

local function escape_string(value)
  return value
    :gsub("\\", "\\\\")
    :gsub('"', '\\"')
    :gsub("\b", "\\b")
    :gsub("\f", "\\f")
    :gsub("\n", "\\n")
    :gsub("\r", "\\r")
    :gsub("\t", "\\t")
end

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local max_index = 0
  for key, _ in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    if key > max_index then
      max_index = key
    end
  end
  for i = 1, max_index do
    if value[i] == nil then
      return false
    end
  end
  return true
end

local function encode_value(value)
  local kind = type(value)
  if kind == "nil" then
    return "null"
  end
  if kind == "boolean" then
    return value and "true" or "false"
  end
  if kind == "number" then
    return tostring(value)
  end
  if kind == "string" then
    return '"' .. escape_string(value) .. '"'
  end
  if kind ~= "table" then
    error("unsupported json type: " .. kind)
  end
  if is_array(value) then
    local encoded = {}
    for i = 1, #value do
      encoded[i] = encode_value(value[i])
    end
    return "[" .. table.concat(encoded, ",") .. "]"
  end
  local keys = {}
  for key, _ in pairs(value) do
    keys[#keys + 1] = key
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  local encoded = {}
  for _, key in ipairs(keys) do
    encoded[#encoded + 1] = encode_value(tostring(key)) .. ":" .. encode_value(value[key])
  end
  return "{" .. table.concat(encoded, ",") .. "}"
end

function M.encode(value)
  return encode_value(value)
end

return M
