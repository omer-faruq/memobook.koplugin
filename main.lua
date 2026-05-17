local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local ButtonDialog = require("ui/widget/buttondialog")
local util = require("frontend/util")
local _ = require("gettext")

local MemoManager = require("memobook_manager")
local MemoPopup = require("memobook_popup")
local MemoListDialog = require("memobook_list_dialog")

local MemoBook = InputContainer:new{
    name = "memobook",
    is_doc_only = false,
}

local function normalizeForMemo(text)
    if type(text) ~= "string" then
        return nil, nil
    end
    local cleaned = util.cleanupSelectedText and util.cleanupSelectedText(text) or text
    local trimmed = util.trim(cleaned)
    if trimmed == "" then
        return nil, nil
    end
    local lowered = util.lower and util.lower(trimmed) or trimmed:lower()
    return trimmed, lowered
end

function MemoBook:init()
    self.manager = MemoManager:new()
    self.popup = MemoPopup:new(self.manager)
    self.list_dialog = MemoListDialog:new(self.manager, self.popup)
    if self.ui and self.ui.menu and self.ui.menu.registerToMainMenu then
        self.ui.menu:registerToMainMenu(self)
    end

    -- Register Memo button with new KOReader dict API (PR #15184+)
    -- Safe no-op on older versions where addToDictButtons doesn't exist.
    if self.ui and self.ui.dictionary
        and type(self.ui.dictionary.addToDictButtons) == "function" then
        self.ui.dictionary:addToDictButtons({
            id = "memobook_memo",
            text = _("Memo"),
            callback = self:_buildMemoDictButton(nil).callback,
            hold_callback = self:_buildMemoDictButton(nil).hold_callback,
        })
    end
end

function MemoBook:onReaderReady()
    if not self.ui or not self.ui.highlight then
        return
    end

    self.manager:setUI(self.ui)

    self.ui.highlight:addToHighlightDialog("memobook_button", function(reader_highlight)
        return {
            text = _("Memo"),
            callback = function()
                local selected = reader_highlight.selected_text and reader_highlight.selected_text.text
                if selected then
                    if reader_highlight.highlight_dialog then
                        UIManager:close(reader_highlight.highlight_dialog)
                        reader_highlight.highlight_dialog = nil
                    end
                    reader_highlight:clear()
                    self.popup:show(selected, self.manager:getActiveDocumentContext())
                else
                    UIManager:show(ButtonDialog:new{
                        title = _("Memo"),
                        text = _("No text selected."),
                        buttons = {{ { text = _("Close") } }},
                    })
                end
            end,
        }
    end)
end

function MemoBook:addToMainMenu(menu_items)
    menu_items.memobook = {
        sorting_hint = "tools",
        text = _("Memo Book"),
        callback = function()
            self.manager:setUI(self.ui)
            self.list_dialog:show({ context = self.manager:getActiveDocumentContext() })
        end,
    }
end

local function hasMemoButton(dict_buttons)
    for _, row in ipairs(dict_buttons) do
        for _, button in ipairs(row) do
            if button.id == "memobook_memo" then
                return true
            end
        end
    end
    return false
end

-- Builds the Memo button spec for the dict popup.
-- Used by both the new addToDictButtons API and the legacy onDictButtonsReady hook.
function MemoBook:_buildMemoDictButton(dict_popup_arg)
    -- dict_popup_arg is either:
    -- new API: the DictQuickLookup widget instance (passed by KOReader as arg to callback)
    -- old API: the dict_popup captured as upvalue in onDictButtonsReady
    return {
        text = _("Memo"),
        callback = function(widget_instance)
            -- In new API, widget_instance is passed. In old API, use upvalue.
            local popup = widget_instance or dict_popup_arg
            self.manager:setUI(self.ui)
            local highlight_source = popup and popup.highlight
                and popup.highlight.selected_text
                and popup.highlight.selected_text.text
            local highlight_text, highlight_norm = normalizeForMemo(highlight_source)
            local dict_source = popup and (popup.lookupword or popup.word or popup.displayword)
            local dict_text, dict_norm = normalizeForMemo(dict_source)
            local selected = highlight_text or dict_text
            if selected and selected ~= "" then
                if popup then
                    if popup.onClose then
                        popup:onClose()
                    else
                        UIManager:close(popup)
                    end
                end
                local options
                if highlight_text and dict_text and dict_norm and highlight_norm and dict_norm ~= highlight_norm then
                    options = { initial_alias = dict_text }
                end
                self.popup:show(selected, self.manager:getActiveDocumentContext(), options)
            else
                UIManager:show(ButtonDialog:new{
                    title = _("Memo"),
                    text = _("No text selected."),
                    buttons = {{ { text = _("Close") } }},
                })
            end
        end,
        hold_callback = function()
            self.list_dialog:show({ context = self.manager:getActiveDocumentContext() })
        end,
    }
end

function MemoBook:onDictButtonsReady(dict_popup, dict_buttons)
    if not dict_popup or not dict_buttons then
        return
    end
    if hasMemoButton(dict_buttons) then
        return
    end
    -- If new KOReader API is present, we already registered at init() time.
    -- This hook won't be called on new KOReader anyway, but guard for safety.
    if self.ui and self.ui.dictionary
        and type(self.ui.dictionary.addToDictButtons) == "function" then
        return
    end

    local btn = self:_buildMemoDictButton(dict_popup)
    local button_row = {
        {
            id = "memobook_memo",
            text = btn.text,
            callback = function() btn.callback(nil) end,
            hold_callback = btn.hold_callback,
        },
    }

    local insert_index = #dict_buttons
    if insert_index < 1 then
        table.insert(dict_buttons, button_row)
    else
        table.insert(dict_buttons, insert_index, button_row)
    end
end

function MemoBook:handleEvent(event)
    if event.type == "DictButtonsReady" then
        self:onDictButtonsReady(event.arg1, event.arg2)
        return true
    end
    return InputContainer.handleEvent(self, event)
end

return MemoBook
