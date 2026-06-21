--[[
    Komga Metadata Cache & File Helpers
    Handles persistent offline storage of library structures and cover art.
--]]

local logger = require("logger")

local KomgaCache = {}

local function sanitize_for_settings(val)
    if type(val) == "table" then
        local res = {}
        for k, v in pairs(val) do
            if type(k) == "string" or type(k) == "number" then
                local s_v = sanitize_for_settings(v)
                if s_v ~= nil then
                    res[k] = s_v
                end
            end
        end
        return res
    elseif type(val) == "string" or type(val) == "number" or type(val) == "boolean" then
        return val
    end
    return nil
end

function KomgaCache:new(plugin)
    local o = { plugin = plugin }
    return setmetatable(o, { __index = self })
end

-- Helper to recursively create a directory structure
function KomgaCache:mkdir_rec(path)
    local logger = require("logger")
    logger.dbg("KomgaCache:mkdir_rec called with path:", path)
    local lfs = require("libs/libkoreader-lfs")
    
    local accum = ""
    if path:sub(1,1) == "/" then
        accum = "/"
        path = path:sub(2)
    end
    
    for segment in path:gmatch("[^/]+") do
        accum = accum .. segment .. "/"
        local ok, err = lfs.mkdir(accum)
        logger.dbg("KomgaCache:mkdir_rec creating", accum, "ok:", ok, "err:", err)
    end
end

-- Helper to write binary files safely using Lua I/O
function KomgaCache:write_file(filepath, content)
    local f = io.open(filepath, "wb")
    if f then
        f:write(content)
        f:close()
        return true
    end
    return false
end

-- Ensures offline metadata tables are nested and structured safely
function KomgaCache:ensureStructure()
    if not self.plugin.settings.library_metadata_cache then
        self.plugin.settings.library_metadata_cache = {}
    end
    local cache = self.plugin.settings.library_metadata_cache
    if not cache.series then cache.series = {} end
    if not cache.series_time then cache.series_time = {} end
    if not cache.books then cache.books = {} end
    if not cache.books_time then cache.books_time = {} end
    if not cache.covers then cache.covers = {} end
    cache.libraries_time = cache.libraries_time or 0
end

function KomgaCache:clear()
    self.plugin.settings.library_metadata_cache = {}
    self:ensureStructure()
    self.plugin:saveSettings()
    logger.info("[Komga Cache] Cleared metadata cache")
end

-- Retrieves libraries list, querying either cache or remote api depending on conditions
function KomgaCache:getLibraries()
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    
    local use_cache = false
    if self.plugin.settings.cache_expiry_policy ~= "always_refresh" and cache.libraries then
        if self.plugin.settings.cache_expiry_policy == "manual" then
            use_cache = true
        elseif self.plugin.settings.cache_expiry_policy == "smart" then
            local age = os.time() - (cache.libraries_time or 0)
            if age < (self.plugin.settings.cache_expiry_mins or 60) * 60 then
                use_cache = true
            end
        end
    end
    
    if use_cache then
        logger.info("[Komga Cache] Sourced libraries from local cache")
        return cache.libraries
    end
    
    logger.info("[Komga Cache] Sourced libraries from remote API")
    local libs, err = self.plugin.api:get_libraries()
    if libs then
        cache.libraries = sanitize_for_settings(libs)
        cache.libraries_time = os.time()
        self.plugin:saveSettings()
    end
    return libs, err
end

-- Retrieves series list by library ID, supporting policy-based caching
function KomgaCache:getSeries(library_id)
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    
    local use_cache = false
    if self.plugin.settings.cache_expiry_policy ~= "always_refresh" and cache.series[library_id] then
        if self.plugin.settings.cache_expiry_policy == "manual" then
            use_cache = true
        elseif self.plugin.settings.cache_expiry_policy == "smart" then
            local age = os.time() - (cache.series_time[library_id] or 0)
            if age < (self.plugin.settings.cache_expiry_mins or 60) * 60 then
                use_cache = true
            end
        end
    end
    
    if use_cache then
        logger.info("[Komga Cache] Sourced series from local cache for library: " .. library_id)
        return cache.series[library_id]
    end
    
    logger.info("[Komga Cache] Sourced series from remote API for library: " .. library_id)
    local series_page, err = self.plugin.api:get_series(library_id)
    if series_page then
        cache.series[library_id] = sanitize_for_settings(series_page)
        cache.series_time[library_id] = os.time()
        
        -- Download/precache thumbnails if option is selected
        if self.plugin.settings.cache_covers and series_page.content then
            self:prefetchCovers(series_page.content, "series")
        end
        
        self.plugin:saveSettings()
    end
    return series_page, err
end

-- Retrieves books list inside a series, returning from disk cache where policy allows
function KomgaCache:getBooks(series_id)
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    
    local use_cache = false
    if self.plugin.settings.cache_expiry_policy ~= "always_refresh" and cache.books[series_id] then
        if self.plugin.settings.cache_expiry_policy == "manual" then
            use_cache = true
        elseif self.plugin.settings.cache_expiry_policy == "smart" then
            local age = os.time() - (cache.books_time[series_id] or 0)
            if age < (self.plugin.settings.cache_expiry_mins or 60) * 60 then
                use_cache = true
            end
        end
    end
    
    if use_cache then
        logger.info("[Komga Cache] Sourced books from local cache for series: " .. series_id)
        return cache.books[series_id]
    end
    
    logger.info("[Komga Cache] Sourced books from remote API for series: " .. series_id)
    local books_page, err = self.plugin.api:get_books_for_series(series_id)
    if books_page then
        cache.books[series_id] = sanitize_for_settings(books_page)
        cache.books_time[series_id] = os.time()
        
        -- Download/precache thumbnails if option is selected
        if self.plugin.settings.cache_covers and books_page.content then
            self:prefetchCovers(books_page.content, "book")
        end
        
        self.plugin:saveSettings()
    end
    return books_page, err
end

-- Downloads and maintains dynamic offline cover art inside downloads directory
function KomgaCache:cacheThumbnail(type_label, id, lastModifiedString, force)
    if not force and not self.plugin.settings.cache_covers then return nil end
    
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    local cache_key = type_label .. "_" .. id
    
    local DataStorage = require("datastorage")
    local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
    self:mkdir_rec(covers_dir)
    
    local local_path = covers_dir .. "/" .. cache_key .. ".jpg"
    
    -- Check if file already exists AND lastModified hasn't changed
    local file_exists = false
    local f_test = io.open(local_path, "rb")
    if f_test then
        file_exists = true
        f_test:close()
    end
    
    if file_exists then
        if self.plugin.settings.never_update_covers or cache.covers[cache_key] == lastModifiedString then
            return local_path
        end
    end
    
    logger.info("[Komga Cache] Fetching and caching cover: " .. cache_key)
    local img_data = nil
    if type_label == "series" then
        img_data = self.plugin.api:download_series_thumbnail(id)
    else
        img_data = self.plugin.api:download_book_thumbnail(id)
    end
    
    if img_data and type(img_data) == "string" and #img_data > 0 then
        local ok = self:write_file(local_path, img_data)
        if ok then
            cache.covers[cache_key] = lastModifiedString
            self.plugin:saveSettings()
            return local_path
        end
    end
    return nil
end

-- Pre-flights a list of items to count missing covers, then downloads them sequentially with a UI blocker
function KomgaCache:prefetchCovers(item_list, type_label)
    if not item_list or #item_list == 0 then return end
    
    local UIManager = require("ui/uimanager")
    local InfoMessage = require("ui/widget/infomessage")
    
    self:ensureStructure()
    local cache = self.plugin.settings.library_metadata_cache
    local DataStorage = require("datastorage")
    local covers_dir = DataStorage:getDataDir() .. "/komga_covers"
    
    local to_download = {}
    for _, item in ipairs(item_list) do
        local cache_key = type_label .. "_" .. item.id
        local local_path = covers_dir .. "/" .. cache_key .. ".jpg"
        
        local file_exists = false
        local f = io.open(local_path, "rb")
        if f then file_exists = true; f:close() end
        
        local needs_download = true
        if file_exists then
            if self.plugin.settings.never_update_covers or cache.covers[cache_key] == item.lastModified then
                needs_download = false
            end
        end
        
        if needs_download then
            table.insert(to_download, item)
        end
    end
    
    if #to_download == 0 then return end
    
    logger.info("[Komga Cache] Pre-fetching " .. #to_download .. " covers for " .. type_label)
    local message = InfoMessage:new{ text = "Downloading " .. #to_download .. " new covers..." }
    UIManager:show(message)
    UIManager:forceRePaint()
    
    for _, item in ipairs(to_download) do
        self:cacheThumbnail(type_label, item.id, item.lastModified, true)
    end
    
    UIManager:close(message)
end

return KomgaCache
