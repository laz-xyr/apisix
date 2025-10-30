local redis = require "resty.redis"

local M = {}

local function set_keepalive(p, red, opts)
    while true do
        if "dead" == coroutine.status(p) then break end
        ngx.sleep(0.01)
    end
    local ok, err = red:set_keepalive(opts.freetime, opts.poolsize)
    if not ok then
        ngx.log(ngx.ERR, "failed to set keepalive: ", err)
        return
    end
end

function M:new(opts)
    opts = opts or {}
    opts.ip = opts.ip or "127.0.0.1"
    opts.port = opts.port or 6379
    opts.db = opts.db or 0
    opts.timeout = opts.timeout or 1000
    opts.poolsize = opts.poolsize or 100 -- 连接池大小 100 个
    opts.freetime = opts.freetime or (10 * 1000) -- 最大空闲时间 10s

    local red = redis:new()
    red:set_timeout(opts.timeout)
    local ok, err = red:connect(opts.ip, opts.port)
    if not ok then
        ngx.log(ngx.ERR, "failed to connect redis: ", err)
        return ok, err
    end
    if opts.passwd ~= nil and opts.passwd ~= ngx.null then
        local count, err_count = red:get_reused_times() -- 如果需要密码，来自连接池的链接不需要再进行auth验证；如果不做这个判断，连接池不起作用
        if type(count) == "number" and count == 0 then
            local ok, err = red:auth(opts.passwd)
            ngx.log(ngx.ERR, "recreate redis: ", err)
            if not ok then
                ngx.log(ngx.ERR,
                        "redis auth error: " .. tostring(opts.ip) .. ":" ..
                            tostring(opts.port) .. " error: " .. err)
                return nil
            end
        elseif err then
            ngx.log(ngx.ERR, "failed to authenticate: ", err_count)
            red:close()
            return nil
        end
    end
    -- local count, err = red:get_reused_times()
    -- ngx.log(ngx.ERR, "redis get_reused_times: ", count)

    local ok, err = red:select(opts.db)
    if not ok then
        ngx.log(ngx.ERR, "failed to select redis db: ", err)
        return ok, err
    end

    -- local t, err = ngx.thread.spawn(set_keepalive, coroutine.running(), red, opts)
    -- if not t then
    --     ngx.log(ngx.ERR, "failed to spawn thread set_keepalive: ", err)
    --     return t, err
    -- end

    return red
end

return M
