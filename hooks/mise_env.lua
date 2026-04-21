local cmd = require("cmd")
local json = require("json")

local function resolve_fnox_bin(fnox_bin)
    local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
    -- Prefer the shim (which respects mise's version resolution, honoring
    -- project-level pins) over `installs/latest` (managed by mise's default
    -- alias — wrong when the user has pinned to a non-latest version).
    local candidates = {
        fnox_bin,
        home .. "/.local/share/mise/shims/fnox",
        home .. "/.local/share/mise/installs/fnox/latest/fnox",
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

local function exec(command, opts)
    local ok, output = pcall(function()
        return cmd.exec(command, opts)
    end)
    return ok, output
end

local function run_json(command, opts)
    local ok, output = exec(command, opts)
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

local function get_config_files(fnox_bin, opts)
    local command = fnox_bin .. " config-files"
    local ok, output = exec(command, opts)
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

local function has_lease_backends(config_files)
    for _, path in ipairs(config_files) do
        local f = io.open(path, "r")
        if f then
            local content = f:read("*a")
            f:close()
            if content and (content:match("%[leases%.") or content:match("%[%[leases")) then
                return true
            end
        end
    end
    return false
end

function PLUGIN:MiseEnv(ctx)
    local fnox_bin = resolve_fnox_bin(ctx.options.fnox_bin or "fnox")
    local profile = ctx.options.profile

    -- ensure fnox's parent dir is on PATH for subprocesses
    local fnox_dir = fnox_bin:match("(.+)/[^/]+$")
    local exec_opts = {}
    if fnox_dir then
        local path = os.getenv("PATH") or ""
        exec_opts = {env = {PATH = fnox_dir .. ":" .. path}}
    end

    local config_files = get_config_files(fnox_bin, exec_opts)
    if not config_files then
        -- config-files failed; return a non-cacheable empty result so mise
        -- proceeds and retries on the next activation
        return {cacheable = false, watch_files = {}, env = {}}
    end
    if #config_files == 0 then
        return {cacheable = true, watch_files = {}, env = {}}
    end

    local profile_flag = ""
    if profile then
        profile_flag = " --profile " .. profile
    end

    local env_vars = {}
    local had_failure = false

    -- export secrets: failures are surfaced as warnings, not errors, so a
    -- broken fnox invocation never blocks mise from progressing
    local export_cmd = fnox_bin .. " export --format json" .. profile_flag
    local eok, edata = pcall(run_json, export_cmd, exec_opts)
    if eok then
        for key, value in pairs(edata.secrets or {}) do
            table.insert(env_vars, {key = key, value = value})
        end
    else
        had_failure = true
        print("[fnox] warning: export failed, continuing without secrets: " .. strip_traceback(edata))
    end

    -- create leases (only if any backends are configured); same policy as
    -- export — warn on failure, never block mise
    if has_lease_backends(config_files) then
        local lease_cmd = fnox_bin .. " lease create --all --format json" .. profile_flag
        local lok, ldata = pcall(run_json, lease_cmd, exec_opts)
        if lok then
            for key, value in pairs(ldata) do
                if key ~= "backend" and key ~= "lease_id" and type(value) == "string" then
                    table.insert(env_vars, {key = key, value = value})
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
