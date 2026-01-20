# ReaScript Socket Example

A personal, minimal reapy-like implementation for calling raw ReaScript API via TCP.

## Compatibility

Tested on Windows and Linux. macOS has not been tested; macOS users may need to modify the scripts for correct execution.

## Testing Scripts

Run benchmarks to measure performance:

```bash
# Python client
python python_example/api_run.py

# Lua client
lua lua_example/api_run.lua

# Python calling Lua ReaScript API
python lua_example/api_run_to_lua.py
```

Each script performs:
- Add 100 markers → remove 100 markers (HOLD mode)
- Add 100 markers → remove 100 markers (NOHOLD mode)
- Reports elapsed time for each operation

 JSON implementation is provided by [rxi/json.lua](https://github.com/rxi/json.lua).

## LuaSocket Installation

Lua server requires LuaSocket. Easiest way: install via [DanielLumertz-Scripts](https://github.com/daniellumertz/DanielLumertz-Scripts) ReaPack repository.

This project uses the standard socket path from that package.

### Lua Client Socket Configuration

The Lua client (`lua_example/api_client.lua`) uses a hardcoded path to load LuaSocket:
- Default location: `$HOME/.config/REAPER/Scripts/Daniel Lumertz Scripts/LUA Sockets/socket module`
- If your LuaSocket is installed elsewhere, modify the `load_luasocket()` function in `api_client.lua`
- You can also use other socket loading methods by updating the function accordingly

## References

https://forums.cockos.com/showthread.php?t=265912
https://forum.cockos.com/showthread.php?p=2551512
https://github.com/daniellumertz/DanielLumertz-Scripts
https://github.com/RomeoDespres/reapy
https://github.com/rxi/json.lua

