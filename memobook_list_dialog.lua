local ButtonDialog = require("ui/widget/buttondialog")
local ButtonTable = require("ui/widget/buttontable")
local ConfirmBox = require("ui/widget/confirmbox")
local FrameContainer = require("ui/widget/container/framecontainer")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Size = require("ui/size")
local Font = require("ui/font")
local Screen = require("device").screen
local ffiUtil = require("ffi/util")
local T = ffiUtil.template
local util = require("util")
local _ = require("gettext")

local ListDialog = {}
ListDialog.__index = ListDialog

function ListDialog:new(manager, popup)
    return setmetatable({
        manager = manager,
        popup = popup,
        filter_text = nil,
        context = nil,
        document_id = nil,
        active_document = nil,
        active_dialog = nil,
    }, self)
end

local function cloneAndSortGroups(groups)
    local sorted = {}
    for index, group in ipairs(groups) do
        table.insert(sorted, group)
    end
    table.sort(sorted, function(a, b)
        local a_tag = a.primary_tag or ""
        local b_tag = b.primary_tag or ""
        return a_tag:lower() < b_tag:lower()
    end)
    return sorted
end

local function groupOptions(group)
    if not group then
        return { document_id = nil, context = nil }
    end
    return {
        document_id = group.document_id,
        context = group.document_context,
    }
end

local function getPreferredDialogWidth()
    local width = Screen and Screen:getWidth() or Size.screen.width or 600
    local height = Screen and Screen:getHeight() or Size.screen.height or width
    local base = math.max(width, height)
    if width < height then
        base = width
    end
    return math.floor(base * 0.92)
end

local function ensureButtonCallbacks(button_grid)
    if not button_grid then
        return button_grid
    end
    for _, row in ipairs(button_grid) do
        for _, entry in ipairs(row) do
            if entry.callback == nil then
                entry.callback = function() end
            end
        end
    end
    return button_grid
end

function ListDialog:showGroupActions(group)
    local opts = groupOptions(group)
    local full_group = self.manager:getGroupForTag(group.primary_tag, opts)
    if not full_group then
        UIManager:show(InfoMessage:new{ text = _("Group could not be loaded."), timeout = 2 })
        return
    end
    local dialog
    local buttons = {
        {
            {
                text = _("Details"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    elseif UIManager.closeTopmost then
                        UIManager:closeTopmost()
                    elseif UIManager.close then
                        UIManager:close()
                    end
                    self:showGroupDetails(full_group)
                end,
            },
            {
                text = _("Open"),
                callback = function()
                    UIManager:scheduleIn(0, function()
                        self.popup:show(full_group.primary_tag, { document_id = full_group.document_id, identity = full_group.document_identity, identity_type = full_group.document_identity_type })
                    end)
                end,
            },
            {
                text = _("Delete"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    elseif UIManager.closeTopmost then
                        UIManager:closeTopmost()
                    elseif UIManager.close then
                        UIManager:close()
                    end
                    UIManager:show(ConfirmBox:new{
                        text = T(_("Delete memo group '%1'?"), full_group.primary_tag),
                        ok_text = _("Delete"),
                        ok_callback = function()
                            self.manager:removeGroup(full_group.primary_tag, opts)
                            self:show()
                        end,
                    })
                end,
            },
        },
        {
            {
                text = _("Cancel"),
                callback = function()
                    if dialog then
                        UIManager:close(dialog)
                    elseif UIManager.closeTopmost then
                        UIManager:closeTopmost()
                    elseif UIManager.close then
                        UIManager:close()
                    end
                end,
            },
        },
    }
    ensureButtonCallbacks(buttons)
    dialog = ButtonDialog:new{
        title = full_group.primary_tag,
        buttons = buttons,
    }
    UIManager:show(dialog)
end

local function formatTimestamp(ts)
    if not ts then
        return _("Unknown")
    end
    return os.date("%Y-%m-%d %H:%M", ts)
end

function ListDialog:showGroupDetails(group)
    local lines = {}
    local identity_text = group and group.document_identity or ""
    if not identity_text or identity_text == "" then
        identity_text = _("(unknown path)")
    end
    table.insert(lines, T(_("File: %1"), identity_text))
    table.insert(lines, T(_("Primary tag: %1"), group.primary_tag or ""))
    local alias_text
    if group.aliases and #group.aliases > 0 then
        alias_text = table.concat(group.aliases, ", ")
    else
        alias_text = _("(none)")
    end
    table.insert(lines, T(_("Aliases: %1"), alias_text))
    local note_count = group.notes and #group.notes or 0
    table.insert(lines, T(_("Notes: %1"), note_count))
    if note_count > 0 then
        local preview = util.trim(group.notes[1].text or "")
        if #preview > 200 then
            preview = preview:sub(1, 200) .. "…"
        end
        table.insert(lines, T(_("First note updated: %1"), formatTimestamp(group.notes[1].updated_at)))
        table.insert(lines, T(_("First note preview: %1"), preview ~= "" and preview or _("(empty)")))
    end

    UIManager:show(InfoMessage:new{
        title = _("Memo details"),
        text = table.concat(lines, "\n\n"),
    })
end

function ListDialog:_closeActiveDialog()
    if self.active_dialog then
        UIManager:close(self.active_dialog)
        self.active_dialog = nil
    end
end

function ListDialog:promptExport()
    if UIManager.closeTopmost then
        UIManager:closeTopmost()
    elseif UIManager.close then
        UIManager:close()
    end
    local default_path = self.manager:getDefaultExportPath({ document_id = self.active_document and self.active_document.id, context = self.context })
    local export_dialog
    export_dialog = InputDialog:new{
        title = _("Export memos to JSON"),
        input = default_path,
        buttons = {
            {
                {
                    text = _("Export"),
                    callback = function()
                        local path = util.trim(export_dialog:getInputText() or "")
                        if path == "" then
                            UIManager:show(InfoMessage:new{ text = _("Please provide a file path."), timeout = 2 })
                            return
                        end
                        local dir = ffiUtil.dirname(path)
                        if dir and dir ~= "" and dir ~= "." then
                            local created, create_err = util.makePath(dir)
                            if not created then
                                UIManager:show(InfoMessage:new{
                                    text = T(_("Export failed: %1"), create_err or _("Could not create destination folder.")),
                                    timeout = 3,
                                })
                                return
                            end
                        end
                        local ok, err = self.manager:exportTo(path, { document_id = self.active_document and self.active_document.id, context = self.context })
                        if ok then
                            UIManager:show(InfoMessage:new{
                                text = T(_("Exported to: %1"), path),
                                timeout = 3,
                            })
                        else
                            UIManager:show(InfoMessage:new{
                                text = T(_("Export failed: %1"), err or _("Unknown error")),
                                timeout = 3,
                            })
                        end
                        UIManager:close(export_dialog)
                        UIManager:scheduleIn(0, function()
                            self:show({ preserve_filter = true })
                        end)
                    end,
                },
                {
                    text = _("Close"),
                    callback = function()
                        UIManager:close(export_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(export_dialog)
end

function ListDialog:show(opts)
    opts = opts or {}

    self:_closeActiveDialog()

    if not opts.preserve_filter then
        self.filter_text = opts.filter_text
    end

    if opts.context ~= nil then
        self.context = opts.context
    end
    if opts.document_id ~= nil then
        self.document_id = opts.document_id
    end

    local groups, active_doc = self.manager:listGroups{
        context = self.context,
        document_id = self.document_id,
        search_text = self.filter_text,
    }
    self.active_document = active_doc
    local is_document_view = self.active_document ~= nil or self.document_id ~= nil or self.context ~= nil

    if #groups == 0 then
        local close_button = { text = _("Close") }
        local buttons = {
            {
                {
                    text = self.filter_text and self.filter_text ~= "" and _("No memos match filter") or _("No memos yet"),
                    enabled = false,
                },
            },
            { close_button },
        }
        ensureButtonCallbacks(buttons)
        local dialog = ButtonDialog:new{
            title = _("Memo Book"),
            buttons = buttons,
        }
        self.active_dialog = dialog
        close_button.callback = function()
            if self.active_dialog == dialog then
                self.active_dialog = nil
            end
            UIManager:close(dialog)
            local had_filter = self.filter_text ~= nil and self.filter_text ~= ""
            if had_filter then
                UIManager:scheduleIn(0, function()
                    self:show({ preserve_filter = false })
                end)
            end
        end
        UIManager:show(dialog)
        return
    end

    local button_rows = {}

    for index, group in ipairs(cloneAndSortGroups(groups)) do
        local label = group.primary_tag or ""
        if not is_document_view then
            local doc_name = group.document_display_name or group.document_identity or _("Unknown document")
            label = label .. " — " .. doc_name
        end
        table.insert(button_rows, {
            {
                text = label,
                callback = function()
                    self.popup:show(group.primary_tag, {
                        document_id = group.document_id,
                        identity = group.document_identity,
                        identity_type = group.document_identity_type,
                    })
                end,
                hold_callback = function()
                    self:showGroupActions(group)
                end,
            },
        })
    end

    ensureButtonCallbacks(button_rows)
    local dialog_width = getPreferredDialogWidth()
    local dialog = ButtonDialog:new{
        title = _("Memo Book"),
        buttons = button_rows,
        width = dialog_width,
        shrink_unneeded_width = false,
    }
    self.active_dialog = dialog

    local content_size = dialog.getContentSize and dialog:getContentSize() or nil
    local available_width = dialog_width
    if content_size and content_size.w and content_size.w > 0 then
        available_width = content_size.w
    end
    local controls_buttons = {
        {
            {
                text = self.filter_text and self.filter_text ~= "" and T(_("Filter: %1"), self.filter_text) or _("Filter: (none)"),
                enabled = false,
            },
            {
                text = _("Search"),
                callback = function()
                    local search_dialog
                    search_dialog = InputDialog:new{
                        title = _("Search tags or aliases"),
                        input_text = self.filter_text or "",
                        buttons = {
                            {
                                {
                                    text = _("Apply"),
                                    callback = function()
                                        local value = util.trim(search_dialog:getInputText() or "")
                                        self.filter_text = value ~= "" and value or nil
                                        UIManager:close(search_dialog)
                                        UIManager:scheduleIn(0, function()
                                            self:show({ preserve_filter = true })
                                        end)
                                    end,
                                },
                                {
                                    text = _("Close"),
                                    callback = function()
                                        UIManager:close(search_dialog)
                                    end,
                                },
                            },
                        },
                    }
                    UIManager:show(search_dialog)
                end,
            },
            {
                text = _("Clear filter"),
                enabled = self.filter_text ~= nil,
                callback = function()
                    self.filter_text = nil
                    UIManager:scheduleIn(0, function()
                        self:show({ preserve_filter = true })
                    end)
                end,
            },
            {
                text = _("Export JSON"),
                callback = function()
                    self:promptExport()
                end,
            },
            {
                text = _("Close"),
                callback = function()
                    if self.active_dialog == dialog then
                        self.active_dialog = nil
                    end
                    UIManager:close(dialog)
                end,
            },
        },
    }

    ensureButtonCallbacks(controls_buttons)
    local controls_table = ButtonTable:new{
        buttons = controls_buttons,
        width = available_width,
        show_parent = dialog,
        shrink_unneeded_width = false,
    }

    local header_group = VerticalGroup:new{ align = "left", not_focusable = true }
    if not is_document_view then
        table.insert(header_group, TextWidget:new{
            text = _("Document: All"),
            face = Font:getFace("smallinfofont"),
            max_width = available_width,
            not_focusable = true,
        })
    end

    table.insert(header_group, FrameContainer:new{
        padding = Size.padding.default,
        controls_table,
    })

    dialog:addWidget(header_group)

    UIManager:show(dialog)
end

return ListDialog
