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
local plugin_name = "applehealthcheck2apple"
local schema_def = require("apisix.schema_def")
local cjson = require("cjson.safe").new()
local local_conf = require('apisix.core.config_local').local_conf()



-- serialize a table to a string
local serialize = cjson.encode

-- deserialize a string to a table
local deserialize = cjson.decode

local schema = {
    type = "object",
    properties = {
        healthcheck_bypass = {type = "boolean", default = false},
        bypass_suffix = {type = "string", enum = {"smp", "smp-dr", "public"},},
        endpoint = { type = "array",items = {type = "string"}}
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
    ip =  local_conf.redis.ip,
    port = local_conf.redis.port,
    passwd = local_conf.redis.passwd,
    db = local_conf.redis.db,
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
    core.log.info("clear_target_nodes")

    return success
end


function _M.check_schema(conf, schema_type)

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
            if  conf.endpoint and #endpoint > 0 then
                for _, domain in ipairs(endpoint) do
                    add_target_node(domain)
                    core.log.info("add_target_node: ", domain)
                end
            end
        end
    end

    return true
end

local function key_for(key_prefix, hostname)
    return string_format("%s:%s", key_prefix, hostname or "")
end

local function get_val_from_redis(domain)
    local red = redis:new(opts)
    if not red then
        core.log.warn("new redis err")
        return nil, nil, "redis connect err"
    end
    local region = red:hget(redis_prefix .. domain , "region")
    local pod = red:hget(redis_prefix .. domain , "pod")


    red:set_keepalive(opts.freetime, opts.poolsize)
    local res = ""
    if region ~= ngx.null and region ~= nil and pod ~= "" then 
        res = res .. "-" .. region
    end

    if pod ~= ngx.null and pod ~= nil and pod ~= "" then 
        res = res .. "-" .. pod
    end
    core.log.info("redis key: ", redis_prefix .. domain, " ",res)
    if res == "" then
        return nil
    end
    return res
end


local function set_val_to_redis(domain, ...)
    -- core.log.error("prefix: ", prefix)
    local red, err = redis:new(opts)
    if not red then
        core.log.error("redis err: ", err)
        return false, "redis connect err"
    end
    local res, err = red:hset(redis_prefix .. domain, ...)
    if not res then
        core.log.error("failed to set hset: ", err)
        return false, "failed to set hset: " .. err
    end
    core.log.info("redis key: ", redis_prefix .. domain, ...)
    red:set_keepalive(opts.freetime, opts.poolsize)
    return true
end
_M.set_val_to_redis = set_val_to_redis






local function report_http_status(domain, status, limit)
    local state_key = key_for(TARGET_STATE, domain)
    local old_status, flags = shm:get(state_key)
    if not old_status then
        local _, err = shm:safe_set(state_key,"healthy")
        if err then
            core.log.error("dict set err: ", err)
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
            core.log.info(domain," fali counter: ", multictr)
            if err then
                core.log.error("COUNTER err: ",err)
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
MIIFJzCCBA+gAwIBAgIIELnfS9XoEk0wDQYJKoZIhvcNAQELBQAwezE1MDMGA1UE
AwwsQXBwbGUgQ29ycG9yYXRlIEV4dGVybmFsIEF1dGhlbnRpY2F0aW9uIENBIDEx
IDAeBgNVBAsMF0NlcnRpZmljYXRpb24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBs
ZSBJbmMuMQswCQYDVQQGEwJVUzAeFw0yNTA4MjEwNTU1MjdaFw0yNjA5MTUxOTU1
MTNaMIH3MSswKQYKCZImiZPyLGQBAQwbaWRlbnRpdHk6aWRtcy5ncm91cC4xMzQ2
MDQzMTEwLwYDVQQDDChPUkctN2NjYzE3NmUtYWFlYi00MDIzLWFkNGItZTAwYmFl
ZGVmZWQ1MSUwIwYDVQQLDBxtYW5hZ2VtZW50OmlkbXMuZ3JvdXAuNzI2NjA0MUkw
RwYDVQQKDEBHcmVhdCBXYWxsIE1vdG9yIENvbXBhbnkgOjo6ZmIxZDg1NjQtNTU3
OS00ZmE4LThmNTItZDNhY2Y5NWE1ZmMzMSMwIQYKCZImiZPyLGQBGRYTQ2VydGlm
aWNhdGUgTWFuYWdlcjCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBAL5M
OAaIen27+PRwZfe9glkUhBabx/WQxSJRqUnWbEZ8hLegKvaWZBMTVn/hxVCEoXzI
vyoQuv58Z3Vmwf9iCSRdmvsC7BJu+gAos9TwZo7ZJTFGppJd0MaNYxCym6F0rLN1
sF13fZFmiBJVX+6IXD5005hT0bSfyTnL1HfBHobGC2PELPo1vV0ZWf244c7Jubti
4Ga08JRDQOnintuEG6oiGP7Xt6MqBM1VkaYgJsrby9RYwpDnV7C6jKn+7zF57Wmr
1yxoGHItQv1lcVYQuB2I1e5nKJ1XfBO22ukoi+2ss3ICFma0lmjdr8NoZ4Aq/SS4
9gFD0UzURnMegiOPxqMCAwEAAaOCATAwggEsMAwGA1UdEwEB/wQCMAAwHwYDVR0j
BBgwFoAUWUGmOVO5lKWmGKZWu3QlEtZQYcAwfQYIKwYBBQUHAQEEcTBvMDUGCCsG
AQUFBzAChilodHRwOi8vY2VydHMuYXBwbGUuY29tL2NvcnBleHRhdXRoY2ExLmRl
cjA2BggrBgEFBQcwAYYqaHR0cDovL29jc3AuYXBwbGUuY29tL29jc3AwMy1jb3Jw
ZXh0YXV0aDAyMBMGA1UdJQQMMAoGCCsGAQUFBwMCMDgGA1UdHwQxMC8wLaAroCmG
J2h0dHA6Ly9jcmwuYXBwbGUuY29tL2NvcnBleHRhdXRoY2ExLmNybDAdBgNVHQ4E
FgQUH8a4JCq4bc/d3G6Bbiz8N0IJky4wDgYDVR0PAQH/BAQDAgeAMA0GCSqGSIb3
DQEBCwUAA4IBAQCYivNQmFDh1UQJgdENTA6AnoTvGhTg3NCNoxJYDuZIF/zKXxCI
Q5LTZ3C8dRG5Q20+vV7Sxh43TjrUrbxZyKQYZWzKgAYCkSQv1dtmeFUbYlf+YEo3
xv/yh1SzymH1weflJTQnLDkJED1T8quNfu0cbZJRRoxZI6nInSHEoDftYiVAW07o
DEeX8Q2OaU4EUZ3rw8YYlulMuwe95c5EghE/69/u0tvA3uO+Ba7QgxDuESgnc1gX
uqG9a4g5MjwzTOJfuwNXNISJmSAiBLD3qexi/uaLseFpPd2kuhUNZhb3SuO8Okbf
Fli/3CAbuqnk/KrFs1gcngoqiU3BOV/+NkCq
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIEVDCCAzygAwIBAgIIF4vODdrr46AwDQYJKoZIhvcNAQELBQAwZjEgMB4GA1UE
AwwXQXBwbGUgQ29ycG9yYXRlIFJvb3QgQ0ExIDAeBgNVBAsMF0NlcnRpZmljYXRp
b24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAe
Fw0xMzEwMzAyMjA2MjFaFw0yOTA3MTcxOTIwNDVaMHsxNTAzBgNVBAMMLEFwcGxl
IENvcnBvcmF0ZSBFeHRlcm5hbCBBdXRoZW50aWNhdGlvbiBDQSAxMSAwHgYDVQQL
DBdDZXJ0aWZpY2F0aW9uIEF1dGhvcml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjEL
MAkGA1UEBhMCVVMwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCiJgVj
YR/T0LyNvndubeEsRn22T5PHWMV29gPV2UonspETuSoFLrlZTTt7iRgJm0pQTPX3
sxzOTCsSloFrNv4kC9KNNEg97YMU9ndpXEGTtvRyviWQ2IC6yWu6a0nU1JZqAurf
B+bUUGc7R2HGYnhrzjBB1vbg051rq4AYLpbZxMldQZkHuBzcflrnZErqr9EYfPkJ
Xht+s4PDxum1t/H+5+bNlskM3a/Ip+usZnGjEPqSRvQm5yc2CApE6qVU/8TTlVla
y2S2QW9/zNM6hz+IBHOYN59/xSLLZe2U7OA6DVmmEUZt9zkit1h2m60l0KtgNQ5k
heWX574nFkOl91tpAgMBAAGjgfAwge0wQQYIKwYBBQUHAQEENTAzMDEGCCsGAQUF
BzABhiVodHRwOi8vb2NzcC5hcHBsZS5jb20vb2NzcDA0LWNvcnByb290MB0GA1Ud
DgQWBBRZQaY5U7mUpaYYpla7dCUS1lBhwDASBgNVHRMBAf8ECDAGAQH/AgEAMB8G
A1UdIwQYMBaAFDUgJs6FvkkmIAHdyO7/PWjI0N/1MDIGA1UdHwQrMCkwJ6AloCOG
IWh0dHA6Ly9jcmwuYXBwbGUuY29tL2NvcnByb290LmNybDAOBgNVHQ8BAf8EBAMC
AQYwEAYKKoZIhvdjZAYYAwQCBQAwDQYJKoZIhvcNAQELBQADggEBAIvOsQYQhJlo
ObZTuK47qD5SFaqqjm8HKaH6gQS7FsQLmk5h2hDEK10dZQhpCu901iYPaadjQrYT
RDLwlZm5oLR5PowgNt9RxJ2tGYdcpo6xp93c51N0Z5Ejf9BJth1qUsTKfjm5GVgP
RokeWVs92M3ONiMjInKN2tgJoAJxoBU9kMaJ65fjf/ZLl7GbXBtcTbzd2dyhQtxp
Z7ABXffXw26iSKGXUH0hSi0wGupADyzo2ltuGclrVw0E5G4GE2n5irnVZHZsFeWT
OA+f4lZe99Q3xssczEyXKJy5qlk1y1gtp78+RPrNTHZMtphxCxCbFBAItYELh8Fs
LnwFyrOU85A=
-----END CERTIFICATE-----
-----BEGIN CERTIFICATE-----
MIIDsTCCApmgAwIBAgIIFJlrSmrkQKAwDQYJKoZIhvcNAQELBQAwZjEgMB4GA1UE
AwwXQXBwbGUgQ29ycG9yYXRlIFJvb3QgQ0ExIDAeBgNVBAsMF0NlcnRpZmljYXRp
b24gQXV0aG9yaXR5MRMwEQYDVQQKDApBcHBsZSBJbmMuMQswCQYDVQQGEwJVUzAe
Fw0xMzA3MTYxOTIwNDVaFw0yOTA3MTcxOTIwNDVaMGYxIDAeBgNVBAMMF0FwcGxl
IENvcnBvcmF0ZSBSb290IENBMSAwHgYDVQQLDBdDZXJ0aWZpY2F0aW9uIEF1dGhv
cml0eTETMBEGA1UECgwKQXBwbGUgSW5jLjELMAkGA1UEBhMCVVMwggEiMA0GCSqG
SIb3DQEBAQUAA4IBDwAwggEKAoIBAQC1O+Ofah0ORlEe0LUXawZLkq84ECWh7h5O
7xngc7U3M3IhIctiSj2paNgHtOuNCtswMyEvb9P3Xc4gCgTb/791CEI/PtjI76T4
VnsTZGvzojgQ+u6dg5Md++8TbDhJ3etxppJYBN4BQSuZXr0kP2moRPKqAXi5OAYQ
dzb48qM+2V/q9Ytqpl/mUdCbUKAe9YWeSVBKYXjaKaczcouD7nuneU6OAm+dJZcm
hgyCxYwWfklh/f8aoA0o4Wj1roVy86vgdHXMV2Q8LFUFyY2qs+zIYogVKsRZYDfB
7WvO6cqvsKVFuv8WMqqShtm5oRN1lZuXXC21EspraznWm0s0R6s1AgMBAAGjYzBh
MB0GA1UdDgQWBBQ1ICbOhb5JJiAB3cju/z1oyNDf9TAPBgNVHRMBAf8EBTADAQH/
MB8GA1UdIwQYMBaAFDUgJs6FvkkmIAHdyO7/PWjI0N/1MA4GA1UdDwEB/wQEAwIB
BjANBgkqhkiG9w0BAQsFAAOCAQEAcwJKpncCp+HLUpediRGgj7zzjxQBKfOlRRcG
+ATybdXDd7gAwgoaCTI2NmnBKvBEN7x+XxX3CJwZJx1wT9wXlDy7JLTm/HGa1M8s
Errwto94maqMF36UDGo3WzWRUvpkozM0mTcAPLRObmPtwx03W0W034LN/qqSZMgv
1i0use1qBPHCSI1LtIQ5ozFN9mO0w26hpS/SHrDGDNEEOjG8h0n4JgvTDAgpu59N
CPCcEdOlLI2YsRuxV9Nprp4t1WQ4WMmyhASrEB3Kaymlq8z+u3T0NQOPZSoLu8cX
akk0gzCSjdeuldDXI6fjKQmhsTTDlUnDpPE2AAnTpAmt8lyXsg==
-----END CERTIFICATE-----]]

local key =[[-----BEGIN RSA PRIVATE KEY-----
MIIEpAIBAAKCAQEAvkw4Boh6fbv49HBl972CWRSEFpvH9ZDFIlGpSdZsRnyEt6Aq
9pZkExNWf+HFUIShfMi/KhC6/nxndWbB/2IJJF2a+wLsEm76ACiz1PBmjtklMUam
kl3Qxo1jELKboXSss3WwXXd9kWaIElVf7ohcPnTTmFPRtJ/JOcvUd8EehsYLY8Qs
+jW9XRlZ/bjhzsm5u2LgZrTwlENA6eKe24QbqiIY/te3oyoEzVWRpiAmytvL1FjC
kOdXsLqMqf7vMXntaavXLGgYci1C/WVxVhC4HYjV7mconVd8E7ba6SiL7ayzcgIW
ZrSWaN2vw2hngCr9JLj2AUPRTNRGcx6CI4/GowIDAQABAoIBAE7h7GV05IXDSjcV
codH9MT1Vq3ChJh8GuOXgzu62SY8zo0JpVWTUMeBgB1Bmte+Kuy9kFShG8qLCh3l
6yvwWQbMkIZVl0Mq4pH3TVhLENBNHfg3p6vLnNP5XuPYjd/XLBG2CtYrxo7juCsV
Xc9UkhxHtECUGj0r8S92mUvM71kA/0KU0O8tdyguXHqfKHmi9VinXfX+1M3Xavie
klgzqJZtdsv2cSUwpWJvAWhk0ZN/DE3nvLMMWcc/Rm3KoGiRgN0fkc1E6zJ0ZcAq
+P8wT1yDLwTkPc2nCehZ/m0EeTeYs4m9ZskzQ/+KwsZe6nxEpsElcnBumrGaxjHX
1tCG/ekCgYEA4nJp0DjEPolYDzm6zDnsVTuX4nJvMOw/qKGqxcyASgiD7qBnO2Fc
DHwZgJ7CaGfgLM4VYNHedOAP3Br32xwXB0b1SpHAK6DPx+ZwA1IzaDisqskgR0bn
4lnjFvPOG9wAJ9NCDjeJeWUW8DcniNtRTdCW4I8Zi1NqcRSWTl72O+kCgYEA1yIP
yR6n0p0aoi6A6t88FCn1Sah7dE9jzfUPq/N8COhyt4lRdTnZN1EHQmroZ3ecBxZR
+3sqyJMmhnbApXOKb3OmqrabuhHITV3rVylyXG72vMh5Gt5KGYDMQwhPMFLw5+1j
g1jEdAlj50ySu1xxz5PLqBHttUkuu2NPMuIocqsCgYBeuOlWNkiwuBbj14wx3ZDk
Xlc8XA3y8v/19BpRPyfyz/kQGnzUM/ejKU4ppT9BGSKG23XJ2EArt4Yq1gUT3H4t
hxsYJDu0hEImJlh4qyvhzsM7dYJRDnH1FxCNC1MOCErwXchl1gllhEnCFfAtqUAr
QrO6H2HaC/ycbLYq9kId8QKBgQCMBFE91sPnYfTZpWamdxBFF2HbxNpEwv70JxFC
GsCZk6BGMAtiPnpPdF9DLQ2BeemE+1P0Vx9rV8p1LYkIpgBttVm+Ngd4vOYe5Iet
PP5/hoD0MY4QnKihnKBU6G2RyAmfCXQBIp8J3qq0+bNuWiaAsXKVOsX5fV36/BGp
zmQA7QKBgQDhKfc0Ebj4hYEZs/den4i8a9y+si7nMBsWnvc1T6lg8hu1kTE+3YoZ
4dXkUN0HebqsOeMad+W1j0HzW2O4EroVecsaE1HNE/kvPyvKNjf76H4iUpjaWoRB
pg8T9Y03gpVd5lmIUMKvHzpLRPvOF+F1EPHJsoiDIsO+7elECzLrTQ==
-----END RSA PRIVATE KEY-----
]]


local function create_timer()

        local http = require "resty.http"
        return ngx.timer.every(10,function (premature)
            if premature then
                return
            end
            core.log.info("apple-healthcheck timer strat")
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
                    port = 443,
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
                        path = "/partner/healthcheck",
                        headers = {
                            ["Host"] =upstream,
                            ["Connection"] = "close"
                        },
                    }
                    if not res then
                        core.log.info("apple-healthcheck request error: ",err)
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
        conf.healthcheck_bypass = true
        conf.bypass_suffix = "public"
    end

    local user_identifier = core.request.header(ctx, "x-user-identifier")
    if not user_identifier then
        return 400, '{"message":"required x-user-identifier header"}'
    end

    local region_pod, err = get_val_from_redis(user_identifier) 
    
    if err then
        return 500, '{"message":"Internal Server Error: fali get value form redis"}'
    end

    local prefix_without_smp
    if not region_pod then
        local x_pod = core.request.header(ctx, "x-pod")
        local regex = "^(.*?)(?=-smp|-smp-dr|$)(-smp)?(-dr)?$"
        local match = ngx.re.match(x_pod or "", regex)
    
        if not match then
            return 400, '{"message":"identifier关联的x_pod不存在"}'
        end
        prefix_without_smp = match[1]
        core.log.error(match[1])

    else
        prefix_without_smp = "cn-apple-pay-gateway" ..  region_pod
    end

    local upstreams = {}
    local temp_upstreams = {
        prefix_without_smp .. "-smp" .. suffix_apple,
        prefix_without_smp .. "-smp-dr" .. suffix_apple,
        prefix_without_smp .. suffix_apple
    }
    
    local upstream
    local found = false

    if not conf.healthcheck_bypass then
        local target_list = fetch_target_list()
        for _, key in ipairs(temp_upstreams) do
            if target_list[key] then  -- 检查是否在endpoint配置
                table.insert(upstreams, key)
            end
        end
    end

    if not upstreams or #upstreams == 0 then
        return 400, '{"message":"identifier关联的' .. prefix_without_smp .. '无效或者不存在"}'
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


    ctx.matched_route.value.upstream.nodes ={
        {
                host = upstream,
                port = 443,
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


local function fetch_healtheck_status()
    local target_list = fetch_target_list()

    for domain, _ in ipairs(target_list) do
        local state_key = key_for(TARGET_STATE, domain)
        local value, _ = shm:get(state_key)
        target_list[domain] = value and value or "healthy"
    end

    core.response.exit(200, target_list)

end

function _M.api()
    return {
        {
            methods = {"GET"},
            uri = "/apisix/applehealthcheck",
            handler = fetch_healtheck_status,
        }
    }
end

return _M
