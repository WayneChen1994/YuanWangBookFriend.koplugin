--[[--
串行请求队列（PRD F7.4）：任一时刻只有一个请求在飞，
避免 KPW4 这类低性能设备并发请求导致卡顿或 OOM。
超时与重试：最多 max_retries 次，指数退避。
--]]--

local socket_ok, socket = pcall(require, "socket")

local Queue = {
    items = {},
    running = false,
    last_error = nil,
}

function Queue:init(opts)
    opts = opts or {}
    self.items = opts.items or {}
    self.running = false
    self.last_error = nil
    return self
end

function Queue:size()
    return #self.items
end

function Queue:clear()
    self.items = {}
end

--[[--
提交任务。
@param task { name=string, fn=function() -> result, err end, on_done=fn(result), on_error=fn(err), retries=number }
--]]
function Queue:submit(task)
    if type(task) ~= "table" or type(task.fn) ~= "function" then
        return false
    end
    task.attempts = 0
    task.max_retries = task.retries or 2
    table.insert(self.items, task)
    return true
end

local function sleep(seconds)
    if socket_ok and socket.sleep then
        socket.sleep(seconds)
    else
        -- 兜底：忙等（仅在 socket 不可用时使用）
        local t0 = os.clock()
        while os.clock() - t0 < seconds do end
    end
end

-- 顺序执行队列中所有任务（同步阻塞，调用方应放在后台协程/Trapper 中）
function Queue:process()
    if self.running then return false, "queue already running" end
    self.running = true

    while #self.items > 0 do
        local task = table.remove(self.items, 1)
        task.attempts = task.attempts + 1

        local ok, result, err = pcall(task.fn)
        if ok and err == nil then
            if task.on_done then
                pcall(task.on_done, result)
            end
        else
            local errmsg = ok and tostring(err) or tostring(result)
            if task.attempts <= task.max_retries then
                sleep(2 ^ (task.attempts - 1))  -- 1s, 2s, 4s...
                table.insert(self.items, 1, task)  -- 重新排队到队首
            else
                self.last_error = errmsg
                if task.on_error then
                    pcall(task.on_error, errmsg)
                end
            end
        end
    end

    self.running = false
    return true
end

return Queue
