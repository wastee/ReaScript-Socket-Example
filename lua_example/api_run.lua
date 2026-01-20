local script_dir = debug.getinfo(1, "S").source:match("@(.*[/\\])") or "./"
script_dir = script_dir:gsub("\\", "/"):gsub("/+$", "")
package.path = package.path .. ";" .. script_dir .. "/?.lua;" .. script_dir .. "/?/init.lua"

local api = require("api_client")
local socket = api.socket

api.enable_global_proxies()

local function now()
  if socket.gettime then
    return socket.gettime()
  end
  return os.clock()
end

local function timer(label, fn)
  local t0 = now()
  fn()
  local elapsed = now() - t0
  io.write(string.format("%s_elapsed_seconds: %.6f\n", label, elapsed))
end

local function main()
  local n = 100

  api.client:connect()

  timer("hold", function()
    local markers = {}
    api.hold(function()
      for i = 0, n - 1 do
        local idx = AddProjectMarker(0, 0, i, 0, "hold" .. tostring(i + 1), i + 1)
        markers[#markers + 1] = idx
      end

      for _, idx in ipairs(markers) do
        DeleteProjectMarker(0, idx, 0)
      end
    end)
  end)

  timer("no_hold", function()
    local markers = {}
    for i = 0, n - 1 do
      local idx = AddProjectMarker(0, 0, i + 0.5, 0, "nohold" .. tostring(i + 1), i + 1)
      markers[#markers + 1] = idx
    end

    for _, idx in ipairs(markers) do
      DeleteProjectMarker(0, idx, 0)
    end
  end)

  api.client:close()
end

main()
