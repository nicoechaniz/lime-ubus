#!/usr/bin/env lua
#!/usr/bin/lua
--[[
lime-ubus

Copyright 2017 Nicolas Echaniz <nicoechaniz@altermundi.net>

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-3.0

]]--



-- deprecated calls
--
-- get_cloud_nodes, replaced by standard ubus call to uci:
-- ubus  call uci get '{"config": "system", "section": "@system[0]", "option": "hostname"}'


require "ubus"
require "uloop"

function lines(str)
    print(str)
    local t = {}
    local function helper(line)
        table.insert(t, line)
        return ""
    end
    helper((str:gsub("(.-)\r?\n", helper)))
    return t
end

local function shell(command)
    -- TODO(nicoechaniz): sanitize or evaluate if this is a security risk
    local handle = io.popen(command)
    local result = handle:read("*a")
    handle:close()
    return result
end

local function _get_loss(host, ip_version)
    local ping_cmd = "ping"
    if ip_version then
        if ip_version == 6 then
            ping_cmd = "ping6"
        end
    end
    local shell_output = shell(ping_cmd.." -q  -i 0.1 -c4 -w2 "..host)
    local loss = "100"
    if shell_output ~= "" then
        loss = shell_output:match("(%d*)%% packet loss")
    end
    return loss
end


uloop.init()

local conn = ubus.connect()
if not conn then
    error("Failed to connect to ubus")
end

local function get_cloud_nodes(req, msg)
    local local_net = conn:call("uci", "get", {config="network", section="lm_net_anygw_route4", option="target" }).value
    local nodes = lines(shell("bmx6 -cd8 | grep ".. local_net .." | awk '{ print $10 }'"))
    local result = {}
    result.nodes = {}
    for _, line in ipairs(nodes) do --nodes:gmatch("[^\n]*") do
        if line ~= "" then
            table.insert(result.nodes, line)
        end
    end
    conn:reply(req, result);
end

local function get_location(req, msg)
    local result = {}
    local lat = conn:call("uci", "get", {config="libremap", section="location", option="latitude" }).value
    local lon = conn:call("uci", "get", {config="libremap", section="location", option="longitude" }).value

    if (type(tonumber(lat)) == "number" and type(tonumber(lon)) == "number") then
        result.lat = lat
        result.lon = lon
    else
        result.lat = conn:call("uci", "get", {config="libremap", section="@libremap[0]",
                                              option="community_lat" }).value
        result.lon = conn:call("uci", "get", {config="libremap", section="@libremap[0]",
                                              option="community_lon" }).value
    end
    conn:reply(req, result);
end

local function get_metrics(req, msg)
    conn:reply(req, {status="processing"})
    local def_req = conn:defer_request(req)
    uloop.timer(function()
            local result = {}
            local node = msg.target
            local loss = _get_loss(node..".mesh", 6)
            local bw = 0
            if loss ~= "100" then
                local command = "netperf -l 6 -H "..node..".mesh -t tcp_maerts| tail -n1| awk '{ print $5 }'"
                local shell_output = shell(command)
                if shell_output ~= "" then
                    bw = shell_output:match("[%d.]+")
                end
            end
            result.loss = loss
            result.bandwidth = bw

            conn:reply(def_req, result)
            conn:complete_deferred_request(def_req, 0)
            print("Deferred request complete")
                end, 500)
    print("Call to function 'deferred'")
end


local lime_api = {
    lime = {
        get_cloud_nodes = { get_cloud_nodes, {} },
        get_location = { get_location, {} },
        get_metrics = { get_metrics, { msg=ubus.STRING } },
    }
}

conn:add(lime_api)

local my_event = {
    test = function(msg)
        print("Call to test event")
        for k, v in pairs(msg) do
            print("key=" .. k .. " value=" .. tostring(v))
        end
    end,
}

conn:listen(my_event)

uloop.run()
