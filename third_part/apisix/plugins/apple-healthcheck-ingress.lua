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
local ngx      = ngx
local plugin_name = "apple-healthcheck-ingress"
local schema_def = require("apisix.schema_def")
local cjson = require("cjson.safe").new()
local apple_health = require("apisix.plugins.apple-healthcheck")


local schema = {
    type = "object",
    properties = {
        healthcheck_bypass = {type = "boolean", default = false},
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
        
    }
}


local consumer_schema = {
    type = "object",
    -- can't use additionalProperties with dependencies
    properties = {},
    
}


local _M = {
    version = 0.1,
    priority = 98,
    name = plugin_name,
    schema = schema
}

-- constants
local SHM_PREFIX = "apple-healthcheck"
local shm = ngx.shared["apple-healthcheck"]
local Region = {["sh"]= true,["tj"]=true}

function _M.check_schema(conf, schema_type)
    core.log.info("input conf: ", core.json.delay_encode(conf))

    local ok, err
    if schema_type == core.schema.TYPE_CONSUMER then
        ok, err = core.schema.check(consumer_schema, conf)
    else
        return core.schema.check(schema, conf)
    end

    if not ok then
        return false, err
    end

    return true
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

    local x_device_oem_host = core.request.header(ctx, "x-device-oem-host")
    if not x_device_oem_host then
        return 400, "required x-device-oem-host header"
    end

    local x_pod = core.request.header(ctx, "x-pod")
    if not x_pod then
        return 400, "required x-pod header"
    end




    local regex = "^(.*)-([^-]*)-([^-]*)-smp(?:-(dr))?[^-]*$"
    local match = ngx.re.match(x_device_oem_host or x_pod , regex)

    if not match then
        return 400, "域名不匹配"
    end
    core.log.warn("apple-healthcheck match: ",match[1]," ",match[2]," ",match[3]," ",match[4])
    local is_dr = match[4] and true or false

    apple_health.set_val_to_redis(user_identifier,"x_device_oem_host",x_device_oem_host,"x_pod",x_pod,"region"
    ,match[2],"pod",match[3],"is_dr",is_dr)

end

function  _M.init()
    if not shm then
        core.log.error("need apple-healthcheck shared dict")
        return
    end
end

return _M
