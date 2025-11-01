local DataStorage = require("datastorage")
local ffiUtil = require("ffi/util")
local util = require("util")
local json = require("json")
local logger = require("logger")

local DocumentContext = {}

local CONFIG_FILENAME = "document_map.json"
local CONFIG_DIR = ffiUtil.joinPath(DataStorage:getDataDir(), "memobook")
local CONFIG_PATH = ffiUtil.joinPath(CONFIG_DIR, CONFIG_FILENAME)

local MODULE_SOURCE = debug.getinfo(1, "S").source or ""
if MODULE_SOURCE:sub(1, 1) == "@" then
    MODULE_SOURCE = MODULE_SOURCE:sub(2)
end
local MODULE_DIR = MODULE_SOURCE ~= "" and ffiUtil.dirname(MODULE_SOURCE) or nil
local PLUGIN_CONFIG_PATH = MODULE_DIR and ffiUtil.joinPath(MODULE_DIR, CONFIG_FILENAME) or nil

local mapping_loaded = false
local mapped_sources = {}

local function ensureConfigDir()
    local ok, err = util.makePath(CONFIG_DIR)
    if not ok then
        logger.warn("memobook: unable to ensure config directory", err)
    end
end

local function normalizeMappingEntry(source, entry)
    if type(entry) == "string" then
        return {
            identity = entry,
        }
    end
    if type(entry) ~= "table" then
        return nil
    end
    local identity = entry.identity or entry.target or source
    local display_name = entry.display_name or entry.name
    local resolved = {
        identity = identity,
        display_name = display_name,
    }
    if type(entry.aliases) == "table" then
        for _, alias in ipairs(entry.aliases) do
            if type(alias) == "string" and alias ~= "" then
                mapped_sources[alias] = {
                    identity = identity,
                    display_name = display_name,
                }
            end
        end
    end
    return resolved
end

local function normalizeGroupArray(entry)
    if type(entry) ~= "table" then
        return
    end
    local main_identity
    local aliases = {}
    for index, value in ipairs(entry) do
        if type(value) == "string" and value ~= "" then
            if not main_identity then
                main_identity = value
            else
                table.insert(aliases, value)
            end
        end
    end
    if not main_identity then
        return
    end
    return {
        identity = main_identity,
        aliases = aliases,
    }
end

local function loadConfigTable(path)
    if not path then
        return nil
    end
    local fp = io.open(path, "r")
    if not fp then
        return nil
    end
    local content = fp:read("*a")
    fp:close()
    local ok, decoded = pcall(function()
        return json.decode(content)
    end)
    if not ok or type(decoded) ~= "table" then
        logger.warn(string.format("memobook: unable to parse document map config at %s", path))
        return nil
    end
    return decoded
end

local function applyDecodedMap(decoded)
    if type(decoded) ~= "table" then
        return
    end
    local function registerEntry(source, entry)
        if type(source) ~= "string" or source == "" then
            return
        end
        local resolved = normalizeMappingEntry(source, entry)
        if resolved then
            mapped_sources[source] = resolved
        end
    end

    if decoded[1] then
        for _, entry in ipairs(decoded) do
            local normalized = normalizeGroupArray(entry)
            if normalized then
                local main = normalized.identity
                registerEntry(main, {
                    identity = main,
                    aliases = normalized.aliases,
                })
                for _, alias in ipairs(normalized.aliases or {}) do
                    registerEntry(alias, main)
                end
            end
        end
        return
    end

    local map = decoded
    if type(decoded.groups) == "table" then
        map = decoded.groups
    end
    if map[1] and type(map[1]) == "table" then
        for _, entry in ipairs(map) do
            local normalized = normalizeGroupArray(entry)
            if normalized then
                registerEntry(normalized.identity, normalized.identity)
                for _, alias in ipairs(normalized.aliases or {}) do
                    registerEntry(alias, normalized.identity)
                end
            end
        end
        return
    end
    for source, entry in pairs(map) do
        registerEntry(source, entry)
    end
end

local function loadMapping()
    if mapping_loaded then
        return
    end
    mapping_loaded = true
    ensureConfigDir()

    local sources = {}
    local plugin_decoded = loadConfigTable(PLUGIN_CONFIG_PATH)
    if plugin_decoded then
        table.insert(sources, plugin_decoded)
    end
    local user_decoded = loadConfigTable(CONFIG_PATH)
    if user_decoded then
        table.insert(sources, user_decoded)
    end

    for _, decoded in ipairs(sources) do
        applyDecodedMap(decoded)
    end
end

local function defaultDisplayName(path)
    if not path or path == "" then
        return nil
    end
    local basename = ffiUtil.basename and ffiUtil.basename(path)
    if basename and basename ~= "" then
        return basename
    end
    return path
end

local function resolveIdentity(identity)
    loadMapping()
    if mapped_sources[identity] then
        return mapped_sources[identity]
    end
    return {
        identity = identity,
    }
end

function DocumentContext.fromUI(ui)
    if not ui or not ui.document or not ui.document.file then
        return nil
    end
    local source_identity = ui.document.file
    local resolved = resolveIdentity(source_identity)
    local display_name = resolved.display_name or defaultDisplayName(resolved.identity)
    return {
        identity = resolved.identity,
        identity_type = "path",
        display_name = display_name,
        source_identity = source_identity,
    }
end

function DocumentContext.resolve(identity)
    if not identity or identity == "" then
        return nil
    end
    local resolved = resolveIdentity(identity)
    if resolved.display_name then
        return resolved.identity, resolved.display_name
    end
    return resolved.identity, defaultDisplayName(resolved.identity)
end

function DocumentContext.getConfigPath()
    ensureConfigDir()
    return CONFIG_PATH
end

return DocumentContext
