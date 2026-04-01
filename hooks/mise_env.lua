local cmd = require("cmd")
local json = require("json")

local function get_config_files(fnox_bin)
    local ok, output = pcall(function()
        return cmd.exec(fnox_bin .. " config-files")
    end)
    if not ok then
        print("[fnox] warning: `" .. fnox_bin .. " config-files` failed: " .. tostring(output))
        return {}
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

function PLUGIN:MiseEnv(ctx)
    local fnox_bin = ctx.options.fnox_bin or "fnox"
    local profile = ctx.options.profile

    local config_files = get_config_files(fnox_bin)
    if #config_files == 0 then
        return {cacheable = true, watch_files = {}, env = {}}
    end

    local profile_flag = ""
    if profile then
        profile_flag = " --profile " .. profile
    end

    local env_vars = {}

    -- export secrets
    local export_cmd = fnox_bin .. " export --format json" .. profile_flag
    local ok, output = pcall(function()
        return cmd.exec(export_cmd)
    end)
    if ok then
        local decode_ok, data = pcall(json.decode, output)
        if decode_ok then
            for key, value in pairs(data.secrets or {}) do
                table.insert(env_vars, {key = key, value = value})
            end
        else
            print("[fnox] warning: failed to parse JSON from `" .. export_cmd .. "`: " .. tostring(data))
        end
    else
        print("[fnox] warning: `" .. export_cmd .. "` failed: " .. tostring(output))
    end

    -- create leases and merge credentials
    local lease_cmd = fnox_bin .. " lease create --all --format json" .. profile_flag
    local lok, loutput = pcall(function()
        return cmd.exec(lease_cmd)
    end)
    if lok then
        local ldecode_ok, ldata = pcall(json.decode, loutput)
        if ldecode_ok then
            for key, value in pairs(ldata) do
                if key ~= "backend" and key ~= "lease_id" and type(value) == "string" then
                    table.insert(env_vars, {key = key, value = value})
                end
            end
        else
            print("[fnox] warning: failed to parse JSON from `" .. lease_cmd .. "`: " .. tostring(ldata))
        end
    end

    return {
        cacheable = true,
        watch_files = config_files,
        env = env_vars,
        redact = true
    }
end
