local DataStorage = require("datastorage")
local Storage = require("memobook_storage_sqlite")
local DocumentContext = require("memobook_document_context")
local ffiUtil = require("ffi/util")
local util = require("util")
local logger = require("logger")
local _ = require("gettext")

local MemoManager = {}
MemoManager.__index = MemoManager

local EXPORT_DIR = ffiUtil.joinPath(DataStorage:getDataDir(), "memobook")
local GLOBAL_CONTEXT = {
    identity = "__MEMOBOOK_GLOBAL__",
    identity_type = "virtual",
    display_name = _ and _("All memos") or "All memos",
}

local function prepareText(value)
    if type(value) ~= "string" then
        return nil, nil
    end
    local trimmed = util.trim(value)
    if trimmed == "" then
        return nil, nil
    end
    local lower = util.lower and util.lower(trimmed) or trimmed:lower()
    return trimmed, lower
end

local function sanitizeFilename(name)
    if not name or name == "" then
        return "memobook"
    end
    local sanitized = name
        :gsub("[\\/:%*%?\"<>|]", " ")
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s+$", "")
        :gsub("%s", "_")
        :gsub("[^%w%._%-]", "_")
    if sanitized == "" then
        sanitized = "memobook"
    end
    return sanitized
end

local function cloneNotes(notes)
    local result = {}
    for index, note in ipairs(notes) do
        result[index] = {
            id = note.id,
            text = note.text or "",
            created_at = note.created_at,
            updated_at = note.updated_at,
        }
    end
    return result
end

local ReaderUI
local ok_reader, reader_module = pcall(require, "apps/reader/readerui")
if ok_reader then
    ReaderUI = reader_module
end

local function cloneAliases(entries)
    local result = {}
    for index, entry in ipairs(entries) do
        result[index] = entry.alias
    end
    return result
end

function MemoManager:new(ui)
    local manager = {
        ui = ui,
        last_ui = ui,
    }
    return setmetatable(manager, self)
end

function MemoManager:setUI(ui)
    self.ui = ui
    if ui then
        self.last_ui = ui
    end
end

function MemoManager:getActiveDocumentContext()
    local current_ui = self.ui or self.last_ui
    if not current_ui and ReaderUI and ReaderUI.instance then
        current_ui = ReaderUI.instance
        self.last_ui = current_ui
    end
    if not current_ui then
        return nil
    end
    return DocumentContext.fromUI(current_ui)
end

function MemoManager:save()
    -- no-op retained for API compatibility
end

function MemoManager:reset()
    Storage.reset()
end

function MemoManager:_resolveDocument(opts)
    opts = opts or {}
    if opts.document_id then
        local doc = Storage.getDocumentById(opts.document_id)
        if doc then
            return doc, nil
        end
    end

    local context = opts.context
    if not context and self.ui then
        context = DocumentContext.fromUI(self.ui)
    end
    if not context or not context.identity or context.identity == "" then
        context = GLOBAL_CONTEXT
    end

    if opts.create then
        local doc = Storage.getOrCreateDocument(context)
        return doc, context
    end

    local doc = Storage.findDocument(context.identity, context.identity_type or "path")
    if doc then
        return doc, context
    end
    if opts.create_if_missing then
        doc = Storage.getOrCreateDocument(context)
        return doc, context
    end
    return nil, context
end

function MemoManager:_expandGroup(doc, record)
    if not record then
        return nil
    end
    local aliases = cloneAliases(Storage.listAliases(record.id))
    local notes = cloneNotes(Storage.getNotes(record.id))
    return {
        id = record.id,
        document_id = doc.id,
        document_identity = doc.identity,
        document_identity_type = doc.identity_type,
        document_display_name = doc.display_name,
        primary_tag = record.primary_tag,
        normalized_tag = record.normalized_tag,
        multi_note_mode = record.multi_note_mode,
        aliases = aliases,
        notes = notes,
    }
end

function MemoManager:_getGroup(doc, normalized_tag)
    if not doc or not normalized_tag then
        return nil
    end
    local record = Storage.getGroup(doc.id, normalized_tag)
    if not record then
        return nil
    end
    return self:_expandGroup(doc, record)
end

function MemoManager:_ensureGroup(doc, display_tag, normalized_tag)
    if not doc or not normalized_tag then
        return nil
    end
    local record = Storage.ensureGroup(doc.id, display_tag, normalized_tag)
    return self:_expandGroup(doc, record)
end

function MemoManager:getGroupForTag(tag, opts)
    local display_tag, normalized = prepareText(tag)
    if not normalized then
        return nil
    end
    local doc = self:_resolveDocument(opts or {})
    if not doc then
        return nil
    end
    return self:_getGroup(doc, normalized)
end

function MemoManager:getOrCreateGroup(tag, opts)
    local display_tag, normalized = prepareText(tag)
    if not normalized then
        logger.warn("memobook: invalid primary tag")
        return nil
    end
    local doc = self:_resolveDocument({
        document_id = opts and opts.document_id,
        context = opts and opts.context,
        create = true,
    })
    if not doc then
        return nil
    end
    return self:_ensureGroup(doc, display_tag, normalized)
end

function MemoManager:addNote(tag, noteText, opts)
    local group = self:getOrCreateGroup(tag, opts)
    if not group then
        return nil
    end
    local notes = Storage.getNotes(group.id)
    local is_first_note = #notes == 0
    Storage.addNote(group.id, noteText or "")
    if is_first_note and opts and opts.initial_alias then
        self:addAlias(tag, opts.initial_alias, opts)
    end
    notes = Storage.getNotes(group.id)
    if #notes > 1 and not group.multi_note_mode then
        Storage.setGroupMultiNoteMode(group.id, true)
    end
    return self:getGroupForTag(tag, opts)
end

function MemoManager:updateSingleNote(tag, noteText, opts)
    local group = self:getOrCreateGroup(tag, opts)
    if not group then
        return nil
    end
    local notes = Storage.getNotes(group.id)
    local text = noteText or ""
    if notes[1] then
        Storage.updateNote(notes[1].id, text)
    else
        Storage.addNote(group.id, text)
    end
    return self:getGroupForTag(tag, opts)
end

function MemoManager:setMultiNoteMode(tag, enabled, opts)
    local group = self:getGroupForTag(tag, opts)
    if not group then
        return
    end
    Storage.setGroupMultiNoteMode(group.id, enabled and true or false)
end

function MemoManager:deleteNote(tag, index, opts)
    local group = self:getGroupForTag(tag, opts)
    if not group then
        return
    end
    local notes = Storage.getNotes(group.id)
    local entry = notes[index]
    if not entry then
        return
    end
    Storage.deleteNote(entry.id)
    local remaining = Storage.getNotes(group.id)
    if #remaining <= 1 then
        Storage.setGroupMultiNoteMode(group.id, false)
    end
end

function MemoManager:listGroups(opts)
    opts = opts or {}
    local doc = nil
    if opts.document_id or opts.context then
        doc = self:_resolveDocument({
            document_id = opts.document_id,
            context = opts.context,
            create_if_missing = true,
        })
    else
        local context = self:getActiveDocumentContext()
        if context then
            doc = self:_resolveDocument({ context = context, create_if_missing = true })
        end
    end

    local target_document_id = doc and doc.id or opts.document_id
    Storage.deleteGroupsWithoutNotes(target_document_id)

    local rows = Storage.listGroups({
        document_id = target_document_id,
        search_text = opts.search_text,
    })

    for _, row in ipairs(rows) do
        row.note_count = row.note_count or 0
        row.alias_count = row.alias_count or 0
        row.document_display_name = row.document_display_name or select(2, DocumentContext.resolve(row.document_identity))
    end

    return rows, doc
end

function MemoManager:removeGroup(tag, opts)
    local group = self:getGroupForTag(tag, opts)
    if not group then
        return false
    end
    Storage.deleteGroup(group.id)
    return true
end

function MemoManager:getNote(tag, index, opts)
    local group = self:getGroupForTag(tag, opts)
    if not group then
        return nil
    end
    return group.notes[index]
end

function MemoManager:updateNote(tag, index, noteText, opts)
    local group = self:getGroupForTag(tag, opts)
    if not group then
        return false
    end
    local notes = Storage.getNotes(group.id)
    local entry = notes[index]
    if not entry then
        return false
    end
    Storage.updateNote(entry.id, noteText or "")
    return true
end

function MemoManager:listAliases(tag, opts)
    local group = self:getGroupForTag(tag, opts)
    if not group then
        return nil, {}
    end
    return group.primary_tag, group.aliases or {}
end

function MemoManager:addAlias(tag, alias, opts)
    local group = self:getOrCreateGroup(tag, opts)
    if not group then
        return false
    end
    local display_alias, normalized = prepareText(alias)
    if not normalized or normalized == group.normalized_tag then
        return false
    end
    if Storage.aliasInUse(group.document_id, normalized) then
        return false
    end
    Storage.addAlias(group.id, display_alias, normalized)
    -- Refresh to ensure subsequent calls see the new alias
    self:getGroupForTag(tag, opts)
    return true
end

function MemoManager:removeAlias(tag, alias, opts)
    local group = self:getGroupForTag(tag, opts)
    if not group then
        return false
    end
    local _, normalized = prepareText(alias)
    if not normalized then
        return false
    end
    Storage.removeAlias(group.id, normalized)
    self:getGroupForTag(tag, opts)
    return true
end

function MemoManager:getDefaultExportPath(opts)
    opts = opts or {}
    local doc = nil
    if opts.document_id or opts.context then
        doc = self:_resolveDocument({
            document_id = opts.document_id,
            context = opts.context,
        })
    else
        local context = self:getActiveDocumentContext()
        if context then
            doc = self:_resolveDocument({ context = context })
        end
    end

    util.makePath(EXPORT_DIR)
    if doc then
        local filename = string.format("memobook_%s.json", sanitizeFilename(doc.display_name or doc.identity))
        return ffiUtil.joinPath(EXPORT_DIR, filename)
    end
    return ffiUtil.joinPath(EXPORT_DIR, "memobook_all.json")
end

function MemoManager:getStorageFilePath(opts)
    return self:getDefaultExportPath(opts)
end

function MemoManager:exportTo(path, opts)
    opts = opts or {}
    local document_id = opts.document_id
    if not document_id and (opts.context or self.ui) then
        local doc = self:_resolveDocument({
            document_id = opts.document_id,
            context = opts.context,
        })
        document_id = doc and doc.id or nil
    end
    return Storage.exportTo(path, { document_id = document_id })
end

return MemoManager
