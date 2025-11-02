---@diagnostic disable: undefined-field

local DataStorage = require("datastorage")
local SQ3 = require("lua-ljsqlite3/init")
local ffiUtil = require("ffi/util")
local util = require("util")
local json = require("json")
local logger = require("logger")

local Storage = {}

local DB_SCHEMA_VERSION = 20241031
local DB_DIRECTORY = ffiUtil.joinPath(DataStorage:getDataDir(), "memobook")
local DB_PATH = ffiUtil.joinPath(DB_DIRECTORY, "memobook.sqlite3")

local SCHEMA_STATEMENTS = {
    "CREATE TABLE IF NOT EXISTS documents (id INTEGER PRIMARY KEY AUTOINCREMENT, identity TEXT NOT NULL, identity_type TEXT NOT NULL DEFAULT 'path', display_name TEXT, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), UNIQUE(identity, identity_type))",
    "CREATE TABLE IF NOT EXISTS groups (id INTEGER PRIMARY KEY AUTOINCREMENT, document_id INTEGER NOT NULL REFERENCES documents(id) ON DELETE CASCADE, primary_tag TEXT NOT NULL, normalized_tag TEXT NOT NULL, multi_note_mode INTEGER NOT NULL DEFAULT 0 CHECK(multi_note_mode IN (0,1)), created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), UNIQUE(document_id, normalized_tag))",
    "CREATE TABLE IF NOT EXISTS aliases (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE, alias TEXT NOT NULL, normalized_alias TEXT NOT NULL, UNIQUE(group_id, normalized_alias))",
    "CREATE TABLE IF NOT EXISTS notes (id INTEGER PRIMARY KEY AUTOINCREMENT, group_id INTEGER NOT NULL REFERENCES groups(id) ON DELETE CASCADE, text TEXT, created_at INTEGER NOT NULL DEFAULT (strftime('%s','now')), updated_at INTEGER NOT NULL DEFAULT (strftime('%s','now')))" ,
    "CREATE INDEX IF NOT EXISTS idx_groups_document ON groups(document_id)",
    "CREATE INDEX IF NOT EXISTS idx_aliases_group ON aliases(group_id)",
    "CREATE INDEX IF NOT EXISTS idx_notes_group ON notes(group_id)",
}

local initialized = false

local function fetchAll(conn, sql, params)
    if params == nil then
        params = {}
    elseif type(params) ~= "table" then
        params = { params }
    end
    local stmt = conn:prepare(sql)
    if #params > 0 then
        stmt:bind(table.unpack(params))
    end
    local result = {}
    local data = stmt:resultset("hik")
    stmt:close()
    if not data then
        return result
    end
    local headers = data[0]
    for row_index = 1, #data[1] do
        local record = {}
        for header_index, header in ipairs(headers) do
            local column_values = data[header_index]
            record[header] = column_values[row_index]
        end
        table.insert(result, record)
    end
    return result
end

local function fetchOne(conn, sql, params)
    local rows = fetchAll(conn, sql, params)
    return rows[1]
end

local function execStatements(conn, statements)
    for _, statement in ipairs(statements) do
        local trimmed = util.trim(statement)
        if trimmed ~= "" then
            local final_stmt = trimmed
            if not final_stmt:find(";%s*$") then
                final_stmt = final_stmt .. ";"
            end
            local ok, err = pcall(conn.exec, conn, final_stmt)
            if not ok then
                error(string.format("memobook sqlite schema error: %s -- %s", final_stmt, err))
            end
        end
    end
end

local function ensureDirectory()
    local dir = DB_DIRECTORY
    local ok, err = util.makePath(dir)
    if not ok then
        logger.warn("memobook: unable to create database directory", err)
    end
end

local function openConnection()
    local conn = SQ3.open(DB_PATH)
    conn:exec("PRAGMA foreign_keys = ON;")
    conn:exec("PRAGMA synchronous = NORMAL;")
    conn:exec("PRAGMA journal_mode = WAL;")
    return conn
end

local function withConnection(fn)
    local conn = openConnection()
    local ok, result, extra = pcall(fn, conn)
    conn:close()
    if not ok then
        error(result)
    end
    return result, extra
end

function Storage.init()
    if initialized then
        return
    end
    ensureDirectory()
    local conn = openConnection()
    local current_version = tonumber(conn:rowexec("PRAGMA user_version;")) or 0
    if current_version < DB_SCHEMA_VERSION then
        -- Drop existing data when schema changes. Old JSON-based data is intentionally discarded.
        conn:exec("PRAGMA writable_schema = ON;")
        conn:exec("DELETE FROM sqlite_master WHERE type IN ('table','index','trigger');")
        conn:exec("PRAGMA writable_schema = OFF;")
        conn:exec("VACUUM;")
        conn:exec("PRAGMA user_version = " .. DB_SCHEMA_VERSION .. ";")
    end
    execStatements(conn, SCHEMA_STATEMENTS)
    conn:close()
    initialized = true
end

local function mapDocumentRow(row)
    if not row then
        return nil
    end
    return {
        id = tonumber(row.id),
        identity = row.identity,
        identity_type = row.identity_type,
        display_name = row.display_name,
    }
end

local function computeDisplayName(identity)
    if not identity or identity == "" then
        return nil
    end
    local basename = ffiUtil.basename and ffiUtil.basename(identity)
    if basename and basename ~= "" then
        return basename
    end
    return identity
end

function Storage.getOrCreateDocument(context)
    Storage.init()
    if not context or not context.identity or context.identity == "" then
        return nil
    end
    local identity_type = context.identity_type or "path"
    local display_name = context.display_name or computeDisplayName(context.identity)
    return withConnection(function(conn)
        local row = fetchOne(conn, [[SELECT id, identity, identity_type, display_name FROM documents WHERE identity = ? AND identity_type = ?;]], { context.identity, identity_type })
        if row then
            local id = tonumber(row.id)
            local stored_identity = row.identity
            local stored_type = row.identity_type
            local stored_display = row.display_name
            if display_name and display_name ~= stored_display then
                local update_stmt = conn:prepare([[UPDATE documents SET display_name = ? WHERE id = ?;]])
                update_stmt:bind(display_name, id)
                update_stmt:step()
                update_stmt:close()
                stored_display = display_name
            end
            return {
                id = id,
                identity = stored_identity,
                identity_type = stored_type,
                display_name = stored_display,
            }
        end
        local insert_stmt = conn:prepare([[INSERT INTO documents (identity, identity_type, display_name) VALUES (?, ?, ?);]])
        insert_stmt:bind(context.identity, identity_type, display_name)
        insert_stmt:step()
        insert_stmt:close()
        local id_row = fetchOne(conn, [[SELECT last_insert_rowid() AS id;]])
        local doc_id = id_row and tonumber(id_row.id) or nil
        return {
            id = doc_id,
            identity = context.identity,
            identity_type = identity_type,
            display_name = display_name,
        }
    end)
end

function Storage.listDocuments()
    Storage.init()
    return withConnection(function(conn)
        local rows = fetchAll(conn, [[SELECT id, identity, identity_type, display_name FROM documents ORDER BY display_name COLLATE NOCASE;]])
        local result = {}
        for _, row in ipairs(rows) do
            table.insert(result, mapDocumentRow(row))
        end
        return result
    end)
end

function Storage.findDocument(identity, identity_type)
    Storage.init()
    if not identity or identity == "" then
        return nil
    end
    identity_type = identity_type or "path"
    return withConnection(function(conn)
        local row = fetchOne(conn, [[SELECT id, identity, identity_type, display_name FROM documents WHERE identity = ? AND identity_type = ?;]], { identity, identity_type })
        if not row then
            return nil
        end
        return {
            id = tonumber(row.id),
            identity = row.identity,
            identity_type = row.identity_type,
            display_name = row.display_name,
        }
    end)
end

function Storage.getDocumentById(id)
    Storage.init()
    if not id then
        return nil
    end
    return withConnection(function(conn)
        local row = fetchOne(conn, [[SELECT id, identity, identity_type, display_name FROM documents WHERE id = ?;]], { id })
        if not row then
            return nil
        end
        return {
            id = tonumber(row.id),
            identity = row.identity,
            identity_type = row.identity_type,
            display_name = row.display_name,
        }
    end)
end

local function buildSearchClause(search_text)
    if not search_text or search_text == "" then
        return nil
    end
    local pattern = string.lower(search_text)
    local clause = [[ AND (
        LOWER(g.primary_tag) LIKE '%' || ? || '%' OR
        EXISTS (
            SELECT 1 FROM aliases a WHERE a.group_id = g.id AND LOWER(a.alias) LIKE '%' || ? || '%'
        )
    )]]
    return clause, pattern
end

function Storage.listGroups(opts)
    Storage.init()
    opts = opts or {}
    local clause, pattern = buildSearchClause(opts.search_text)
    local document_filter = ""
    local bindings = {}
    if opts.document_id then
        document_filter = " AND g.document_id = ?"
        table.insert(bindings, opts.document_id)
    end
    if clause then
        table.insert(bindings, pattern)
        table.insert(bindings, pattern)
    end
    local sql = [[
        SELECT g.id, g.document_id, g.primary_tag, g.normalized_tag, g.multi_note_mode,
               d.identity, d.identity_type, d.display_name,
               (SELECT COUNT(*) FROM aliases WHERE group_id = g.id) AS alias_count,
               (SELECT COUNT(*) FROM notes WHERE group_id = g.id) AS note_count
        FROM groups g
        JOIN documents d ON d.id = g.document_id
        WHERE 1 = 1]] .. document_filter .. (clause or "") .. [[
        ORDER BY LOWER(g.primary_tag) ASC;
    ]]
    return withConnection(function(conn)
        local rows = fetchAll(conn, sql, bindings)
        local groups = {}
        for _, row in ipairs(rows) do
            table.insert(groups, {
                id = tonumber(row.id),
                document_id = tonumber(row.document_id),
                document_identity = row.identity,
                document_identity_type = row.identity_type,
                document_display_name = row.display_name,
                primary_tag = row.primary_tag,
                normalized_tag = row.normalized_tag,
                multi_note_mode = tonumber(row.multi_note_mode) == 1,
                alias_count = tonumber(row.alias_count) or 0,
                note_count = tonumber(row.note_count) or 0,
            })
        end
        return groups
    end)
end

local function getGroupRow(conn, document_id, normalized_tag)
    local row = fetchOne(conn, [[SELECT id, primary_tag, normalized_tag, multi_note_mode FROM groups WHERE document_id = ? AND normalized_tag = ?;]], { document_id, normalized_tag })
    if not row then
        return nil
    end
    return {
        id = tonumber(row.id),
        primary_tag = row.primary_tag,
        normalized_tag = row.normalized_tag,
        multi_note_mode = tonumber(row.multi_note_mode) == 1,
    }
end

function Storage.deleteGroupsWithoutNotes(document_id)
    Storage.init()
    local target_id = document_id and tonumber(document_id) or nil
    return withConnection(function(conn)
        local sql
        local stmt
        if target_id then
            sql = [[DELETE FROM groups WHERE document_id = ? AND NOT EXISTS (SELECT 1 FROM notes WHERE group_id = groups.id);]]
            stmt = conn:prepare(sql)
            stmt:bind(target_id)
        else
            sql = [[DELETE FROM groups WHERE NOT EXISTS (SELECT 1 FROM notes WHERE group_id = groups.id);]]
            stmt = conn:prepare(sql)
        end
        stmt:step()
        stmt:close()
    end)
end

function Storage.ensureGroup(document_id, primary_tag, normalized_tag)
    Storage.init()
    if not document_id then
        return nil
    end
    return withConnection(function(conn)
        local existing = getGroupRow(conn, document_id, normalized_tag)
        if existing then
            if not existing.multi_note_mode then
                local update_stmt = conn:prepare([[UPDATE groups SET multi_note_mode = 1 WHERE id = ?;]])
                update_stmt:bind(existing.id)
                update_stmt:step()
                update_stmt:close()
                existing.multi_note_mode = true
            end
            if existing.primary_tag ~= primary_tag then
                local update_stmt = conn:prepare([[UPDATE groups SET primary_tag = ? WHERE id = ?;]])
                update_stmt:bind(primary_tag, existing.id)
                update_stmt:step()
                update_stmt:close()
                existing.primary_tag = primary_tag
            end
            return existing
        end
        local stmt = conn:prepare([[INSERT INTO groups (document_id, primary_tag, normalized_tag) VALUES (?, ?, ?);]])
        stmt:bind(document_id, primary_tag, normalized_tag)
        stmt:step()
        stmt:close()
        local id_row = fetchOne(conn, [[SELECT last_insert_rowid() AS id;]])
        local group_id = id_row and tonumber(id_row.id) or nil
        return {
            id = group_id,
            primary_tag = primary_tag,
            normalized_tag = normalized_tag,
            multi_note_mode = true,
        }
    end)
end

function Storage.getGroup(document_id, normalized_tag)
    Storage.init()
    if not document_id then
        return nil
    end
    return withConnection(function(conn)
        return getGroupRow(conn, document_id, normalized_tag)
    end)
end

function Storage.setGroupMultiNoteMode(group_id, enabled)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE groups SET multi_note_mode = ? WHERE id = ?;]])
        stmt:bind(enabled and 1 or 0, group_id)
        stmt:step()
        stmt:close()
    end)
end

function Storage.deleteGroup(group_id)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[DELETE FROM groups WHERE id = ?;]])
        stmt:bind(group_id)
        stmt:step()
        stmt:close()
    end)
end

function Storage.addNote(group_id, text)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[INSERT INTO notes (group_id, text) VALUES (?, ?);]])
        stmt:bind(group_id, text)
        stmt:step()
        stmt:close()
        local row = fetchOne(conn, [[SELECT last_insert_rowid() AS id;]])
        return row and tonumber(row.id) or nil
    end)
end

function Storage.updateNote(note_id, text)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[UPDATE notes SET text = ?, updated_at = strftime('%s','now') WHERE id = ?;]])
        stmt:bind(text, note_id)
        stmt:step()
        stmt:close()
    end)
end

function Storage.deleteNote(note_id)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[DELETE FROM notes WHERE id = ?;]])
        stmt:bind(note_id)
        stmt:step()
        stmt:close()
    end)
end

function Storage.getNotes(group_id)
    Storage.init()
    return withConnection(function(conn)
        local rows = fetchAll(conn, [[SELECT id, text, created_at, updated_at FROM notes WHERE group_id = ? ORDER BY created_at ASC;]], { group_id })
        local notes = {}
        for _, row in ipairs(rows) do
            table.insert(notes, {
                id = tonumber(row.id),
                text = row.text,
                created_at = tonumber(row.created_at),
                updated_at = tonumber(row.updated_at),
            })
        end
        return notes
    end)
end

function Storage.clearNotes(group_id)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[DELETE FROM notes WHERE group_id = ?;]])
        stmt:bind(group_id)
        stmt:step()
        stmt:close()
    end)
end

function Storage.listAliases(group_id)
    Storage.init()
    return withConnection(function(conn)
        local rows = fetchAll(conn, [[SELECT alias, normalized_alias FROM aliases WHERE group_id = ? ORDER BY LOWER(alias) ASC;]], { group_id })
        local aliases = {}
        for _, row in ipairs(rows) do
            table.insert(aliases, {
                alias = row.alias,
                normalized = row.normalized_alias,
            })
        end
        return aliases
    end)
end

function Storage.addAlias(group_id, alias, normalized_alias)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[INSERT OR IGNORE INTO aliases (group_id, alias, normalized_alias) VALUES (?, ?, ?);]])
        stmt:bind(group_id, alias, normalized_alias)
        stmt:step()
        stmt:close()
    end)
end

function Storage.aliasInUse(document_id, normalized_alias)
    Storage.init()
    if not document_id or not normalized_alias then
        return false
    end
    return withConnection(function(conn)
        local row = fetchOne(conn, [[SELECT 1 FROM groups WHERE document_id = ? AND normalized_tag = ? LIMIT 1;]], { document_id, normalized_alias })
        if row then
            return true
        end
        local alias_exists = fetchOne(conn, [[SELECT 1 FROM aliases a JOIN groups g ON g.id = a.group_id WHERE g.document_id = ? AND a.normalized_alias = ? LIMIT 1;]], { document_id, normalized_alias })
        return alias_exists ~= nil
    end)
end

function Storage.getDatabasePath()
    Storage.init()
    return DB_PATH
end

function Storage.removeAlias(group_id, normalized_alias)
    Storage.init()
    return withConnection(function(conn)
        local stmt = conn:prepare([[DELETE FROM aliases WHERE group_id = ? AND normalized_alias = ?;]])
        stmt:bind(group_id, normalized_alias)
        stmt:step()
        stmt:close()
    end)
end

local function loadFullData(conn, target_document_id)
    local data = { documents = {}, groups = {} }
    local document_rows
    if target_document_id then
        document_rows = fetchAll(conn, [[SELECT id, identity, identity_type, display_name FROM documents WHERE id = ?;]], { target_document_id })
    else
        document_rows = fetchAll(conn, [[SELECT id, identity, identity_type, display_name FROM documents;]])
    end
    for _, doc in ipairs(document_rows) do
        local doc_id = tonumber(doc.id)
        if doc_id then
            data.documents[doc_id] = {
                id = doc_id,
                identity = doc.identity,
                identity_type = doc.identity_type,
                display_name = doc.display_name,
            }
        end
    end

    local groups = {}
    local group_rows
    if target_document_id then
        group_rows = fetchAll(conn, [[SELECT id, document_id, primary_tag, normalized_tag, multi_note_mode FROM groups WHERE document_id = ?;]], { target_document_id })
    else
        group_rows = fetchAll(conn, [[SELECT id, document_id, primary_tag, normalized_tag, multi_note_mode FROM groups;]])
    end
    for _, group in ipairs(group_rows) do
        local group_id = tonumber(group.id)
        local group_document_id = tonumber(group.document_id)
        if group_id and group_document_id then
            groups[group_id] = {
                document_id = group_document_id,
                primary_tag = group.primary_tag,
                normalized_tag = group.normalized_tag,
                multi_note_mode = tonumber(group.multi_note_mode) == 1,
                aliases = {},
                notes = {},
            }
            if not data.groups[group_document_id] then
                data.groups[group_document_id] = {}
            end
            data.groups[group_document_id][group.normalized_tag] = groups[group_id]
        end
    end

    local alias_rows
    if target_document_id then
        alias_rows = fetchAll(conn, [[SELECT a.group_id, a.alias, a.normalized_alias FROM aliases a JOIN groups g ON g.id = a.group_id WHERE g.document_id = ?;]], { target_document_id })
    else
        alias_rows = fetchAll(conn, [[SELECT group_id, alias, normalized_alias FROM aliases;]])
    end
    for _, alias in ipairs(alias_rows) do
        local group_id = tonumber(alias.group_id)
        local group_entry = group_id and groups[group_id] or nil
        if group_entry then
            table.insert(group_entry.aliases, {
                alias = alias.alias,
                normalized = alias.normalized_alias,
            })
        end
    end
    local note_rows
    if target_document_id then
        note_rows = fetchAll(conn, [[SELECT n.id, n.group_id, n.text, n.created_at, n.updated_at FROM notes n JOIN groups g ON g.id = n.group_id WHERE g.document_id = ?;]], { target_document_id })
    else
        note_rows = fetchAll(conn, [[SELECT id, group_id, text, created_at, updated_at FROM notes;]])
    end
    for _, note in ipairs(note_rows) do
        local group_id = tonumber(note.group_id)
        local group_entry = group_id and groups[group_id] or nil
        if group_entry then
            table.insert(group_entry.notes, {
                id = tonumber(note.id),
                text = note.text,
                created_at = tonumber(note.created_at),
                updated_at = tonumber(note.updated_at),
            })
        end
    end

    return data
end

function Storage.exportTo(path, opts)
    Storage.init()
    opts = opts or {}
    local target_document_id = opts.document_id and tonumber(opts.document_id) or nil
    return withConnection(function(conn)
        local data = loadFullData(conn, target_document_id)
        local encoded = json.encode(data)
        local dir = ffiUtil.dirname(path)
        if dir and dir ~= "" and dir ~= "." then
            util.makePath(dir)
        end
        local fp, err = io.open(path, "w")
        if not fp then
            return false, err or "io_open_failed"
        end
        fp:write(encoded)
        fp:close()
        return true
    end)
end

function Storage.reset()
    Storage.init()
    return withConnection(function(conn)
        conn:exec("DELETE FROM notes;")
        conn:exec("DELETE FROM aliases;")
        conn:exec("DELETE FROM groups;")
        conn:exec("DELETE FROM documents;")
    end)
end

return Storage
