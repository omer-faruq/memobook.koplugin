--[[--
Scrollable note list used by the memo popup when a keyword holds several notes.

Each note is rendered as a tappable row showing at most `max_lines` lines of
its text, instead of being crammed into a button label. The rows live in a
ScrollableContainer of bounded height, so the popup's action buttons stay
visible at the bottom no matter how many notes exist.

    local list, scrollable = NoteList.build{
        notes = group.notes,
        width = dialog:getAddedWidgetAvailableWidth(),
        show_parent = dialog,
        on_tap = function(index, note) ... end,
        on_hold = function(index, note) ... end,
    }
    dialog:addWidget(list)
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local InputContainer = require("ui/widget/container/inputcontainer")
local LineWidget = require("ui/widget/linewidget")
local ScrollableContainer = require("ui/widget/container/scrollablecontainer")
local Size = require("ui/size")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local util = require("util")
local _ = require("gettext")

local Screen = Device.screen

-- TextBoxWidget lays out its lines at round((1 + line_height) * face.size) px,
-- with line_height defaulting to 0.3 em; mirror that to cap a note at a given
-- number of lines (anything beyond gets an ellipsis).
local function heightForLines(face, lines)
    return math.floor(1.3 * face.size + 0.5) * lines
end

local NoteItem = InputContainer:extend{
    width = nil,
    text = nil,
    meta = nil,
    max_lines = 3,
    face = nil,
    meta_face = nil,
    show_parent = nil, -- the dialog holding the list, for cropped repaints
    callback = nil,
    hold_callback = nil,
}

function NoteItem:init()
    local padding = Size.padding.default
    local inner_width = self.width - 2 * padding

    local content = VerticalGroup:new{ align = "left" }
    if self.meta and self.meta ~= "" then
        table.insert(content, TextWidget:new{
            text = self.meta,
            face = self.meta_face,
            max_width = inner_width,
        })
        table.insert(content, VerticalSpan:new{ width = math.floor(padding / 2) })
    end
    table.insert(content, TextBoxWidget:new{
        text = self.text,
        face = self.face,
        width = inner_width,
        height = heightForLines(self.face, self.max_lines),
        height_adjust = true, -- shrink to the lines actually used
        height_overflow_show_ellipsis = true,
        alignment = "left",
    })

    self[1] = FrameContainer:new{
        padding = padding,
        margin = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        -- so UIManager:widgetInvert() clips our tap highlight to the scrolled view
        show_parent = self.show_parent,
        content,
    }

    -- Keep this Geom table across repaints: the gesture ranges below hold a
    -- reference to it, and InputContainer:paintTo() updates x/y in place.
    self.dimen = Geom:new{ x = 0, y = 0, w = self.width, h = self[1]:getSize().h }
    self.ges_events.Tap = {
        GestureRange:new{ ges = "tap", range = self.dimen },
    }
    self.ges_events.Hold = {
        GestureRange:new{ ges = "hold", range = self.dimen },
    }
end

function NoteItem:onTap()
    if not self.callback then
        return true
    end
    local frame = self[1]
    if not frame.dimen or (G_reader_settings and G_reader_settings:isFalse("flash_ui")) then
        self.callback()
        return true
    end
    -- Refresh only the part of the row that is actually visible: a row may be
    -- half-scrolled out of the list view.
    local region = frame.dimen
    local cropper = self.show_parent and self.show_parent.cropping_widget
    if cropper and cropper.getCropRegion then
        region = cropper:getCropRegion():intersect(region)
    end
    -- Flash the row, then run the callback (same feedback flow as MenuItem)
    frame.invert = true
    UIManager:widgetInvert(frame, frame.dimen.x, frame.dimen.y)
    UIManager:setDirty(nil, "fast", region)
    UIManager:forceRePaint()
    UIManager:yieldToEPDC()
    frame.invert = false
    UIManager:widgetInvert(frame, frame.dimen.x, frame.dimen.y)
    UIManager:setDirty(nil, "ui", region)
    self.callback()
    UIManager:forceRePaint()
    return true
end

function NoteItem:onHold()
    if self.hold_callback then
        self.hold_callback()
    end
    return true
end

local NoteList = {
    NoteItem = NoteItem,
}

--[[--
Builds the scrollable list widget.

@tparam table opts notes, width, show_parent, on_tap(index, note),
    and optionally on_hold(index, note), max_lines, max_height, meta_func
    (meta_func(note, index) adds a small header line above a row's text)
@treturn widget the widget to hand to ButtonDialog:addWidget()
@treturn boolean whether the list is taller than the view and thus scrolls
--]]
function NoteList.build(opts)
    local notes = opts.notes or {}
    local max_lines = opts.max_lines or 3
    local face = opts.face or Font:getFace("smallinfofont")
    local meta_face = opts.meta_face or Font:getFace("xx_smallinfofont")
    local max_height = opts.max_height or math.floor(Screen:getHeight() * 0.5)
    local meta_func = opts.meta_func

    -- Always leave room for the scrollbar so rows keep the same width whether
    -- or not the list ends up scrolling.
    local scrollbar_width = ScrollableContainer:getScrollbarWidth()
    local row_width = opts.width - scrollbar_width

    local rows = VerticalGroup:new{ align = "left" }
    for index, note in ipairs(notes) do
        if index > 1 then
            table.insert(rows, LineWidget:new{
                background = Blitbuffer.COLOR_GRAY,
                dimen = Geom:new{ w = row_width, h = Size.line.thin },
            })
        end
        local text = util.trim(note.text or "")
        if text == "" then
            text = _("[No note]")
        end
        table.insert(rows, NoteItem:new{
            width = row_width,
            text = text,
            meta = meta_func and meta_func(note, index) or nil,
            max_lines = max_lines,
            face = face,
            meta_face = meta_face,
            show_parent = opts.show_parent,
            callback = function()
                opts.on_tap(index, note)
            end,
            hold_callback = opts.on_hold and function()
                opts.on_hold(index, note)
            end or nil,
        })
    end

    local content_height = rows:getSize().h
    local view_height = math.min(content_height, max_height)
    local container = ScrollableContainer:new{
        dimen = Geom:new{ x = 0, y = 0, w = opts.width, h = view_height },
        show_parent = opts.show_parent,
        rows,
    }
    -- ButtonDialog would otherwise make the whole list a single focus cell.
    container.not_focusable = true

    return container, content_height > view_height
end

return NoteList
