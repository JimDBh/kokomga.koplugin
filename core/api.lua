--[[
    Komga API Connector for KOReader
    Handles communication with your Komga server.
--]]

local http = require("socket.http")
local https = require("ssl.https")
local ltn12 = require("ltn12")
local url_utils = require("socket.url")
local logger = require("logger")

local JSON = require("json")

-- Basic base64 encoding (if no lib is available, usually KOReader plugins use a fallback)
local function encode_base64(data)
    local b = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
    return ((data:gsub('.', function(x) 
        local r, b = '', x:byte()
        for i = 8, 1, -1 do r = r .. (b % 2^i - b % 2^(i-1) > 0 and '1' or '0') end
        return r;
    end) .. '0000'):gsub('%d%d%d?%d?%d?%d?', function(x)
        if (#x < 6) then return '' end
        local c = 0
        for i = 1, 6 do c = c + (x:sub(i,i) == '1' and 2^(6-i) or 0) end
        return b:sub(c+1, c+1)
    end) .. ({ '', '==', '=' })[#data%3+1])
end

local KomgaAPI = {}
KomgaAPI.__index = KomgaAPI

-- Universal HTTP Request Helper (Matching OPDS plugin pattern)
local function perform_request(args)
    local response_body = {}
    local request_params = {
        url = args.url,
        method = args.method or "GET",
        headers = args.headers or {},
        sink = args.sink or ltn12.sink.table(response_body),
        timeout = args.timeout or 10
    }
    
    if args.post_data then
        request_params.source = ltn12.source.string(args.post_data)
        request_params.headers["Content-Length"] = tostring(#args.post_data)
    end
    
    local res, code, headers, status
    if args.url:find("https://") == 1 then
        res, code, headers, status = https.request(request_params)
    else
        res, code, headers, status = http.request(request_params)
    end
    
    logger.dbg("Komga API URL:", args.url)
    logger.dbg("Komga API Request Method:", request_params.method)
    logger.dbg("Komga API Response Code:", code)
    logger.dbg("Komga API Response Status:", status)
    
    if not res then
        logger.err("Komga API Request failed:", tostring(code))
        return nil, code or "Network request failed"
    end
    
    return {
        code = tonumber(code) or code,
        body = not args.sink and table.concat(response_body) or nil,
        headers = headers,
        status = status
    }
end

-- Helper for URI escaping (Using socket.url like OPDS)
local function escape_uri(str)
    return url_utils.escape(str)
end

-- Initialize API details
function KomgaAPI:new(base_url, api_key)
    local o = setmetatable({}, self)
    
    -- Normalize URL
    if type(base_url) == "string" then
        o.base_url = base_url:gsub("/+$", "")
    else
        o.base_url = ""
    end
    o.api_key = api_key
    
    -- Cache for auth header
    o.auth_header = nil
    
    return o
end

-- Create the request headers
function KomgaAPI:get_headers()
    local headers = {
        ["Accept"] = "application/json",
        ["Content-Type"] = "application/json"
    }
    if self.api_key and self.api_key ~= "" then
        headers["X-API-Key"] = self.api_key
    elseif self.auth_header then
        headers["Authorization"] = self.auth_header
    end
    return headers
end

-- Helper to perform a synchronized HTTP request
function KomgaAPI:request(path, method, body_data)
    local url = self.base_url .. path
    local headers = self:get_headers()
    
    local post_data = nil
    if body_data then
        post_data = JSON.encode(body_data)
    end
    
    local res, err = perform_request({
        url = url,
        method = method or "GET",
        headers = headers,
        post_data = post_data,
        timeout = 10,
    })
    
    if not res then 
        logger.warn("KomgaAPI:request error", tostring(err), "URL:", url)
        return nil, err
    end
    
    if res.code < 200 or res.code >= 300 then
        logger.warn("KomgaAPI:request bad status", tostring(res.code), "URL:", url)
        if res.body then logger.dbg("Response body:", string.sub(res.body, 1, 500)) end
        return nil, "Server returned status " .. (res.code or "unknown")
    end
    
    if res.code == 204 then return true end
    
    local parsed, result = pcall(function()
        return JSON.decode(res.body)
    end)
    if not parsed then 
        logger.warn("KomgaAPI:request failed to parse JSON from", url, "error:", tostring(result))
        return nil, "JSON parsing failed: " .. tostring(result)
    end
    return result
end

-- Check server credentials & connect (handles both v1 and v2 API versions)
function KomgaAPI:ping()
    local result, err = self:request("/api/v2/users/me")
    if not result then
        -- Fallback to v1 for older Komga instances
        result, err = self:request("/api/v1/users/me")
    end
    if not result then
        return false, err
    end
    return true, result
end

-- Get all Libraries
function KomgaAPI:get_libraries()
    return self:request("/api/v1/libraries")
end

-- Search books by filename or metadata, optionally filtered by series_id
function KomgaAPI:search_books(filename, series_id)
    local query = "search=" .. escape_uri(filename)
    if series_id then
        query = query .. "&series_id=" .. escape_uri(series_id)
    end
    return self:request("/api/v1/books?" .. query)
end

-- Retrieve user progress for a book
function KomgaAPI:get_read_progress(book_id)
    local book, err = self:request("/api/v1/books/" .. book_id)
    if not book then
        return nil, err
    end
    return book.readProgress
end

-- Update read progress on Komga
-- progress_data is a table with:
--   page: integer (0-indexed or 1-indexed depending on server config, Komga is 1-indexed)
--   completed: boolean
function KomgaAPI:patch_read_progress(book_id, page, completed)
    local payload = {
        page = page,
        completed = completed or false
    }
    return self:request("/api/v1/books/" .. book_id .. "/read-progress", "PATCH", payload)
end

-- Get series, optionally filtered by library
function KomgaAPI:get_series(library_id, page, size)
    local params = {}
    if library_id then table.insert(params, "library_id=" .. escape_uri(library_id)) end
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    local q = #params > 0 and ("?" .. table.concat(params, "&")) or ""
    return self:request("/api/v1/series" .. q)
end

-- Search series by name or query
function KomgaAPI:search_series(query)
    local encoded_query = escape_uri(query)
    return self:request("/api/v1/series?search=" .. encoded_query)
end

function KomgaAPI:get_books_for_series(series_id, filters, page, size)
    local encoded_id = escape_uri(series_id)
    local params = {}
    if filters then
        if filters.read_status then
            if type(filters.read_status) == "table" then
                for _, status in ipairs(filters.read_status) do
                    table.insert(params, "read_status=" .. escape_uri(status))
                end
            else
                table.insert(params, "read_status=" .. escape_uri(filters.read_status))
            end
        end
        if filters.sort then table.insert(params, "sort=" .. escape_uri(filters.sort)) end
    end
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    local query = #params > 0 and ("?" .. table.concat(params, "&")) or ""
    return self:request("/api/v1/series/" .. encoded_id .. "/books" .. query)
end

-- Download raw book file content

function KomgaAPI:get_books(filters, page, size)
    local params = {}
    if filters then
        if filters.read_status then
            if type(filters.read_status) == "table" then
                for _, status in ipairs(filters.read_status) do
                    table.insert(params, "read_status=" .. escape_uri(status))
                end
            else
                table.insert(params, "read_status=" .. escape_uri(filters.read_status))
            end
        end
        if filters.sort then table.insert(params, "sort=" .. escape_uri(filters.sort)) end
    end
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    local query = #params > 0 and ("?" .. table.concat(params, "&")) or ""
    return self:request("/api/v1/books" .. query)
end

function KomgaAPI:get_books_ondeck(page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    local q = #params > 0 and ("?" .. table.concat(params, "&")) or ""
    return self:request("/api/v1/books/ondeck" .. q)
end

function KomgaAPI:get_new_series(page, size)
    local params = {}
    if page then table.insert(params, "page=" .. tostring(page)) end
    if size then table.insert(params, "size=" .. tostring(size)) end
    local q = #params > 0 and ("?" .. table.concat(params, "&")) or ""
    return self:request("/api/v1/series/new" .. q)
end

-- Get the next book in the series after book_id (404 = no next book → returns nil)
function KomgaAPI:get_next_book(book_id)
    return self:request("/api/v1/books/" .. escape_uri(book_id) .. "/next")
end

function KomgaAPI:download_book(book_id, dest_filepath)
    local url = self.base_url .. "/api/v1/books/" .. book_id .. "/file"
    local headers = self:get_headers()
    headers["Accept"] = nil
    
    local file, err
    local sink_func = nil
    if dest_filepath then
        file, err = io.open(dest_filepath, "wb")
        if not file then
            return nil, "Failed to open file for writing: " .. tostring(err)
        end
        sink_func = ltn12.sink.file(file)
    end
    
    local res, req_err = perform_request({
        url = url,
        method = "GET",
        headers = headers,
        sink = sink_func,
        timeout = 120,
    })
    
    if file then
        pcall(file.close, file)
    end
    
    if not res then 
        logger.err("KomgaAPI:download_book request failed", tostring(req_err), "URL:", url)
        if dest_filepath then os.remove(dest_filepath) end
        return nil, req_err 
    end
    if res.code < 200 or res.code >= 300 then
        logger.err("KomgaAPI:download_book bad status", tostring(res.code), "URL:", url)
        if dest_filepath then os.remove(dest_filepath) end
        return nil, "Server error " .. res.code
    end
    return dest_filepath and true or res.body
end

-- Helper for downloading images without JSON Accept headers
function KomgaAPI:download_image(path)
    local url = self.base_url .. path
    local headers = self:get_headers()
    headers["Accept"] = "image/jpeg, image/png, image/*"
    headers["Content-Type"] = nil
    
    local res, err = perform_request({
        url = url,
        method = "GET",
        headers = headers,
        timeout = 10,
    })
    
    if not res or res.code < 200 or res.code >= 300 then
        return nil, "Failed to download image"
    end
    
    return res.body
end

-- Download raw series thumbnail/poster
function KomgaAPI:download_series_thumbnail(series_id)
    return self:download_image("/api/v1/series/" .. escape_uri(series_id) .. "/thumbnail")
end

-- Download raw book thumbnail
function KomgaAPI:download_book_thumbnail(book_id)
    return self:download_image("/api/v1/books/" .. escape_uri(book_id) .. "/thumbnail")
end

function KomgaAPI:set_basic_auth(username, password)
    if username and password then
        local creds = username .. ":" .. password
        self.auth_header = "Basic " .. encode_base64(creds)
    else
        self.auth_header = nil
    end
end

function KomgaAPI:generate_api_key(comment)
    local payload = {
        comment = comment or "KOReader Client"
    }
    return self:request("/api/v2/users/me/api-keys", "POST", payload)
end

return KomgaAPI
