-- Sending books over Wi-Fi: the HTTP pieces, the upload server on a fake
-- network, and the transfer screen.
local H = require("helper")
local test, eq, truthy = H.it, H.eq, H.truthy
local Http = require("sereno/transfer/http")
local Server = require("sereno/transfer/server")
local TransferLayout = require("sereno/transfer/layout")
local Theme = require("sereno/ui/theme")
local Layout = require("sereno/home/layout")

H.describe("send over Wi-Fi")

test("request heads, names and responses", function()
    local r = Http.parseHead("PUT /upload?name=Moby%20Dick.epub&code=1234 HTTP/1.1\r\nHost: x\r\nContent-Length: 42")
    eq(r.method, "PUT")
    eq(r.path, "/upload")
    eq(r.params.name, "Moby Dick.epub")
    eq(r.params.code, "1234")
    eq(r.length, 42)
    eq(Http.parseHead("garbage"), nil)
    eq(Http.safeName("Emma.EPUB"), "Emma.EPUB")
    eq(Http.safeName("../../etc/passwd.epub"), "passwd.epub", "no folders")
    eq(Http.safeName("C:\\Users\\me\\Book.pdf"), "Book.pdf")
    eq(select(2, Http.safeName("notes.exe")), "type")
    eq(select(2, Http.safeName(".hidden.epub")), "name")
    eq(select(2, Http.safeName("")), "name")
    local taken = { ["Emma.epub"] = true, ["Emma (2).epub"] = true }
    eq(Http.uniqueName("Emma.epub", function(n) return taken[n] end), "Emma (3).epub")
    local resp = Http.response(200, "hi", "text/plain")
    truthy(resp:find("^HTTP/1.1 200 OK\r\n"), resp)
    truthy(resp:find("Content%-Length: 2\r\n"), resp)
    truthy(resp:find("\r\n\r\nhi$"), resp)
    eq(Http.json({ ok = true, name = 'a "b"' }), '{"name":"a \\u0022b\\u0022","ok":true}')
    local page = Http.page("Kindle 100%", { title = "Enviar libros", wrong_code = "It's wrong" })
    truthy(page:find("<title>Sereno · Enviar libros</title>", 1, true), "translated")
    truthy(page:find("Kindle 100", 1, true), "device name with a percent sign")
    truthy(not page:find("%TITLE%", 1, true) and not page:find("%DONE%", 1, true), "every placeholder filled")
    truthy(page:find("Its wrong", 1, true), "quotes removed so the script stays valid")
end)

-- A fake LuaSocket: the test feeds bytes in, in pieces, like a real network.
local function fakeNet()
    local net = { pending = {}, bound = {} }
    local function client(chunks)
        local c = { chunks = chunks, i = 1, buf = "", out = "", closed = false, peer_closed = false }
        local function fill()
            -- one chunk arrives per receive call, so data comes in pieces
            if c.i <= #c.chunks then
                c.buf = c.buf .. c.chunks[c.i]
                c.i = c.i + 1
            end
        end
        function c:settimeout() end
        function c:receive(pat)
            fill()
            if pat == "*l" then
                local line, rest = self.buf:match("^(.-)\n(.*)$")
                if line then
                    self.buf = rest
                    return (line:gsub("\r$", ""))
                end
                local partial = self.buf
                self.buf = ""
                if self.i > #self.chunks and self.peer_closed then return nil, "closed", partial end
                return nil, "timeout", partial
            end
            local n = pat
            if #self.buf >= n then
                local data = self.buf:sub(1, n)
                self.buf = self.buf:sub(n + 1)
                return data
            end
            local partial = self.buf
            self.buf = ""
            if self.i > #self.chunks and self.peer_closed then return nil, "closed", partial end
            return nil, "timeout", partial
        end
        function c:send(data, i)
            -- at most 1000 bytes per call
            local last = math.min(#data, i + 999)
            self.out = self.out .. data:sub(i, last)
            return last
        end
        function c:close() self.closed = true end
        return c
    end
    net.client = client
    net.socket = {
        bind = function(host, port)
            if net.busy_port == port then return nil, "address already in use" end
            local l = { port = port, closed = false }
            function l:settimeout() end
            function l:accept() return table.remove(net.pending, 1) end
            function l:close() self.closed = true end
            net.bound[#net.bound + 1] = l
            return l
        end,
    }
    function net:connect(chunks)
        local c = client(chunks)
        self.pending[#self.pending + 1] = c
        return c
    end
    return net
end

local function fakeFiles()
    local fs = { files = {} }
    fs.open = function(path)
        local f = { data = {} }
        function f:write(s) self.data[#self.data + 1] = s return self end
        function f:close() fs.files[path] = table.concat(self.data) end
        return f
    end
    fs.rename = function(a, b)
        if not fs.files[a] then return nil end
        fs.files[b], fs.files[a] = fs.files[a], nil
        return true
    end
    fs.remove = function(p) fs.files[p] = nil return true end
    fs.exists = function(p) return fs.files[p] ~= nil end
    return fs
end

local function run(server, n)
    for _i = 1, n or 200 do server:step() end
end

local function upload(name, code, body, pieces)
    local head = string.format("PUT /upload?name=%s&code=%s HTTP/1.1\r\nHost: kindle\r\nContent-Length: %d\r\n\r\n", name, code, #body)
    local chunks = { head:sub(1, 20), head:sub(21) }
    local size = math.ceil(#body / (pieces or 3))
    for i = 1, #body, size do chunks[#chunks + 1] = body:sub(i, i + size - 1) end
    return chunks
end

test("a book arrives in pieces, is written whole and renamed", function()
    local net, fs = fakeNet(), fakeFiles()
    local got = {}
    local s = Server.new{ socket = net.socket, dir = "/mnt/us/documents/", code = "4821", page = "<html>",
        open = fs.open, rename = fs.rename, remove = fs.remove, exists = fs.exists,
        on_file = function(name, path, bytes) got[#got + 1] = { name, path, bytes } end }
    truthy(s:start())
    eq(s.port, Server.PORT)
    local body = string.rep("PK\3\4 epub bytes ", 5000)
    local c = net:connect(upload("Emma.epub", "4821", body, 7))
    run(s)
    truthy(c.out:find("^HTTP/1.1 200"), c.out)
    eq(fs.files["/mnt/us/documents/Emma.epub"], body, "the whole book")
    eq(fs.files["/mnt/us/documents/Emma.epub.part"], nil, "no .part left")
    eq(got[1][1], "Emma.epub")
    eq(got[1][3], #body)
    truthy(c.closed, "connection closed after the reply")
    -- the same name again: kept, not overwritten
    net:connect(upload("Emma.epub", "4821", "second"))
    run(s)
    eq(fs.files["/mnt/us/documents/Emma (2).epub"], "second")
    eq(#s.received, 2)
    s:stop()
    truthy(net.bound[1].closed)
end)

test("wrong code, wrong type, too big and a cut connection are refused", function()
    local net, fs = fakeNet(), fakeFiles()
    local s = Server.new{ socket = net.socket, dir = "/books", code = "4821", page = "<html>", max_bytes = 1000,
        words = { wrong_code = "Código incorrecto" },
        open = fs.open, rename = fs.rename, remove = fs.remove, exists = fs.exists }
    s:start()
    local bad = net:connect(upload("Emma.epub", "0000", "x"))
    local exe = net:connect(upload("virus.exe", "4821", "x"))
    local big = net:connect(upload("Big.pdf", "4821", string.rep("x", 1001)))
    run(s)
    truthy(bad.out:find("^HTTP/1.1 403"), bad.out)
    truthy(bad.out:find("Código incorrecto", 1, true), "the error in the reader's language")
    truthy(exe.out:find("^HTTP/1.1 415"), exe.out)
    truthy(big.out:find("^HTTP/1.1 413"), big.out)
    -- the browser goes away halfway through
    local chunks = upload("Half.epub", "4821", string.rep("y", 600), 3)
    table.remove(chunks)
    local cut = net:connect(chunks)
    cut.peer_closed = true
    run(s)
    eq(fs.files["/books/Half.epub"], nil, "nothing half-written in the library")
    eq(fs.files["/books/Half.epub.part"], nil, "and the .part is removed")
    eq(next(fs.files), nil, "no files at all")
    s:stop()
end)

test("the page and the code check", function()
    local net, fs = fakeNet(), fakeFiles()
    local page = string.rep("<p>page</p>", 400)
    local s = Server.new{ socket = net.socket, dir = "/books", code = "4821", page = page,
        open = fs.open, rename = fs.rename, remove = fs.remove, exists = fs.exists }
    s:start()
    local get = net:connect({ "GET / HTTP/1.1\r\nHost: k\r\n\r\n" })
    local ok = net:connect({ "GET /check?code=4821 HTTP/1.1\r\n\r\n" })
    local no = net:connect({ "GET /check?code=1 HTTP/1.1\r\n\r\n" })
    local missing = net:connect({ "GET /favicon.ico HTTP/1.1\r\n\r\n" })
    run(s)
    truthy(get.out:find("^HTTP/1.1 200") and get.out:find("text/html", 1, true), get.out:sub(1, 80))
    truthy(get.out:sub(-#page) == page, "the whole page, sent in several pieces")
    truthy(ok.out:find("^HTTP/1.1 200"), ok.out)
    truthy(no.out:find("^HTTP/1.1 403"), no.out)
    truthy(missing.out:find("^HTTP/1.1 404"), missing.out)
    s:stop()
end)

test("a taken port is reported; the address comes from the route or ip", function()
    local net = fakeNet()
    net.busy_port = Server.PORT
    local s = Server.new{ socket = net.socket, dir = "/books", code = "1" }
    local ok, err = s:start()
    eq(ok, nil)
    eq(err, "address already in use")
    truthy(s:start(Server.PORT + 1))
    s:stop()
    local udp = { udp = function()
        return { setpeername = function() end, getsockname = function() return "192.168.1.23", 5000 end, close = function() end }
    end }
    eq(Server.localAddress(udp), "192.168.1.23")
    local no_route = { udp = function()
        return { setpeername = function() error("no route") end, getsockname = function() return "0.0.0.0" end, close = function() end }
    end }
    local popen = function(cmd)
        local out = cmd:find("^ip") and "1: lo\n    inet 127.0.0.1/8 scope host lo\n3: wlan0\n    inet 10.0.0.7/24 brd 10.0.0.255" or ""
        return { read = function() return out end, close = function() end }
    end
    eq(Server.localAddress(no_route, popen), "10.0.0.7")
    local ifconfig = function(cmd)
        local out = cmd:find("^ifconfig") and "wlan0 Link encap:Ethernet\n inet addr:192.168.0.40  Bcast:192.168.0.255" or ""
        return { read = function() return out end, close = function() end }
    end
    eq(Server.localAddress(no_route, ifconfig), "192.168.0.40", "BusyBox ifconfig on a Kindle")
    local code = Server.newCode()
    truthy(code:match("^[1-9]%d%d%d$"), code)
end)

test("the transfer screen fits every screen", function()
    local copy = {
        title = "Send books over Wi-Fi", connecting = "Connecting to Wi-Fi…",
        open = "On a computer or phone on the same Wi-Fi, open this address in a browser:",
        code = "Then type this code:", keep = "Keep this screen open while books are sending. The reader stays awake until you tap Stop.",
        received = "Received", nothing_yet = "Nothing yet. Books you send appear here and in the Library.",
        receiving = "receiving…", stop = "Stop",
    }
    local received = {}
    for i = 1, 30 do received[i] = { name = "A fairly long book title number " .. i .. ".epub", bytes = i * 300000 } end
    for _i, scr in ipairs({ { 600, 800, 167 }, { 1072, 1448, 300 }, { 1860, 2480, 300 }, { 1448, 1072, 300 } }) do
        local t = Theme.new{ width = scr[1], height = scr[2], dpi = scr[3] }
        for _j, state in ipairs({
            { phase = "connecting" },
            { phase = "error", message = "Couldn't find this reader's address on the network." },
            { phase = "running", url = "http://192.168.100.123:8181", code = "4821", received = {} },
            { phase = "running", url = "http://192.168.100.123:8181", code = "4821", received = received, receiving = true },
        }) do
            local nodes = TransferLayout.layout(t, state, copy)
            local problems = Layout.check(t, nodes)
            eq(#problems, 0, scr[1] .. "x" .. scr[2] .. " " .. state.phase .. ": " .. table.concat(problems, "; "))
            local stop
            for _k, n in ipairs(nodes) do if n.kind == "tap" and n.action.type == "close" then stop = n end end
            truthy(stop, "a Stop button")
        end
    end
    eq(TransferLayout.size(2516582), "2.4 MB")
    eq(TransferLayout.size(830 * 1024), "830 KB")
end)
