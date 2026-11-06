--[[--
A small upload server for sending books over Wi-Fi from a browser. It runs
only while its screen is open: `step()` is called from a timer, never
blocks, and handles a few connections at a time.

  GET  /                      the upload page
  GET  /check?code=1234       200 if the code is right, 403 if not
  PUT  /upload?name=&code=    the file as the body (Content-Length required)

Files are written as "<name>.part" and renamed when complete, so a cut
connection never leaves half a book in the library.

The socket module (LuaSocket), the file functions and the clock are
passed in, so the specs run it against a fake network.
]]

local Http = require("sereno/transfer/http")

local Server = {}
Server.__index = Server

Server.PORT = 8181
local CHUNK = 64 * 1024
local HEAD_LIMIT = 16 * 1024
local IDLE_SECS = 30

--[[--
opts {
  socket   LuaSocket's module (`require("socket")`)
  dir      the folder books go to
  code     the 4-digit code shown on the e-reader
  page     the HTML page (string)
  words    { wrong_code, bad_type, too_big, failed } error texts for the page
  on_file  function(name, path, bytes) when a book has arrived
  on_activity function() whenever something happens (to redraw the screen)
  open, rename, remove, exists, now   (io.open, os.rename, os.remove, a file check, os.time by default)
}
]]
function Server.new(opts)
    local s = setmetatable({}, Server)
    s.socket = opts.socket
    s.dir = (opts.dir or "."):gsub("/+$", "")
    s.code = tostring(opts.code or "")
    s.page = opts.page or ""
    s.words = opts.words or {}
    s.on_file = opts.on_file
    s.on_activity = opts.on_activity
    s.open = opts.open or io.open
    s.rename = opts.rename or os.rename
    s.remove = opts.remove or os.remove
    s.exists = opts.exists or function(path)
        local f = io.open(path, "rb")
        if f then f:close() return true end
        return false
    end
    s.now = opts.now or os.time
    s.max_bytes = opts.max_bytes or Http.MAX_BYTES
    s.clients = {}
    s.received = {}
    return s
end

--- A random 4-digit code (not starting with 0, so it reads as a number).
function Server.newCode(random)
    random = random or math.random
    return tostring(random(1000, 9999))
end

--- Starts listening; returns true, or nil and the error.
function Server:start(port)
    local listener, err = self.socket.bind("*", port or Server.PORT)
    if not listener then return nil, err end
    listener:settimeout(0)
    self.listener = listener
    self.port = port or Server.PORT
    return true
end

function Server:stop()
    for _i, c in ipairs(self.clients) do self:drop(c) end
    self.clients = {}
    if self.listener then self.listener:close() end
    self.listener = nil
end

function Server:running() return self.listener ~= nil end

--- True while a book is being received (the timer then runs faster).
function Server:busy()
    for _i, c in ipairs(self.clients) do
        if c.state == "body" then return true end
    end
    return false
end

function Server:drop(c)
    if c.file then
        c.file:close()
        c.file = nil
        if c.part then self.remove(c.part) end
    end
    if c.sock then c.sock:close() end
    c.sock = nil
    c.state = "closed"
end

local function err(self, key, default)
    return Http.json({ error = self.words[key] or default })
end

function Server:reply(c, status, body, content_type)
    c.out = Http.response(status, body, content_type)
    c.state = "send"
    if c.file then
        c.file:close()
        c.file = nil
        if c.part then self.remove(c.part) end
    end
end

--- What to do once a request head has arrived.
function Server:route(c, req)
    if req.method == "GET" and (req.path == "/" or req.path == "/index.html") then
        return self:reply(c, 200, self.page, "text/html; charset=utf-8")
    elseif req.method == "GET" and req.path == "/check" then
        if req.params.code == self.code then return self:reply(c, 200, Http.json({ ok = true })) end
        return self:reply(c, 403, err(self, "wrong_code", "Wrong code. Check the code on the e-reader."))
    elseif req.method == "PUT" and req.path == "/upload" then
        if req.params.code ~= self.code then
            return self:reply(c, 403, err(self, "wrong_code", "Wrong code. Check the code on the e-reader."))
        end
        local name, why = Http.safeName(req.params.name)
        if not name then
            return self:reply(c, 415, err(self, why == "type" and "bad_type" or "bad_name", "Not a book KOReader can open."))
        end
        if not req.length then return self:reply(c, 400, err(self, "failed", "The upload failed.")) end
        if req.length > self.max_bytes then return self:reply(c, 413, err(self, "too_big", "This file is too big.")) end
        local final = Http.uniqueName(name, function(n) return self.exists(self.dir .. "/" .. n) end)
        if not final then return self:reply(c, 500, err(self, "failed", "The upload failed.")) end
        c.name, c.path, c.part = final, self.dir .. "/" .. final, self.dir .. "/" .. final .. ".part"
        c.file = self.open(c.part, "wb")
        if not c.file then
            c.part = nil
            return self:reply(c, 500, err(self, "failed", "The upload failed."))
        end
        c.left, c.bytes = req.length, 0
        c.state = "body"
        if c.left == 0 then return self:finish(c) end
        return
    end
    return self:reply(c, 404, err(self, "not_found", "Not found."))
end

function Server:finish(c)
    c.file:close()
    c.file = nil
    local ok = self.rename(c.part, c.path)
    if not ok then
        self.remove(c.part)
        c.part = nil
        return self:reply(c, 500, err(self, "failed", "The upload failed."))
    end
    c.part = nil
    self.received[#self.received + 1] = { name = c.name, bytes = c.bytes }
    if self.on_file then self.on_file(c.name, c.path, c.bytes) end
    return self:reply(c, 200, Http.json({ ok = true, name = c.name }))
end

-- one bounded round of work for a connection; returns true if it moved
function Server:serve(c)
    local moved = false
    if c.state == "head" then
        while true do
            local line, e, partial = c.sock:receive("*l")
            if not line then
                c.buffer = c.buffer .. (partial or "")
                if e ~= "timeout" then return self:drop(c) end
                break
            end
            moved = true
            line = c.buffer .. line
            c.buffer = ""
            if line == "" or line == "\r" then
                local req = Http.parseHead(table.concat(c.lines, "\n"))
                if not req then return self:drop(c) end
                self:route(c, req)
                break
            end
            c.lines[#c.lines + 1] = line
            c.head_bytes = c.head_bytes + #line
            if c.head_bytes > HEAD_LIMIT then return self:drop(c) end
        end
    end
    if c.state == "body" then
        for _i = 1, 32 do
            local data, e, partial = c.sock:receive(math.min(CHUNK, c.left))
            data = data or partial
            if data and #data > 0 then
                moved = true
                if not c.file:write(data) then
                    return self:reply(c, 500, err(self, "failed", "The upload failed. Is the e-reader full?"))
                end
                c.left = c.left - #data
                c.bytes = c.bytes + #data
                if c.left <= 0 then return self:finish(c) end
            end
            if e == "closed" then return self:drop(c) end
            if not data or #data == 0 or e == "timeout" then break end
        end
    end
    if c.state == "send" then
        local last, e, partial_last = c.sock:send(c.out, c.sent + 1)
        last = last or partial_last
        if last and last > c.sent then
            c.sent = last
            moved = true
        end
        if c.sent >= #c.out or (e and e ~= "timeout") then self:drop(c) end
    end
    return moved
end

--- Accepts new connections and moves every open one along. Never blocks.
function Server:step()
    if not self.listener then return false end
    local active = false
    while #self.clients < 8 do
        local sock = self.listener:accept()
        if not sock then break end
        sock:settimeout(0)
        self.clients[#self.clients + 1] = { sock = sock, state = "head", buffer = "", lines = {}, head_bytes = 0,
            sent = 0, seen = self.now() }
        active = true
    end
    local keep = {}
    for _i, c in ipairs(self.clients) do
        if self:serve(c) then
            c.seen = self.now()
            active = true
        elseif self.now() - c.seen > IDLE_SECS then
            self:drop(c)
        end
        if c.state ~= "closed" then keep[#keep + 1] = c end
    end
    self.clients = keep
    if active and self.on_activity then self.on_activity() end
    return active
end

--[[--
The e-reader's address on the local network. A UDP socket "connected" to
an outside address picks the route without sending anything; `popen` reads
`ip`/`ifconfig` when that fails.
]]
function Server.localAddress(socket, popen)
    if socket and socket.udp then
        local u = socket.udp()
        if u then
            local ok = pcall(function() u:setpeername("192.0.2.1", 80) end)
            local ip = ok and u:getsockname()
            u:close()
            if ip and ip ~= "0.0.0.0" and not ip:match("^127%.") then return ip end
        end
    end
    popen = popen or io.popen
    for _i, cmd in ipairs({ "ip -4 addr show 2>/dev/null", "ifconfig 2>/dev/null" }) do
        local p = popen(cmd)
        if p then
            local out = p:read("*a") or ""
            p:close()
            for ip in out:gmatch("inet%s+a?d?d?r?:?(%d+%.%d+%.%d+%.%d+)") do
                if not ip:match("^127%.") then return ip end
            end
        end
    end
end

return Server
