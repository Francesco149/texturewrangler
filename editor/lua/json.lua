-- json.lua — minimal JSON encode/decode for the project document format.
-- Hand-rolled on purpose: tiny, deterministic, no deps, full control.
-- Encodes: nil (as null inside tables, omitted keys skipped by caller),
-- booleans, numbers, strings, tables (arrays vs objects by keys), nested.
-- Decodes: standard JSON into lua values; errors raise with a message.

local json = {}

local function is_array(t)
  local n = 0
  for k in pairs(t) do
    if type(k) ~= "number" or k < 1 or k % 1 ~= 0 then return false end
    if k > n then n = k end
  end
  return n > 0 -- 0 is truthy in Lua; empty tables are objects
end

local esc = {
  ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
  ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function encode_string(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c)
    return esc[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function encode(v, seen)
  local t = type(v)
  if t == "nil" then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    return string.format("%.14g", v)
  elseif t == "string" then return encode_string(v)
  elseif t == "table" then
    if seen[v] then error("json: circular reference") end
    seen[v] = true
    local parts, out = {}, {}
    if is_array(v) then
      for i = 1, #v do
        parts[#parts + 1] = encode(v[i], seen) or "null"
      end
      out[#out + 1] = "[" .. table.concat(parts, ",") .. "]"
    else
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        local ev = encode(v[k], seen)
        if ev ~= "null" or v[k] ~= nil then -- keep explicit nulls out
          parts[#parts + 1] = encode_string(tostring(k)) .. ":" .. ev
        end
      end
      out[#out + 1] = "{" .. table.concat(parts, ",") .. "}"
    end
    seen[v] = nil
    return table.concat(out)
  end
  error("json: cannot encode " .. t)
end

function json.encode(v)
  return encode(v, {})
end

-- ── decoder ─────────────────────────────────────────────────────────────────

local function decode_error(pos, msg)
  error(string.format("json: %s at offset %d", msg, pos), 0)
end

local function skip_ws(s, i)
  local c
  repeat
    c = s:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else break end
  until i > #s
  return i
end

local function decode_value(s, i)
  i = skip_ws(s, i)
  local c = s:sub(i, i)
  if c == "{" then
    local t, key = {}, nil
    i = i + 1
    while true do
      i = skip_ws(s, i)
      c = s:sub(i, i)
      if c == "}" then return t, i + 1 end
      if c ~= '"' then decode_error(i, "expected key string") end
      local ks, ke = s:find('"(.-)"', i)
      if not ks then decode_error(i, "bad key") end
      key = ke == i + #s and "" or s:sub(i + 1, ke - 1)
      local colon = skip_ws(s, ke + 1)
      if s:sub(colon, colon) ~= ":" then decode_error(colon, "expected ':'") end
      local v, ni = decode_value(s, colon + 1)
      t[key] = v
      i = skip_ws(s, ni)
      c = s:sub(i, i)
      if c == "," then i = i + 1
      elseif c == "}" then return t, i + 1
      else decode_error(i, "expected ',' or '}'") end
    end
  elseif c == "[" then
    local t = {}
    i = i + 1
    while true do
      i = skip_ws(s, i)
      c = s:sub(i, i)
      if c == "]" then return t, i + 1 end
      local v, ni = decode_value(s, i)
      t[#t + 1] = v
      i = skip_ws(s, ni)
      c = s:sub(i, i)
      if c == "," then i = i + 1
      elseif c == "]" then return t, i + 1
      else decode_error(i, "expected ',' or ']'") end
    end
  elseif c == '"' then
    local out = {}
    local j = i + 1
    while true do
      local ch = s:sub(j, j)
      if ch == '"' then
        return table.concat(out), j + 1
      elseif ch == "\\" then
        local e = s:sub(j + 1, j + 1)
        if e == "n" then out[#out + 1] = "\n"
        elseif e == "t" then out[#out + 1] = "\t"
        elseif e == "r" then out[#out + 1] = "\r"
        elseif e == "b" then out[#out + 1] = "\b"
        elseif e == "f" then out[#out + 1] = "\f"
        elseif e == "/" then out[#out + 1] = "/"
        elseif e == "u" then
          local hex = s:sub(j + 2, j + 5)
          out[#out + 1] = string.char(tonumber(hex, 16) or 63)
          j = j + 4
        else out[#out + 1] = e end
        j = j + 2
      elseif ch == "" then
        decode_error(j, "unterminated string")
      else
        out[#out + 1] = ch
        j = j + 1
      end
    end
  elseif c == "t" and s:sub(i, i + 3) == "true" then return true, i + 4
  elseif c == "f" and s:sub(i, i + 4) == "false" then return false, i + 5
  elseif c == "n" and s:sub(i, i + 3) == "null" then return nil, i + 4
  else
    local num = s:match("^-?%d+%.?%d*[eE]?[+-]?%d*", i)
    if num and #num > 0 then
      local v = tonumber(num)
      if v then return v, i + #num end
    end
    decode_error(i, "unexpected character '" .. c .. "'")
  end
end

function json.decode(s)
  if type(s) ~= "string" then error("json: decode expects string", 0) end
  local v = decode_value(s, 1)
  return v
end

return json
