--
-- Licensed to the Apache Software Foundation (ASF) under one or more
-- contributor license agreements.  See the NOTICE file distributed with
-- this work for additional information regarding copyright ownership.
-- The ASF licenses this file to You under the Apache License, Version 2.0
-- (the "License"); you may not use this file except in compliance with
-- the License.  You may obtain a copy of the License at
--
--     http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing, software
-- distributed under the License is distributed on an "AS IS" BASIS,
-- WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
-- See the License for the specific language governing permissions and
-- limitations under the License.
--
local core     = require("apisix.core")
local string_format = string.format
local ngx_worker_id = ngx.worker.id
local redis = require ("redis")
local ngx      = ngx
local plugin_name = "apple-healthcheck"
local schema_def = require("apisix.schema_def")
local cjson = require("cjson.safe").new()

-- serialize a table to a string
local serialize = cjson.encode

-- deserialize a string to a table
local deserialize = cjson.decode

local schema = {
    type = "object",
    properties = {
        healthcheck_bypass = {type = "boolean", default = false},
        bypass_suffix = {type = "string", enum = {"smp", "smp-dr", "public"},},
        endpoint = {
            type = "array",items = {type = "string"}},
        upstream = {
            nodes = schema_def.upstream.properties.nodes,
            cert = {
                type = "string", minLength = 128, maxLength = 64*1024
            },
            key =  {
                type = "string", minLength = 128, maxLength = 64*1024
            }
        },
        check = {
            https_verify_certificate = {type = "boolean", default = false},
            interval = {type = "integer", minimum = 1, default = 10},
            timeout = {type = "number", default = 5},
            http_successes = {
                type = "integer",
                minimum = 1,
                maximum = 254,
                default = 3
            },
            http_failures = {
                type = "integer",
                minimum = 1,
                maximum = 254,
                default = 3
            }
        }      
    },
    required = {"endpoint"},
}


local consumer_schema = {
    type = "object",
    -- can't use additionalProperties with dependencies
    properties = {},
    
}


local _M = {
    version = 0.1,
    priority = 99,
    name = plugin_name,
    schema = schema
}

-- constants
local SHM_PREFIX = "apple-healthcheck"
local shm = ngx.shared["apple-healthcheck"]
local TARGET_STATE     = SHM_PREFIX ..  ":state"
local TARGET_COUNTER   = SHM_PREFIX ..  ":counter:"
local TARGET_LIST      = SHM_PREFIX ..  ":target_list"
local redis_prefix = "apple:user_identifier:"
local opts = {
    ip = "192.168.56.103",
    port = 6379,
    passwd = "123456",
    db = 0,
    timeout = 1000,
    poolsize = 100,
    freetime = 30000
}
local suffix_location = {["dr"]= ".dr", ["smp-dr"] =".smp-dr", ["public"]=""}
local suffix_apple = ".apple.com"

local active_check_timer
local last_check_ver = 0


local function fetch_target_list()
    local target_list, err = shm:get(TARGET_LIST)
    if err then
      return {}, "failed to fetch target_list from shm: " .. err
    end
  
    return target_list and deserialize(target_list) or {}
end
_M.fetch_target_list = fetch_target_list


local function add_target_node(domain)
    local target_list = fetch_target_list()

    if not target_list[domain] then
        target_list[domain] = true
        target_list = serialize(target_list)
        local success, err, forcible = shm:set(TARGET_LIST, target_list)
        if not success or forcible then
            core.log.warn("dict no memory: ", err)
        end
    end
end
_M.add_target_node = add_target_node


local function clear_target_nodes()
    local target_list = {}
    target_list = serialize(target_list)
    local success, err, forcible = shm:set(TARGET_LIST, target_list)
    if not success or forcible then
        core.log.warn("dict no memory: ", err)
    end
    core.log.error("clear_target_nodes")

    return success
end


function _M.check_schema(conf, schema_type)
    core.log.warn("input conf: ", core.json.delay_encode(conf))

    if not shm then
        core.log.error("need apple-healthcheck shared dict")
        return false, "need apple-healthcheck shared dict"
    end

    local ok, err
    if schema_type == core.schema.TYPE_CONSUMER then
        ok, err = core.schema.check(consumer_schema, conf)
    else
        ok, err = core.schema.check(schema, conf)
    end

    if not ok then
        return false, err
    end

    if ngx_worker_id() == 0 then
        clear_target_nodes()
        if not conf._meta or not conf._meta.disable then
            local endpoint = conf.endpoint or {}
            if ok and conf.endpoint and #endpoint > 0 then
                for _, domain in ipairs(endpoint) do
                    add_target_node(domain)
                    core.log.info("add_target_node: ", domain)
                end
            end
        end
    end

    return true
end

local function key_for(key_prefix, hostname, health_type)
    return string_format("%s:%s%s", key_prefix, hostname or "",health_type and ":" .. health_type or "")
end

local function get_val_from_redis(domain, header_type)
    local red = redis:new(opts)
    if not red then
        core.log.warn("new redis err")
        return nil
    end
    local exp = red:hget(redis_prefix .. domain , header_type)
    core.log.info("redis key: ", redis_prefix .. domain, " ",header_type)

    red:set_keepalive(opts.freetime, opts.poolsize)
    if exp == ngx.null or exp == nil then return nil end
    return exp
end


local function set_val_to_redis(domain, ...)
    -- core.log.error("prefix: ", prefix)
    local red = redis:new(opts)
    if not red then
        core.log.error("new redis err")
        return false, "new redis err"
    end
    local res, err = red:hset(redis_prefix .. domain, ...)
    if not res then
        core.log.error("failed to set hset: ", err)
        return false, "failed to set hset: " .. err
    end
    core.log.warn("redis key: ", redis_prefix .. domain,...)
    red:set_keepalive(opts.freetime, opts.poolsize)
    return true
end
_M.set_val_to_redis = set_val_to_redis






local function report_http_status(domain, status, limit)
    local state_key = key_for(TARGET_STATE, domain)
    local old_status, flags = shm:get(state_key)
    if not old_status then
        local _, err = shm:safe_set(state_key, status or "healthy")
        if err then
            core.log.warn("dict set err: ", err)
        end
        if status == "healthy" then
            return
        end
        old_status = "healthy" -- 状态默认值
    end

    local counter_key = key_for(TARGET_COUNTER, domain)

    if old_status == status then
        
        if status == "healthy" then
            local _, err = shm:safe_set(counter_key, 0)  -- 重置失败计数器
            if err then
                core.log.warn("dict set err: ", err)
            end
            core.log.debug(domain, "重置失败次数计数器")
        end

        return nil
    end


    if old_status ~= status then
        local status_change = false

        if status == "healthy" then
            status_change = true
        else
            local multictr, err = shm:incr(counter_key, 1, 0)
            core.log.warn(domain," fali counter: ", multictr)
            if err then
                core.log.warn("COUNTER err: ",err)
                return nil
            end
            if multictr and multictr > 2 then
                status_change = true
            end
        end

        if status_change then
            shm:safe_set(counter_key, 0)  -- 重置失败次数计数器
            shm:safe_set(state_key, status)
            last_check_ver = last_check_ver + 1
            core.log.warn(state_key," status change: ", status)
        end
        return status_change
    end

 

end

local cert = [[-----BEGIN CERTIFICATE-----
MIIDUzCCAjugAwIBAgIURw+Rc5FSNUQWdJD+quORtr9KaE8wDQYJKoZIhvcNAQEN
BQAwWDELMAkGA1UEBhMCY24xEjAQBgNVBAgMCUd1YW5nRG9uZzEPMA0GA1UEBwwG
Wmh1SGFpMRYwFAYDVQQDDA1jYS5hcGlzaXguZGV2MQwwCgYDVQQLDANvcHMwHhcN
MjIxMjAxMTAxOTU3WhcNNDIwODE4MTAxOTU3WjBOMQswCQYDVQQGEwJjbjESMBAG
A1UECAwJR3VhbmdEb25nMQ8wDQYDVQQHDAZaaHVIYWkxGjAYBgNVBAMMEWNsaWVu
dC5hcGlzaXguZGV2MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAzypq
krsJ8MaqpS0kr2SboE9aRKOJzd6mY3AZLq3tFpio5cK5oIHkQLfeaaLcd4ycFcZw
FTpxc+Eth6I0X9on+j4tEibc5IpDnRSAQlzHZzlrOG6WxcOza4VmfcrKqj27oodr
oqXv05r/5yIoRrEN9ZXfA8n2OnjhkP+C3Q68L6dBtPpv+e6HaAuw8MvcsEo+MQwu
cTZyWqWT2UzKVzToW29dHRW+yZGuYNWRh15X09VSvx+E0s+uYKzN0Cyef2C6VtBJ
KmJ3NtypAiPqw7Ebfov2Ym/zzU9pyWPi3P1mYPMKQqUT/FpZSXm4iSy0a5qTYhkF
rFdV1YuYYZL5YGl9aQIDAQABox8wHTAbBgNVHREEFDASghBhZG1pbi5hcGlzaXgu
ZGV2MA0GCSqGSIb3DQEBDQUAA4IBAQBepRpwWdckZ6QdL5EuufYwU7p5SIqkVL/+
N4/l5YSjPoAZf/M6XkZu/PsLI9/kPZN/PX4oxjZSDH14dU9ON3JjxtSrebizcT8V
aQ13TeW9KSv/i5oT6qBmj+V+RF2YCUhyzXdYokOfsSVtSlA1qMdm+cv0vkjYcImV
l3L9nVHRPq15dY9sbmWEtFBWvOzqNSuQYax+iYG+XEuL9SPaYlwKRC6eS/dbXa1T
PPWDQad2X/WmhxPzEHvjSl2bsZF1u0GEdKyhXWMOLCLiYIJo15G7bMz8cTUvkDN3
6WaWBd6bd2g13Ho/OOceARpkR/ND8PU78Y8cq+zHoOSqH+1aly5H
-----END CERTIFICATE-----
]]

local key =[[-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAzypqkrsJ8MaqpS0kr2SboE9aRKOJzd6mY3AZLq3tFpio5cK5
oIHkQLfeaaLcd4ycFcZwFTpxc+Eth6I0X9on+j4tEibc5IpDnRSAQlzHZzlrOG6W
xcOza4VmfcrKqj27oodroqXv05r/5yIoRrEN9ZXfA8n2OnjhkP+C3Q68L6dBtPpv
+e6HaAuw8MvcsEo+MQwucTZyWqWT2UzKVzToW29dHRW+yZGuYNWRh15X09VSvx+E
0s+uYKzN0Cyef2C6VtBJKmJ3NtypAiPqw7Ebfov2Ym/zzU9pyWPi3P1mYPMKQqUT
/FpZSXm4iSy0a5qTYhkFrFdV1YuYYZL5YGl9aQIDAQABAoIBAD7tUG//lnZnsj/4
JXONaORaFj5ROrOpFPuRemS+egzqFCuuaXpC2lV6RHnr+XHq6SKII1WfagTb+lt/
vs760jfmGQSxf1mAUidtqcP+sKc/Pr1mgi/SUTawz8AYEFWD6PHmlqBSLTYml+La
ckd+0pGtk49wEnYSb9n+cv640hra9AYpm9LXUFaypiFEu+xJhtyKKWkmiVGrt/X9
3aG6MuYeZplW8Xq1L6jcHsieTOB3T+UBfG3O0bELBgTVexOQYI9O4Ejl9/n5/8WP
AbIw7PaAYc7fBkwOGh7/qYUdHnrm5o9MiRT6dPxrVSf0PZVACmA+JoNjCPv0Typf
3MMkHoECgYEA9+3LYzdP8j9iv1fP5hn5K6XZAobCD1mnzv3my0KmoSMC26XuS71f
vyBhjL7zMxGEComvVTF9SaNMfMYTU4CwOJQxLAuT69PEzW6oVEeBoscE5hwhjj6o
/lr5jMbt807J9HnldSpwllfj7JeiTuqRcCu/cwqKQQ1aB3YBZ7h5pZkCgYEA1ejo
KrR1hN2FMhp4pj0nZ5+Ry2lyIVbN4kIcoteaPhyQ0AQ0zNoi27EBRnleRwVDYECi
XAFrgJU+laKsg1iPjvinHibrB9G2p1uv3BEh6lPl9wPFlENTOjPkqjR6eVVZGP8e
VzxYxIo2x/QLDUeOpxySdG4pdhEHGfvmdGmr2FECgYBeknedzhCR4HnjcTSdmlTA
wI+p9gt6XYG0ZIewCymSl89UR9RBUeh++HQdgw0z8r+CYYjfH3SiLUdU5R2kIZeW
zXiAS55OO8Z7cnWFSI17sRz+RcbLAr3l4IAGoi9MO0awGftcGSc/QiFwM1s3bSSz
PAzYbjHUpKot5Gae0PCeKQKBgQCHfkfRBQ2LY2WDHxFc+0+Ca6jF17zbMUioEIhi
/X5N6XowyPlI6MM7tRrBsQ7unX7X8Rjmfl/ByschsTDk4avNO+NfTfeBtGymBYWX
N6Lr8sivdkwoZZzKOSSWSzdos48ELlThnO/9Ti706Lg3aSQK5iY+aakJiC+fXdfT
1TtsgQKBgQDRYvtK/Cpaq0W6wO3I4R75lHGa7zjEr4HA0Kk/FlwS0YveuTh5xqBj
wQz2YyuQQfJfJs7kbWOITBT3vuBJ8F+pktL2Xq5p7/ooIXOGS8Ib4/JAS1C/wb+t
uJHGva12bZ4uizxdL2Q0/n9ziYTiMc/MMh/56o4Je8RMdOMT5lTsRQ==
-----END RSA PRIVATE KEY-----
]]


local function create_timer()

        local http = require "resty.http"
        return ngx.timer.every(10,function (premature)
            if premature then
                return
            end
            core.log.warn("apple-healthcheck timer strat")
            local target_list = fetch_target_list()

            if not target_list then
                core.log.info("apple-healthcheck target_list nil")
                return
            end
            for upstream, _ in pairs(target_list) do
                local httpc = http.new()
                httpc:set_timeout(5000)
                local ok, err = httpc:connect({
                    scheme = "https",
                    host = upstream,
                    port = 9443,
                    ssl_verify = false,
                    ssl_cert = cert,
                    ssl_key = key
                    
                })
                if not ok then
                    core.log.warn("apple-healthcheck error: ",err)
                    report_http_status(upstream, "unhealthy")
                    goto continue
                end
            
                do
                    local res, err = httpc:request{
                        path = "/headers",
                        headers = {
                            ["Host"] =upstream,
                            ["Connection"] = "close"
                        },
                    }
                    if not res then
                        core.log.warn("apple-healthcheck request error: ",err)
                        report_http_status(upstream, "unhealthy")
                        goto continue
                    elseif res and res.status == 200 then
                        report_http_status(upstream, "healthy")
                    else
                        report_http_status(upstream, "unhealthy")
                    end
      
                    core.log.warn(upstream .. " status: ",res.status)
                end
  
                ::continue::
                httpc:close()
            end
    
        end)
end

function _M.access(conf, ctx)


    if not shm then
        core.log.error("need apple-healthcheck shared dict")
        return
    end

    local user_identifier = core.request.header(ctx, "x-user-identifier")
    if not user_identifier then
        return 400, "required x-user-identifier header"
    end

    local region = get_val_from_redis(user_identifier,"region") 
    local pod = get_val_from_redis(user_identifier,"pod")
    
    if not region and not pod then
        return 400, "identifier缺少关联的region and pod"
    end

    local prefix_without_smp = "cn-apple-pay-gateway-" .. region .. "-" .. pod
    local prefix_with_smp = prefix_without_smp .. "-smp"
    local prefix_with_dr = prefix_with_smp .. "-dr"

    local upstreams = {}

    local upstream
    local found = false

    if not conf.healthcheck_bypass then
        upstreams = {
            prefix_with_smp .. suffix_apple,
            prefix_with_dr .. suffix_apple,
            prefix_without_smp .. suffix_apple
        }
    end


    for _, domain in ipairs(upstreams) do
    
        local state_key = key_for(TARGET_STATE, domain)
        local value, _ = shm:get(state_key)
        core.log.info(state_key, ": ", value)

        if not value then
            local success, err, forcible = shm:set(state_key,"healthy")
            if not success or forcible then
                core.log.warn("dict no memory: ", err)
            end

        elseif value == "healthy" then
            found = true
            upstream = domain
            break
        end

    end
    core.log.info("apple-healthcheck target_list: ",core.json.delay_encode(fetch_target_list(), true))

    if not found or conf.healthcheck_bypass then
        local suffix = suffix_location[conf.bypass_suffix] or ""
        upstream = prefix_without_smp .. suffix   ..  suffix_apple
    end
    
    core.log.warn("apple-healthcheck: ",upstream)

    ctx.matched_route.value.upstream.nodes ={
        {
                host = upstream,
                port = 9080,
                weight = last_check_ver,  -- 防止新旧node的值相同
                priority = 0
        }
    }

    core.log.info("apple-healthcheck",core.json.delay_encode(ctx, true))
end

function  _M.init()
    if not shm then
        core.log.error("need apple-healthcheck shared dict")
        return nil
    end
    core.log.warn("apple-healthcheck plugins init")
    if ngx_worker_id() == 0 and active_check_timer == nil then
        active_check_timer = create_timer()
    end
end

return _M
