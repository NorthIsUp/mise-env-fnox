local cmd = require("cmd")
local json = require("json")

-- Resolve a usable fnox path when mise's `tools = true` PATH injection
-- doesn't reach the lua subprocess (a bug in mise 2026.4.6+).
local function resolve_fnox_bin(fnox_bin)
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    local candidates = {
        fnox_bin,
        home .. "/.local/share/mise/installs/fnox/latest/fnox",
        home .. "/.local/share/mise/shims/fnox",
    }
    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            return path
        end
    end
    return fnox_bin
end

local function strip_traceback(msg)
    if not msg then return "" end
    return (tostring(msg):gsub("\r?\n%s*stack traceback:.*$", ""))
end

local function shquote(s)
    return "'" .. tostring(s):gsub("'", [['\'']]) .. "'"
end

-- Detect a `timeout` binary once per activation. Returns the binary name
-- or nil if none is on PATH.
local _timeout_bin_cached = nil
local _timeout_bin_done = false
local function timeout_bin()
    if _timeout_bin_done then return _timeout_bin_cached end
    _timeout_bin_done = true
    for _, b in ipairs({"timeout", "gtimeout"}) do
        local f = io.popen("command -v " .. b .. " 2>/dev/null")
        if f then
            local out = f:read("*a") or ""
            f:close()
            if out:match("%S") then
                _timeout_bin_cached = b
                return b
            end
        end
    end
    return nil
end

-- Build a shell command string that:
--   1. Prepends fnox's parent dir to PATH (without replacing the rest of env)
--   2. Wraps in `timeout` if available so a stalled network call can't hang
--      mise activation indefinitely.
local function build_command(fnox_bin, args, timeout_secs)
    local fnox_dir = fnox_bin:match("(.+)/[^/]+$")
    local prefix = ""
    if fnox_dir then
        prefix = "PATH=" .. shquote(fnox_dir) .. ':"$PATH" '
    end
    local body = shquote(fnox_bin) .. " " .. args
    local tbin = timeout_bin()
    if tbin and timeout_secs then
        body = tbin .. " --preserve-status " .. timeout_secs .. " " .. body
    end
    return prefix .. body
end

local function exec(command)
    local ok, output = pcall(function()
        return cmd.exec(command)
    end)
    return ok, output
end

local function run_json(command)
    local ok, output = exec(command)
    if not ok then
        error("[fnox] `" .. command .. "` failed: " .. tostring(output))
    end
    if not output or output == "" then
        return {}
    end
    local decode_ok, data = pcall(json.decode, output)
    if not decode_ok then
        error("[fnox] failed to parse JSON from `" .. command .. "`: " .. tostring(data))
    end
    return data
end

local function get_config_files(fnox_bin)
    local command = build_command(fnox_bin, "config-files", 5)
    local ok, output = exec(command)
    if not ok then
        print("[fnox] warning: `" .. command .. "` failed: " .. strip_traceback(output))
        return nil
    end
    if not output or output == "" then
        return {}
    end
    local files = {}
    for line in output:gmatch("[^\n]+") do
        table.insert(files, line)
    end
    return files
end

-- TOML section headers must start at column 0. Anchor the pattern so
-- `[leases.x]` inside a comment or multi-line string can't false-positive.
local function has_lease_backends(config_files)
    for _, path in ipairs(config_files) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and (content:match("\n%s*%[leases%.")
                         or content:match("^%s*%[leases%.")
                         or content:match("\n%s*%[%[leases")
                         or content:match("^%s*%[%[leases")) then
                return true
            end
        end
    end
    return false
end

function PLUGIN:MiseEnv(ctx)
    local fnox_bin = resolve_fnox_bin(ctx.options.fnox_bin or "fnox")
    local profile = ctx.options.profile
    local export_timeout = tonumber(ctx.options.export_timeout) or 15
    local lease_timeout = tonumber(ctx.options.lease_timeout) or 30

    local config_files = get_config_files(fnox_bin)
    if not config_files then
        -- config-files failed; return a non-cacheable empty result so mise
        -- proceeds and retries on the next activation
        return {cacheable = false, watch_files = {}, env = {}}
    end
    if #config_files == 0 then
        return {cacheable = true, watch_files = {}, env = {}}
    end

    local profile_args = ""
    if profile then
        profile_args = " --profile " .. shquote(profile)
    end

    local env_vars = {}
    local seen = {}
    local had_failure = false

    -- export secrets: failures are surfaced as warnings, not errors, so a
    -- broken fnox invocation never blocks mise from progressing
    local export_cmd = build_command(fnox_bin, "export --format json" .. profile_args, export_timeout)
    local eok, edata = pcall(run_json, export_cmd)
    if eok then
        for key, value in pairs(edata.secrets or {}) do
            if not seen[key] then
                seen[key] = true
                table.insert(env_vars, {key = key, value = value})
            end
        end
    else
        had_failure = true
        print("[fnox] warning: export failed, continuing without secrets: " .. strip_traceback(edata))
    end

    -- create leases (only if any backends are configured); same policy as
    -- export -- warn on failure, never block mise
    if has_lease_backends(config_files) then
        local lease_cmd = build_command(fnox_bin, "lease create --all --format json" .. profile_args, lease_timeout)
        local lok, ldata = pcall(run_json, lease_cmd)
        if lok then
            for key, value in pairs(ldata) do
                if key ~= "backend" and key ~= "lease_id" and type(value) == "string" then
                    if seen[key] then
                        print("[fnox] warning: lease credential `" .. key .. "` overrides exported secret")
                        for i, entry in ipairs(env_vars) do
                            if entry.key == key then
                                env_vars[i] = {key = key, value = value}
                                break
                            end
                        end
                    else
                        seen[key] = true
                        table.insert(env_vars, {key = key, value = value})
                    end
                end
            end
        else
            had_failure = true
            print("[fnox] warning: lease creation failed, continuing without lease credentials: " .. strip_traceback(ldata))
        end
    end

    return {
        -- don't cache partial results so mise retries after a transient failure
        cacheable = not had_failure,
        watch_files = config_files,
        env = env_vars,
        redact = true
    }
end
