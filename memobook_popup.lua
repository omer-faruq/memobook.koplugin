local ButtonDialog = require("ui/widget/buttondialog")
local TextWidget = require("ui/widget/textwidget")
local ScrollTextWidget = require("ui/widget/scrolltextwidget")
local LineWidget = require("ui/widget/linewidget")
local FrameContainer = require("ui/widget/container/framecontainer")
local Font = require("ui/font")
local Geom = require("ui/geometry")
local Size = require("ui/size")
local Screen = require("device").screen
local UIManager = require("ui/uimanager")
local InputDialog = require("ui/widget/inputdialog")
local TextViewer = require("ui/widget/textviewer")
local VerticalGroup = require("ui/widget/verticalgroup")
local util = require("frontend/util")
local T = require("ffi/util").template
local _ = require("gettext")

local function utf8_length(text)
    local count = 0
    for _ in text:gmatch(util.UTF8_CHAR_PATTERN) do
        count = count + 1
    end
    return count
end

local function utf8_prefix(text, max_chars)
    local captured = {}
    local count = 0
    for uchar in text:gmatch(util.UTF8_CHAR_PATTERN) do
        count = count + 1
        captured[#captured + 1] = uchar
        if count >= max_chars then
            break
        end
    end
    return table.concat(captured)
end

local function truncate_note_label(text)
    if not text or text == "" then
        return _("[No note]")
    end
    local trimmed = util.trim(text)
    if trimmed == "" then
        return _("[No note]")
    end
    local first_line = trimmed:match("([^\n]*)") or trimmed
    if first_line == "" then
        return _("[No note]")
    end
    if utf8_length(first_line) <= 20 then
        return first_line
    end
    return utf8_prefix(first_line, 20) .. "…"
end

local function get_large_dialog_width()
    return math.floor(math.min(Screen:getWidth(), Screen:getHeight()) * 0.8)
end

local Popup = {}
Popup.__index = Popup

function Popup:new(manager)
    return setmetatable({
        manager = manager,
    }, self)
end

local function buildAliasesRows(self, tag, group, options)
    options = options or {}
    local refresh_callback = options.refresh_callback or function()
        UIManager:scheduleIn(0, function()
            self:show(tag, options.context)
        end)
    end
    local rows = {}
    local primary_tag, aliases = self.manager:listAliases(tag, { context = options.context, document_id = options.document_id })
    local alias_face = Font:getFace("infofont")
        or Font:getFace("cfont")
        or Font:getFace("x_smallinfofont")
        or Font:getFace("infofont", 20)
        or Font:getFace("cfont", 20)
    local alias_widget
    if alias_face and #aliases > 0 then
        alias_widget = TextWidget:new{
            text = _("Aliases: ") .. table.concat(aliases, ", "),
            face = alias_face,
            max_width = math.huge,
        }
        alias_widget.not_focusable = true
    end

    table.insert(rows, {
        {
            text = _("Add alias"),
            callback = function()
                local alias_dialog
                alias_dialog = InputDialog:new{
                    title = _("Add alias"),
                    input = "",
                    buttons = {
                        {
                            {
                                text = _("Save"),
                                callback = function()
                                    local alias = alias_dialog:getInputText()
                                    if alias ~= "" then
                                        self.manager:addAlias(primary_tag or tag, alias, { context = options.context, document_id = options.document_id })
                                    end
                                    UIManager:close(alias_dialog)
                                    refresh_callback()
                                end,
                            },
                            {
                                text = _("Close"),
                                callback = function()
                                    UIManager:close(alias_dialog)
                                    refresh_callback()
                                end,
                            },
                        },
                    },
                }
                UIManager:show(alias_dialog)
            end,
        },
        {
            text = _("Remove alias"),
            enabled = #aliases > 0,
            callback = function()
                if #aliases == 0 then
                    return
                end
                local remove_dialog
                remove_dialog = InputDialog:new{
                    title = _("Remove alias"),
                    input = "",
                    buttons = {
                        {
                            {
                                text = _("Remove"),
                                callback = function()
                                    local alias = remove_dialog:getInputText()
                                    if alias ~= "" then
                                        self.manager:removeAlias(primary_tag or tag, alias, { context = options.context, document_id = options.document_id })
                                    end
                                    UIManager:close(remove_dialog)
                                    refresh_callback()
                                end,
                            },
                            {
                                text = _("Close"),
                                callback = function()
                                    UIManager:close(remove_dialog)
                                    refresh_callback()
                                end,
                            },
                        },
                    },
                }
                UIManager:show(remove_dialog)
            end,
        },
    })

    return rows, alias_widget
end

local function buildMultiNoteDialog(self, tag, group, context, options)
    options = options or {}
    group = self.manager:getGroupForTag(tag, {
        context = context,
        document_id = group and group.document_id,
    }) or group
    local dialog
    local buttons = {}
    local note_buttons_row = {}

    local first_note
    for index, note in ipairs(group.notes or {}) do
        if index == 1 then
            first_note = note
        end
        table.insert(note_buttons_row, {
            text = truncate_note_label(note.text or ""),
            callback = function()
                if dialog then
                    UIManager:close(dialog)
                    dialog = nil
                end
                local viewer
                viewer = TextViewer:new{
                    title = tag,
                    text = note.text or "",
                    text_type = "bookmark",
                    buttons_table = {
                        {
                            {
                                text = _("Edit"),
                                callback = function()
                                    UIManager:close(viewer)
                                    local edit_dialog
                                    edit_dialog = InputDialog:new{
                                        title = T(_("Edit note %1"), index),
                                        input = note.text or "",
                                        multiline = true,
                                        allow_newline = true,
                                        text_height = Font:getFace("infofont").size * 10,
                                        buttons = {
                                            {
                                                {
                                                    text = _("Save"),
                                                    callback = function()
                                                        local text_value = edit_dialog:getInputText()
                                                        self.manager:updateNote(tag, index, text_value, { context = context, document_id = group.document_id })
                                                        UIManager:close(edit_dialog)
                                                        UIManager:scheduleIn(0, function()
                                                            self:show(tag, context)
                                                        end)
                                                    end,
                                                },
                                                {
                                                    text = _("Close"),
                                                    callback = function()
                                                        UIManager:close(edit_dialog)
                                                    end,
                                                },
                                            },
                                        },
                                    }
                                    UIManager:show(edit_dialog)
                                end,
                            },
                            {
                                text = _("Delete"),
                                callback = function()
                                    if dialog then
                                        UIManager:close(dialog)
                                        dialog = nil
                                    end
                                    self.manager:deleteNote(tag, index, { context = context, document_id = group.document_id })
                                    UIManager:close(viewer)
                                    self:show(tag, context)
                                end,
                            },
                            {
                                text = _("Close"),
                                callback = function()
                                    UIManager:close(viewer)
                                    self:show(tag, context)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(viewer)
            end,
            hold_callback = function()
                if dialog then
                    UIManager:close(dialog)
                    dialog = nil
                end
                self.manager:deleteNote(tag, index, { context = context, document_id = group.document_id })
                self:show(tag, context)
            end,
        })
        if #note_buttons_row == 2 then
            table.insert(buttons, note_buttons_row)
            note_buttons_row = {}
        end
    end

    if #note_buttons_row > 0 then
        table.insert(buttons, note_buttons_row)
    end

    table.insert(buttons, {
        {
            text = _("Add"),
            callback = function()
                if dialog then
                    UIManager:close(dialog)
                    dialog = nil
                end
                local new_note_dialog
                new_note_dialog = InputDialog:new{
                    title = _("New note"),
                    input = "",
                    multiline = true,
                    allow_newline = true,
                    text_height = Font:getFace("infofont").size * 10,
                    buttons = {
                        {
                            {
                                text = _("Save"),
                                callback = function()
                                    local text = new_note_dialog:getInputText()
                                    self.manager:addNote(tag, text, {
                                        context = context,
                                        document_id = group.document_id,
                                        initial_alias = options.initial_alias,
                                    })
                                    options.initial_alias = nil
                                    UIManager:close(new_note_dialog)
                                    UIManager:scheduleIn(0, function()
                                        self:show(tag, context)
                                    end)
                                end,
                            },
                            {
                                text = _("Close"),
                                callback = function()
                                    UIManager:close(new_note_dialog)
                                end,
                            },
                        },
                    },
                }
                UIManager:show(new_note_dialog)
            end,
        },
        {
            text = _("Alias"),
            callback = function()
                if dialog then
                    UIManager:close(dialog)
                    dialog = nil
                end
                UIManager:scheduleIn(0, function()
                    Popup.buildAliasDialog(self, tag, group, context)
                end)
            end,
        },
        {
            text = _("Close"),
            callback = function()
                if dialog then
                    UIManager:close(dialog)
                    dialog = nil
                end
            end,
        },
    })

    local dialog_width = get_large_dialog_width()
    dialog = ButtonDialog:new{
        buttons = buttons,
        width = dialog_width,
        shrink_unneeded_width = false,
    }

    local available_width = dialog:getAddedWidgetAvailableWidth()
    if not available_width or available_width <= 0 then
        available_width = dialog_width - 2 * (Size.padding.default + Size.margin.default)
    end
    if available_width <= 0 then
        available_width = dialog_width
    end

    local heading_group = VerticalGroup:new{ align = "left", not_focusable = true }
    table.insert(heading_group, TextWidget:new{
        text = tag,
        face = Font:getFace("cfont"),
        bold = true,
        not_focusable = true,
        max_width = available_width,
    })
    table.insert(heading_group, LineWidget:new{
        dimen = Geom:new{
            w = available_width,
            h = Size.line.medium,
        },
    })

    local aliases = group.aliases or {}
    if #aliases > 0 then
        table.insert(heading_group, TextWidget:new{
            text = T(_("Aliases: %1"), table.concat(aliases, ", ")),
            face = Font:getFace("infofont") or Font:getFace("cfont") or Font:getFace("smallinfofont"),
            not_focusable = true,
            max_width = available_width,
        })
    end
    dialog:addWidget(heading_group)

    local preview_note = first_note or { text = _("[No note]") }
    local note_face = Font:getFace("infofont")
        or Font:getFace("cfont")
        or Font:getFace("x_smallinfofont")
        or Font:getFace("infofont", 20)
        or Font:getFace("cfont", 20)
    local face_size = (note_face and note_face.size) or Size.item.height_big
    local content_padding = Size.padding.default
    local note_height = math.max(face_size * 12, Size.item.height_big)
    local preview_container = FrameContainer:new{
        padding = content_padding,
        ScrollTextWidget:new{
            text = preview_note.text or _("[No note]"),
            face = note_face,
            width = math.max(available_width - 2 * content_padding, Size.padding.large * 2),
            height = note_height,
            dialog = dialog,
            alignment = "left",
        },
    }
    preview_container.not_focusable = true

    dialog:addWidget(preview_container)

    UIManager:show(dialog)
end

function Popup.buildAliasDialog(self, tag, group, context)
    group = group or self.manager:getGroupForTag(tag, { context = context, document_id = group and group.document_id })
    if not group then
        group = self.manager:getOrCreateGroup(tag, { context = context })
    end
    local dialog
    local alias_rows, alias_widget = buildAliasesRows(self, tag, group, {
        document_id = group.document_id,
        context = context,
        refresh_callback = function()
            UIManager:scheduleIn(0, function()
                Popup.buildAliasDialog(self, tag, group, context)
            end)
        end,
    })
    local buttons = {}

    local function wrap_row(row)
        local wrapped = {}
        for index, button in ipairs(row) do
            local original_callback = button.callback
            local new_button = {}
            for key, value in pairs(button) do
                new_button[key] = value
            end
            if original_callback then
                new_button.callback = function(...)
                    if dialog then
                        UIManager:close(dialog)
                        dialog = nil
                    end
                    original_callback(...)
                end
            end
            wrapped[index] = new_button
        end
        return wrapped
    end

    for _, row in ipairs(alias_rows) do
        table.insert(buttons, wrap_row(row))
    end

    table.insert(buttons, {
        {
            text = _("Close"),
            callback = function()
                if dialog then
                    UIManager:close(dialog)
                    dialog = nil
                end
                UIManager:scheduleIn(0, function()
                    self:show(tag, context)
                end)
            end,
        },
    })

    local dialog_width = get_large_dialog_width()
    dialog = ButtonDialog:new{
        buttons = buttons,
        width = dialog_width,
        shrink_unneeded_width = false,
    }

    local available_width = dialog:getAddedWidgetAvailableWidth()
    if not available_width or available_width <= 0 then
        available_width = dialog_width - 2 * (Size.padding.default + Size.margin.default)
    end
    if available_width <= 0 then
        available_width = dialog_width
    end

    local heading_group = VerticalGroup:new{ align = "left", not_focusable = true }
    table.insert(heading_group, TextWidget:new{
        text = tag,
        face = Font:getFace("cfont"),
        bold = true,
        not_focusable = true,
        max_width = available_width,
    })
    table.insert(heading_group, LineWidget:new{
        dimen = Geom:new{
            w = available_width,
            h = Size.line.medium,
        },
    })

    local alias_face = Font:getFace("infofont")
        or Font:getFace("cfont")
        or Font:getFace("x_smallinfofont")
        or Font:getFace("infofont", 20)
        or Font:getFace("cfont", 20)
    local combined_text
    do
        local primary_tag_value, alias_list = self.manager:listAliases(tag, { context = context, document_id = group.document_id })
        alias_list = alias_list or {}
        for index, value in ipairs(alias_list) do
            alias_list[index] = util.trim(value)
        end
        combined_text = table.concat(alias_list, ", ")
        if combined_text == "" then
            combined_text = _("[No alias]")
        end
    end
    table.insert(heading_group, FrameContainer:new{
        padding = Size.padding.default,
        ScrollTextWidget:new{
            text = combined_text,
            face = alias_face,
            width = math.max(available_width - 2 * Size.padding.default, Size.padding.large * 2),
            height = math.max((alias_face and alias_face.size or Size.item.height_big) * 8, Size.item.height_big),
            dialog = dialog,
            alignment = "left",
        },
    })

    dialog:addWidget(heading_group)

    UIManager:show(dialog)
end

function Popup:show(tag, context, options)
    local group = self.manager:getOrCreateGroup(tag, { context = context })
    if not group then
        UIManager:show(ButtonDialog:new{
            title = _("Memo"),
            text = _("Unable to create or load memo group."),
            buttons = {
                {
                    {
                        text = _("Close"),
                    },
                },
            },
        })
        return
    end
    buildMultiNoteDialog(self, tag, group, context, options or {})
end

return Popup
