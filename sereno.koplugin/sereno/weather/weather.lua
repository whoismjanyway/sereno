--[[--
The weather tile's data, from Open-Meteo (open-meteo.com): free, no
account or key. Two requests: finding a town once, and the current
temperature and sky when the home screen shows with Wi-Fi on (at most
every 30 minutes). Sereno never turns Wi-Fi on for it.

Pure Lua: the HTTP getter and the JSON decoder are passed in.
]]

local Weather = {}

Weather.REFRESH_SECS = 30 * 60
-- a reading older than this isn't shown as current
Weather.STALE_SECS = 12 * 60 * 60

local function urlencode(s)
    return (tostring(s):gsub("[^%w%-_%.~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function Weather.searchUrl(name, lang)
    return "https://geocoding-api.open-meteo.com/v1/search?count=1&format=json&language=" .. urlencode(lang or "en")
        .. "&name=" .. urlencode(name)
end

function Weather.forecastUrl(place)
    return string.format("https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f"
        .. "&current=temperature_2m,weather_code&timezone=auto&temperature_unit=%s",
        place.lat, place.lon, place.unit == "F" and "fahrenheit" or "celsius")
end

--- The first match of a town search: { name, lat, lon, country } or nil, reason.
function Weather.parsePlace(data)
    local r = type(data) == "table" and type(data.results) == "table" and data.results[1]
    if not r or not r.latitude or not r.longitude then return nil, "not_found" end
    return { name = r.name, lat = r.latitude, lon = r.longitude, country = r.country, admin = r.admin1 }
end

--- The current reading: { temp, code } or nil.
function Weather.parseCurrent(data)
    local c = type(data) == "table" and data.current
    if type(c) ~= "table" or c.temperature_2m == nil then return nil end
    return { temp = c.temperature_2m, code = c.weather_code or 0 }
end

-- WMO weather codes (open-meteo.com/en/docs) -> symbol and words
local CODES = {
    { 0, 0, "sun", "Clear" },
    { 1, 2, "sun_cloud", "Partly cloudy" },
    { 3, 3, "cloud", "Cloudy" },
    { 45, 48, "fog", "Fog" },
    { 51, 55, "rain", "Drizzle" },
    { 56, 57, "rain", "Freezing drizzle" },
    { 61, 61, "rain", "Light rain" },
    { 63, 63, "rain", "Rain" },
    { 65, 65, "rain", "Heavy rain" },
    { 66, 67, "rain", "Freezing rain" },
    { 71, 75, "snow", "Snow" },
    { 77, 77, "snow", "Snow grains" },
    { 80, 82, "rain", "Showers" },
    { 85, 86, "snow", "Snow showers" },
    { 95, 99, "storm", "Thunderstorm" },
}
Weather.CODES = CODES

function Weather.describe(code)
    for _i, c in ipairs(CODES) do
        if code >= c[1] and code <= c[2] then return c[3], c[4] end
    end
    return "cloud", "Cloudy"
end

--[[--
What the tile shows, from the saved setting
{ name, lat, lon, unit, reading = { temp, code, time } }:
nil (no town yet), { place } (no recent reading), or { place, temp, glyph, text }.
]]
function Weather.display(saved, now, _)
    _ = _ or function(s) return s end
    if type(saved) ~= "table" or not saved.lat then return nil end
    local out = { place = saved.name }
    local r = saved.reading
    if r and r.temp and r.time and (now - r.time) <= Weather.STALE_SECS then
        out.temp = string.format("%d°", math.floor(r.temp + 0.5))
        local glyph, words = Weather.describe(r.code or 0)
        out.glyph, out.text = glyph, _(words)
    end
    return out
end

--- Whether to ask for a new reading now.
function Weather.due(saved, now)
    if type(saved) ~= "table" or not saved.lat then return false end
    local last = math.max(saved.reading and saved.reading.time or 0, saved.tried or 0)
    return now - last >= Weather.REFRESH_SECS
end

--[[--
Fetches the current reading into `saved` (changed in place).
@tparam function get(url) -> body or nil, err
@tparam function decode(json) -> table
@treturn bool, err
]]
function Weather.refresh(saved, now, get, decode)
    saved.tried = now
    local body, err = get(Weather.forecastUrl(saved))
    if not body then return false, err end
    local ok, data = pcall(decode, body)
    local cur = ok and Weather.parseCurrent(data)
    if not cur then return false, "bad_reply" end
    saved.reading = { temp = cur.temp, code = cur.code, time = now }
    return true
end

--- Looks a town up; returns a new saved setting, or nil and a reason.
function Weather.find(name, get, decode, lang, unit)
    local body, err = get(Weather.searchUrl(name, lang))
    if not body then return nil, err end
    local ok, data = pcall(decode, body)
    if not ok then return nil, "bad_reply" end
    local place, why = Weather.parsePlace(data)
    if not place then return nil, why end
    place.unit = unit or "C"
    return place
end

return Weather
