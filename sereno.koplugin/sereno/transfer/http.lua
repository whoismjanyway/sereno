--[[--
The upload page's HTTP side, pure Lua: parsing a request head, checking
an uploaded file's name, the page itself, and responses. The socket work
is in sereno/transfer/server.lua.
]]

local Http = {}

-- what KOReader opens; anything else is refused
Http.EXTENSIONS = {
    epub = true, pdf = true, mobi = true, azw = true, azw3 = true, fb2 = true, cbz = true, cbr = true,
    djvu = true, txt = true, html = true, htm = true, rtf = true, docx = true, chm = true, xps = true, zip = true,
}
Http.MAX_BYTES = 500 * 1024 * 1024

local function unescape(s)
    s = s:gsub("+", " ")
    return (s:gsub("%%(%x%x)", function(h) return string.char(tonumber(h, 16)) end))
end

--- Parses "METHOD /path?query HTTP/1.1\r\nHeader: v\r\n..." (without the final blank line).
function Http.parseHead(head)
    local first, rest = head:match("^([^\r\n]*)\r?\n?(.*)$")
    local method, target = (first or ""):match("^(%u+)%s+(%S+)")
    if not method then return nil end
    local path, query = target:match("^([^?]*)%??(.*)$")
    local params = {}
    for k, v in (query or ""):gmatch("([^&=]+)=?([^&]*)") do params[unescape(k)] = unescape(v) end
    local headers = {}
    for k, v in (rest or ""):gmatch("([^:\r\n]+):%s*([^\r\n]*)") do headers[k:lower()] = v end
    return { method = method, path = path, params = params, headers = headers,
        length = tonumber(headers["content-length"] or "") }
end

--[[--
A safe file name for an upload, or nil and a reason: no folders, no
hidden files, a known e-book extension.
]]
function Http.safeName(name)
    if type(name) ~= "string" then return nil, "name" end
    name = name:gsub("\\", "/"):match("([^/]*)$") or ""
    name = name:gsub("[%c<>:\"|?*]", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" or name:sub(1, 1) == "." or #name > 200 then return nil, "name" end
    local ext = name:match("%.([%w]+)$")
    if not ext or not Http.EXTENSIONS[ext:lower()] then return nil, "type" end
    return name
end

--- "book.epub", "book (2).epub", ... the first that `exists` says is free.
function Http.uniqueName(name, exists)
    if not exists(name) then return name end
    local stem, ext = name:match("^(.*)(%.[^.]+)$")
    for i = 2, 999 do
        local candidate = string.format("%s (%d)%s", stem, i, ext)
        if not exists(candidate) then return candidate end
    end
end

local REASONS = { [200] = "OK", [400] = "Bad Request", [403] = "Forbidden", [404] = "Not Found",
    [413] = "Payload Too Large", [415] = "Unsupported Media Type", [500] = "Internal Server Error" }

function Http.response(status, body, content_type)
    body = body or ""
    return table.concat({
        string.format("HTTP/1.1 %d %s", status, REASONS[status] or ""),
        "Content-Type: " .. (content_type or "application/json; charset=utf-8"),
        "Content-Length: " .. #body,
        "Cache-Control: no-store",
        "Connection: close",
        "", body,
    }, "\r\n")
end

local function jsonString(s)
    return '"' .. tostring(s):gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
end

function Http.json(t)
    local parts = {}
    for k, v in pairs(t) do
        local value = type(v) == "string" and jsonString(v) or tostring(v)
        parts[#parts + 1] = jsonString(k) .. ":" .. value
    end
    table.sort(parts)
    return "{" .. table.concat(parts, ",") .. "}"
end

--[[--
The page a browser gets: pick or drop books, type the code shown on the
e-reader, and each file is sent with its progress. No outside resources.
]]
function Http.page(device_name, words)
    words = words or {}
    -- plain text only, safe inside HTML and the script's quotes, and as a gsub replacement
    local function clean(s) return (s:gsub("[<>&'\"\\]", ""):gsub("%%", "%%%%")) end
    local function w(key, default) return clean(words[key] or default) end
    local html = ([[<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>Sereno · %TITLE%</title>
<style>
:root{--ink:#1c1c1c;--soft:#666;--line:#d8d6d0;--paper:#faf9f6;--accent:#1c1c1c}
@media (prefers-color-scheme:dark){:root{--ink:#eeece6;--soft:#a5a39d;--line:#3a3936;--paper:#171716;--accent:#eeece6}}
*{box-sizing:border-box}body{margin:0;font:16px/1.5 -apple-system,system-ui,"Segoe UI",sans-serif;background:var(--paper);color:var(--ink)}
main{max-width:560px;margin:0 auto;padding:32px 16px}
h1{font:600 26px/1.2 Georgia,"Noto Serif",serif;margin:0 0 4px}p{margin:0 0 20px;color:var(--soft)}
label{display:block;font-weight:600;margin:0 0 6px}
input[type=text]{font:600 22px/1 ui-monospace,monospace;letter-spacing:.3em;width:8em;padding:10px 12px;border:1px solid var(--line);border-radius:8px;background:transparent;color:var(--ink)}
.drop{margin:24px 0;border:2px dashed var(--line);border-radius:14px;padding:36px 16px;text-align:center;cursor:pointer}
.drop.on{border-color:var(--accent)}.drop b{display:block;font-size:18px;margin-bottom:4px}
ul{list-style:none;padding:0;margin:0}li{border-bottom:1px solid var(--line);padding:10px 0;display:flex;gap:12px;align-items:center}
li span{flex:1;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}li em{font-style:normal;color:var(--soft);font-size:14px}
progress{width:90px}
</style></head><body><main>
<h1>%TITLE%</h1><p>%TO% <strong>%DEVICE%</strong>. %KEEP%</p>
<label for="code">%CODE%</label><input id="code" type="text" inputmode="numeric" maxlength="4" autocomplete="off">
<div class="drop" id="drop"><b>%DROP%</b>%FORMATS%<input id="files" type="file" multiple hidden></div>
<ul id="list"></ul>
</main><script>
const code=document.getElementById('code'),drop=document.getElementById('drop'),input=document.getElementById('files'),list=document.getElementById('list');
code.value=localStorage.getItem('sereno-code')||'';
drop.onclick=()=>input.click();
input.onchange=()=>send([...input.files]);
['dragenter','dragover'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.add('on')}));
['dragleave','drop'].forEach(e=>drop.addEventListener(e,ev=>{ev.preventDefault();drop.classList.remove('on')}));
drop.addEventListener('drop',ev=>send([...ev.dataTransfer.files]));
async function send(files){try{localStorage.setItem('sereno-code',code.value)}catch(e){}
try{const r=await fetch('/check?code='+encodeURIComponent(code.value));if(!r.ok){const j=await r.json().catch(()=>({}));alert(j.error||'%WRONG%');code.focus();return}}catch(e){alert('%LOST%');return}
for(const f of files){const li=document.createElement('li'),name=document.createElement('span'),bar=document.createElement('progress'),state=document.createElement('em');
name.textContent=f.name;bar.max=1;bar.value=0;li.append(name,bar,state);list.prepend(li);
await new Promise(done=>{const x=new XMLHttpRequest();x.open('PUT','/upload?name='+encodeURIComponent(f.name)+'&code='+encodeURIComponent(code.value));
x.upload.onprogress=e=>{if(e.lengthComputable)bar.value=e.loaded/e.total};
x.onload=()=>{let r={};try{r=JSON.parse(x.responseText)}catch(e){}bar.remove();state.textContent=x.status==200?'%DONE%':(r.error||('Error '+x.status));done()};
x.onerror=()=>{bar.remove();state.textContent='%LOST%';done()};x.send(f)});}}
</script></body></html>]])
        :gsub("%%TITLE%%", w("title", "Send books"))
        :gsub("%%TO%%", w("to", "Books go to"))
        :gsub("%%DEVICE%%", clean(device_name or "your e-reader"))
        :gsub("%%KEEP%%", w("keep", "Keep this screen open on the e-reader while sending."))
        :gsub("%%CODE%%", w("code", "Code shown on the e-reader"))
        :gsub("%%DROP%%", w("drop", "Drop books here, or click to choose"))
        :gsub("%%FORMATS%%", w("formats", "EPUB, PDF, MOBI, AZW3, FB2, CBZ, DjVu, TXT…"))
        :gsub("%%DONE%%", w("done", "Sent ✓"))
        :gsub("%%LOST%%", w("lost", "Connection lost"))
        :gsub("%%WRONG%%", w("wrong_code", "Wrong code. Check the code on the e-reader."))
    return html
end

return Http
