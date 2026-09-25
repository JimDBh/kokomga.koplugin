--[[
    Komga Book Index
    What kokomga has learned about the Komga books it has met: their series,
    their place in it, and the book that follows each one.

    Lets the end-of-book flow open the next chapter without asking the server --
    offline, as long as the chapter is on the device, and faster online -- and
    lets chapter cleanup order a series' books without a network call.

    Kept in its own settings file, written only by the main process: the
    background pre-download runs in a subprocess and hands its findings back
    instead of writing here, so the two can never overwrite each other.
--]]

local logger = require("logger")

local BookIndex = {}

local store = nil
local function open()
    if not store then
        local DataStorage = require("datastorage")
        local LuaSettings = require("luasettings")
        store = LuaSettings:open(DataStorage:getSettingsDir() .. "/kokomga_book_index.lua")
    end
    return store
end

local function books()
    return open():readSetting("books") or {}
end

local function save(all)
    local s = open()
    s:saveSetting("books", all)
    s:flush()
end

-- KOReader's JSON decoder turns a null into a function sentinel, so keep only
-- values of the type expected.
local function asTable(v) return type(v) == "table" and v or nil end
local function asString(v) return type(v) == "string" and v or nil end
local function asNumber(v) return type(v) == "number" and v or nil end

-- The fields getBookLocalPath and the next-chapter prompt need. Anything that
-- has to write the book's full metadata (a download) fetches the book again.
function BookIndex.trim(book)
    if type(book) ~= "table" or not asString(book.id) then return nil end
    local md = asTable(book.metadata) or {}
    local media = asTable(book.media) or {}
    return {
        id = book.id,
        name = asString(book.name),
        seriesId = asString(book.seriesId),
        seriesTitle = asString(book.seriesTitle),
        oneshot = book.oneshot == true,
        media = { mediaType = asString(media.mediaType) },
        metadata = {
            title = asString(md.title),
            number = asString(md.number) or (asNumber(md.number) and tostring(md.number)) or nil,
            numberSort = asNumber(md.numberSort),
        },
        _trimmed = true,
    }
end

-- Records a book, keeping whatever is already known about what follows it.
function BookIndex.recordBook(book)
    local trimmed = BookIndex.trim(book)
    if not trimmed then return end
    local all = books()
    local previous = all[trimmed.id]
    trimmed.next_id = previous and previous.next_id
    trimmed.next_checked = previous and previous.next_checked
    all[trimmed.id] = trimmed
    save(all)
end

-- Records what follows book_id: next_book, or nil when the server said there
-- is none (the book was the last in its series when checked).
function BookIndex.recordNext(book_id, next_book)
    if type(book_id) ~= "string" then return end
    local all = books()
    local entry = all[book_id] or { id = book_id }
    local trimmed_next = BookIndex.trim(next_book)
    entry.next_id = trimmed_next and trimmed_next.id or false
    entry.next_checked = os.time()
    all[book_id] = entry
    if trimmed_next then
        local known = all[trimmed_next.id]
        trimmed_next.next_id = known and known.next_id
        trimmed_next.next_checked = known and known.next_checked
        all[trimmed_next.id] = trimmed_next
    end
    save(all)
    logger.dbg("KomgaBookIndex: next of", book_id, "is", tostring(entry.next_id))
end

function BookIndex.getBook(book_id)
    local entry = books()[book_id]
    if entry and entry.name then return entry end
end

-- The book after book_id: its record, false when it was last known to have
-- none, or nil when nothing is known.
function BookIndex.getNext(book_id)
    local all = books()
    local entry = all[book_id]
    if not entry or entry.next_id == nil then return nil end
    if entry.next_id == false then return false end
    local next_entry = all[entry.next_id]
    if next_entry and next_entry.name then return next_entry end
    return nil
end

-- Every recorded book of a series, as records.
function BookIndex.booksInSeries(series_id)
    local out = {}
    if type(series_id) ~= "string" then return out end
    for _, entry in pairs(books()) do
        if entry.seriesId == series_id and entry.name then
            out[#out + 1] = entry
        end
    end
    return out
end

return BookIndex
