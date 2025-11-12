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
local ngx      = ngx
local plugin_name = "applehealthcheck2dk"
local apple_health = require("apisix.plugins.applehealthcheck2apple")



local schema = {
    type = "object",
    properties = {
    }
}

local _M = {
    version = 0.1,
    priority = 98,
    name = plugin_name,
    schema = schema
}


function _M.check_schema(conf)
    return core.schema.check(schema, conf)
end

function _M.access(conf, ctx)

    local user_identifier = core.request.header(ctx, "x-user-identifier")
    if not user_identifier then
        return 400, '{"message":"required x-user-identifier header"}'
    end

    local regex
    local x_device_oem_host = core.request.header(ctx, "x-device-oem-host")
    if not x_device_oem_host then
        return 400, '{"message":"required x-device-oem-host header"}'
    end
    
    local x_pod = core.request.header(ctx, "x-pod")
    if not x_pod then
        return 400, '{"message":"required x-pod header"}'
    end

    local regex = "^cn-apple-pay-gateway-([^-]+)(?:-(?!smp)([^-]+))?(?:-smp(?:-(dr))?)?.apple.com"
    local match = ngx.re.match(x_device_oem_host, regex)

    if not match then
        return 400, '{"message":"parse x-device-oem-host or x-pod format failure"}'
    end
    core.log.warn("apple-healthcheck match: ",match[1]," ",match[2]," ",match[3])
    local is_dr = match[3] and true or false

    local ok, _ = apple_health.set_val_to_redis(user_identifier,"x_device_oem_host",x_device_oem_host,"x_pod",x_pod,"region"
    ,match[1] or "","pod",match[2] or "","is_dr",is_dr)

    if not ok then
        return 500, '{"message":"Internal Server Error: fali set value to redis"}'
    end

end

return _M
