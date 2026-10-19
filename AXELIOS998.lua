--[[
    Roblox MCP bridge client v2

    Jangan taruh token di file ini. Isi dari loader sebelum memuat script:
        getgenv().MCP_URL   = "ws://127.0.0.1:8765"   -- HP: ws://IP-PC:8765
        getgenv().MCP_TOKEN = "tokenmu"
        loadstring(game:HttpGet("URL_RAW_CLIENT"))()
]]

local env = (getgenv and getgenv()) or _G
local URL = env.MCP_URL or "ws://127.0.0.1:8765"
local TOKEN = env.MCP_TOKEN

if type(TOKEN) ~= "string" or TOKEN == "" then
    warn('[MCP] Isi token dulu sebelum load:  getgenv().MCP_TOKEN = "tokenmu"')
    return
end

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local LogService = game:GetService("LogService")

local WS = (WebSocket and WebSocket.connect and WebSocket)
    or (syn and syn.websocket)
    or websocket
local doRequest = request or http_request or (syn and syn.request) or (http and http.request)
local loadstr = loadstring

if not WS then return warn("[MCP] Executor ini tidak punya WebSocket") end
if not loadstr then return warn("[MCP] Executor ini tidak punya loadstring") end

---------------------------------------------------------------------
-- Matikan instance lama kalau script dijalankan ulang
---------------------------------------------------------------------
if env.__MCP_STOP then pcall(env.__MCP_STOP) end

local running = true
local activeWs, logConn

env.__MCP_STOP = function()
    running = false
    if logConn then pcall(function() logConn:Disconnect() end) end
    if activeWs then pcall(function() activeWs:Close() end) end
end

---------------------------------------------------------------------
-- Util
---------------------------------------------------------------------
local function json(v) return HttpService:JSONEncode(v) end
local function unjson(s) return HttpService:JSONDecode(s) end
local function clamp(v, a, b) return math.max(a, math.min(b, v)) end

local function serialize(v, depth)
    depth = depth or 0
    local t = typeof(v)
    if v == nil or t == "boolean" or t == "string" then return v end
    if t == "number" then
        if v ~= v or v == math.huge or v == -math.huge then return tostring(v) end
        return v
    end
    if t == "Instance" then return v:GetFullName() .. " [" .. v.ClassName .. "]" end
    if t == "table" and depth < 4 then
        local out = {}
        if #v > 0 then
            for i, x in ipairs(v) do out[i] = serialize(x, depth + 1) end
        else
            for k, x in pairs(v) do out[tostring(k)] = serialize(x, depth + 1) end
        end
        return out
    end
    return tostring(v)
end

local function capabilities()
    local g = (getgenv and getgenv()) or _G
    local names = {
        "loadstring", "request", "writefile", "readfile", "isfile", "makefolder",
        "setclipboard", "gethui", "getgc", "getscripts", "getrunningscripts",
        "getloadedmodules", "getnilinstances", "decompile", "hookfunction",
        "hookmetamethod", "setfenv", "firesignal", "fireclickdetector",
    }
    local have = {}
    for _, n in ipairs(names) do
        if g[n] ~= nil then have[#have + 1] = n end
    end
    return have
end

local function helloInfo()
    local lp = Players.LocalPlayer
    local exName
    if identifyexecutor then
        local ok, n, v = pcall(identifyexecutor)
        if ok then exName = tostring(n) .. (v and (" " .. tostring(v)) or "") end
    end
    return {
        version = 2,
        placeId = game.PlaceId,
        jobId = game.JobId,
        user = lp and lp.Name or "?",
        executor = exName or "unknown",
        caps = capabilities(),
    }
end

-- "game.Workspace.Map" / "Workspace.Map" / "ReplicatedStorage"
local function resolve(path)
    path = tostring(path or "game")
    local parts = string.split(path, ".")
    local cur = game
    local startAt = (parts[1] == "game") and 2 or 1
    for i = startAt, #parts do
        local name = parts[i]
        if name ~= "" then
            local nxt = cur:FindFirstChild(name)
            if not nxt and cur == game then
                pcall(function() nxt = game:GetService(name) end)
            end
            if not nxt then
                return nil, "tidak ditemukan: '" .. name .. "' di " .. cur:GetFullName()
            end
            cur = nxt
        end
    end
    return cur
end

---------------------------------------------------------------------
-- Buffer log console
---------------------------------------------------------------------
local logs, LOG_MAX = {}, 300

local function pushLog(t, mtype, msg)
    local lvlName = (typeof(mtype) == "EnumItem") and mtype.Name or tostring(mtype)
    local level = lvlName:gsub("^Message", "")
    logs[#logs + 1] = { t = t, level = level, msg = tostring(msg) }
    if #logs > LOG_MAX then table.remove(logs, 1) end
end

pcall(function()
    local hist = LogService:GetLogHistory()
    for i = math.max(1, #hist - 100), #hist do
        local h = hist[i]
        pushLog(os.date("%H:%M:%S", h.timestamp), h.messageType, h.message)
    end
end)
logConn = LogService.MessageOut:Connect(function(message, mtype)
    pushLog(os.date("%H:%M:%S"), mtype, message)
end)

---------------------------------------------------------------------
-- Handler perintah
---------------------------------------------------------------------
local function handleExec(msg)
    local out = {}
    local function cap(...)
        local p = table.pack(...)
        for i = 1, p.n do p[i] = tostring(p[i]) end
        out[#out + 1] = table.concat(p, "\t")
    end

    local fn, err = loadstr(tostring(msg.code or ""), "=mcp")
    if not fn then return { ok = false, error = tostring(err), logs = out } end

    if setfenv and getfenv then
        pcall(function()
            local base = getfenv(fn)
            setfenv(fn, setmetatable({ print = cap, warn = cap }, { __index = base, __newindex = base }))
        end)
    end

    local res = table.pack(pcall(fn))
    if not res[1] then return { ok = false, error = tostring(res[2]), logs = out } end

    local ret = {}
    for i = 2, res.n do ret[#ret + 1] = serialize(res[i]) end
    return { ok = true, result = (#ret <= 1) and ret[1] or ret, logs = out }
end

local function handleRequest(msg)
    if not doRequest then return { ok = false, error = "request() tidak tersedia di executor ini" } end
    local ok, resp = pcall(doRequest, {
        Url = msg.url,
        Method = msg.method or "GET",
        Headers = msg.headers,
        Body = msg.body,
    })
    if not ok then return { ok = false, error = tostring(resp) } end
    return { ok = true, response = {
        StatusCode = resp.StatusCode, Headers = resp.Headers, Body = resp.Body,
    } }
end

local function handleTree(msg)
    local root, err = resolve(msg.path)
    if not root then return { ok = false, error = err } end
    local maxDepth = clamp(tonumber(msg.depth) or 2, 0, 8)
    local maxNodes = clamp(tonumber(msg.max_nodes) or 150, 1, 1000)
    local lines, count, truncated = {}, 0, false

    local function walk(inst, depth)
        if truncated then return end
        count = count + 1
        if count > maxNodes then truncated = true return end
        local kids = inst:GetChildren()
        local suffix = (depth >= maxDepth and #kids > 0) and (" (+" .. #kids .. ")") or ""
        lines[#lines + 1] = string.rep("  ", depth) .. inst.Name .. " [" .. inst.ClassName .. "]" .. suffix
        if depth < maxDepth then
            for _, c in ipairs(kids) do walk(c, depth + 1) end
        end
    end

    walk(root, 0)
    if truncated then lines[#lines + 1] = "... (dipotong di " .. maxNodes .. " node)" end
    return { ok = true, result = table.concat(lines, "\n") }
end

local function handleFind(msg)
    local root, err = resolve(msg.root)
    if not root then return { ok = false, error = err } end
    local cls = (type(msg.class_name) == "string" and msg.class_name ~= "") and msg.class_name or nil
    local needle = string.lower(tostring(msg.name_contains or ""))
    local maxR = clamp(tonumber(msg.max_results) or 50, 1, 500)

    local out = {}
    for _, d in ipairs(root:GetDescendants()) do
        local okClass = true
        if cls then
            local ok, isA = pcall(function() return d:IsA(cls) end)
            okClass = ok and isA
        end
        if okClass and (needle == "" or string.find(string.lower(d.Name), needle, 1, true)) then
            out[#out + 1] = d:GetFullName() .. " [" .. d.ClassName .. "]"
            if #out >= maxR then break end
        end
    end
    if #out == 0 then return { ok = true, result = "(tidak ada hasil)" } end
    return { ok = true, result = table.concat(out, "\n") }
end

local function handleLogs(msg)
    local limit = clamp(tonumber(msg.limit) or 30, 1, 200)
    local level = string.lower(tostring(msg.level or ""))
    local out = {}
    for i = #logs, 1, -1 do
        local l = logs[i]
        if level == "" or string.lower(l.level) == level then
            local m = l.msg
            if #m > 300 then m = m:sub(1, 300) .. "..." end
            table.insert(out, 1, "[" .. l.t .. "][" .. l.level .. "] " .. m)
            if #out >= limit then break end
        end
    end
    if #out == 0 then return { ok = true, result = "(log kosong)" } end
    return { ok = true, result = table.concat(out, "\n") }
end

local handlers = {
    exec = handleExec,
    request = handleRequest,
    tree = handleTree,
    find = handleFind,
    logs = handleLogs,
    ping = function() return { ok = true, result = "pong" } end,
}

---------------------------------------------------------------------
-- Koneksi
---------------------------------------------------------------------
local function runSession()
    local ok, ws = pcall(WS.connect, URL)
    if not ok or not ws then
        warn("[MCP] gagal connect ke " .. URL .. " : " .. tostring(ws))
        return false
    end
    activeWs = ws
    local alive = true

    ws.OnClose:Connect(function() alive = false end)
    ws.OnMessage:Connect(function(raw)
        local okp, msg = pcall(unjson, raw)
        if not okp or type(msg) ~= "table" then return end
        task.spawn(function()
            local handler = handlers[msg.type]
            local reply
            if handler then
                local okh, r = pcall(handler, msg)
                reply = okh and r or { ok = false, error = tostring(r) }
            else
                reply = { ok = false, error = "perintah tidak dikenal: " .. tostring(msg.type) }
            end
            reply.id = msg.id
            local oke, enc = pcall(json, reply)
            if not oke then
                enc = json({ id = msg.id, ok = false, error = "gagal encode hasil: " .. tostring(enc) })
            end
            pcall(function() ws:Send(enc) end)
        end)
    end)

    ws:Send(json({ type = "hello", token = TOKEN, info = helloInfo() }))
    print("[MCP] terhubung ke " .. URL)

    while alive and running do task.wait(0.5) end

    pcall(function() ws:Close() end)
    activeWs = nil
    if running then warn("[MCP] koneksi terputus (token salah / server mati?), mencoba lagi...") end
    return true
end

task.spawn(function()
    local delay = 2
    while running do
        local t0 = os.clock()
        local connected = runSession()
        if not running then break end
        if connected and os.clock() - t0 > 10 then delay = 2 else delay = math.min(delay * 2, 15) end
        task.wait(delay)
    end
end)

print("[MCP] bridge v2 jalan, target " .. URL)
