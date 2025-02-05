const std = @import("std");
const lib = @import("../../main.zig");
const shared = @import("../shared.zig");
const os = @import("builtin").target.os;
const log = std.log.scoped(.win32);

const EventFunctions = shared.EventFunctions(@This());
const EventType = shared.BackendEventType;

const win32 = @import("win32.zig");
const gdi = @import("gdip.zig");
const HWND = win32.HWND;
const HINSTANCE = win32.HINSTANCE;
const RECT = win32.RECT;
const MSG = win32.MSG;
const WPARAM = win32.WPARAM;
const LPARAM = win32.LPARAM;
const LRESULT = win32.LRESULT;
const WINAPI = win32.WINAPI;

const Win32Error = error{ UnknownError, InitializationError };

pub const Capabilities = .{ .useEventLoop = true };

pub const PeerType = HWND;

var hInst: HINSTANCE = undefined;
/// By default, win32 controls use DEFAULT_GUI_FONT which is an outdated
/// font from Windows 95 days, by default it doesn't even use ClearType
/// anti-aliasing. So we take the real default caption font from
/// NONFCLIENTEMETRICS and apply it manually to every widget.
var captionFont: win32.HFONT = undefined;
var hasInit: bool = false;

pub fn init() !void {
    if (!hasInit) {
        hasInit = true;
        const hInstance = @ptrCast(win32.HINSTANCE, @alignCast(@alignOf(win32.HINSTANCE), win32.GetModuleHandleW(null).?));
        hInst = hInstance;

        if (os.isAtLeast(.windows, .win10_rs2).?) {
            // tell Windows that we support high-dpi
            if (win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) == 0) {
                log.warn("could not set dpi awareness mode; expect the windows to look blurry on high-dpi screens", .{});
            }
        }

        const initEx = win32.INITCOMMONCONTROLSEX{
            .dwSize = @sizeOf(win32.INITCOMMONCONTROLSEX),
            .dwICC = win32.ICC_STANDARD_CLASSES | win32.ICC_WIN95_CLASSES,
        };
        const code = win32.InitCommonControlsEx(&initEx);
        if (code == 0) {
            std.debug.print("Failed to initialize Common Controls.", .{});
        }

        var input = win32.GdiplusStartupInput{};
        try gdi.gdipWrap(win32.GdiplusStartup(&gdi.token, &input, null));
        
        var ncMetrics: win32.NONCLIENTMETRICSA = undefined;
        ncMetrics.cbSize = @sizeOf(win32.NONCLIENTMETRICSA);
        _ = win32.SystemParametersInfoA(win32.SPI_GETNONCLIENTMETRICS,
            @sizeOf(win32.NONCLIENTMETRICSA),
            &ncMetrics,
            0);
        captionFont = win32.CreateFontIndirectA(&ncMetrics.lfCaptionFont).?;
    }
}

pub const MessageType = enum { Information, Warning, Error };

pub fn showNativeMessageDialog(msgType: MessageType, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrintZ(lib.internal.scratch_allocator, fmt, args) catch {
        std.log.err("Could not launch message dialog, original text: " ++ fmt, args);
        return;
    };
    defer lib.internal.scratch_allocator.free(msg);

    const icon: u32 = switch (msgType) {
        .Information => win32.MB_ICONINFORMATION,
        .Warning => win32.MB_ICONWARNING,
        .Error => win32.MB_ICONERROR,
    };

    _ = win32.messageBoxA(null, msg, "Dialog", icon) catch {
        std.log.err("Could not launch message dialog, original text: " ++ fmt, args);
        return;
    };
}

var defaultWHWND: HWND = undefined;

pub const Window = struct {
    hwnd: HWND,
    source_dpi: u32 = 96,

    const className = "capyWClass";

    fn relayoutChild(hwnd: HWND, lp: LPARAM) callconv(WINAPI) c_int {
        const parent = @intToPtr(HWND, @bitCast(usize, lp));
        if (win32.GetParent(hwnd) != parent) {
            return 1; // ignore recursive childrens
        }

        var rect: RECT = undefined;
        _ = win32.GetClientRect(parent, &rect);
        _ = win32.MoveWindow(hwnd, 0, 0, rect.right - rect.left, rect.bottom - rect.top, 1);
        return 1;
    }

    fn process(hwnd: HWND, wm: c_uint, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
        switch (wm) {
            win32.WM_SIZE => {
                _ = win32.EnumChildWindows(hwnd, relayoutChild, @bitCast(isize, @ptrToInt(hwnd)));
            },
            win32.WM_DPICHANGED => {
                // TODO: update scale factor
            },
            else => {},
        }
        return win32.DefWindowProcA(hwnd, wm, wp, lp);
    }

    pub fn create() !Window {
        var wc: win32.WNDCLASSEXA = .{
            .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
            .lpfnWndProc = process,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hInst,
            .hIcon = null, // TODO: LoadIcon
            .hCursor = null, // TODO: LoadCursor
            .hbrBackground = win32.GetSysColorBrush(win32.COLOR_3DFACE),
            .lpszMenuName = null,
            .lpszClassName = className,
            .hIconSm = null,
        };

        if ((try win32.registerClassExA(&wc)) == 0) {
            showNativeMessageDialog(.Error, "Could not register window class {s}", .{className});
            return Win32Error.InitializationError;
        }

        const hwnd = try win32.createWindowExA(win32.WS_EX_LEFT | win32.WS_EX_COMPOSITED | win32.WS_EX_LAYERED, // dwExtStyle
            className, // lpClassName
            "", // lpWindowName
            win32.WS_OVERLAPPEDWINDOW, // dwStyle
            win32.CW_USEDEFAULT, // X
            win32.CW_USEDEFAULT, // Y
            win32.CW_USEDEFAULT, // nWidth
            win32.CW_USEDEFAULT, // nHeight
            null, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );

        defaultWHWND = hwnd;
        return Window{ .hwnd = hwnd };
    }

    // TODO: handle the fact that ONLY the root child must forcibly draw a background
    pub fn setChild(self: *Window, hwnd: ?HWND) void {
        // TODO: if null, remove child
        _ = win32.SetParent(hwnd.?, self.hwnd);
        const style = win32.GetWindowLongPtr(hwnd.?, win32.GWL_STYLE);
        win32.SetWindowLongPtr(hwnd.?, win32.GWL_STYLE, style | win32.WS_CHILD);
        _ = win32.showWindow(hwnd.?, win32.SW_SHOWDEFAULT);
        _ = win32.UpdateWindow(hwnd.?);
    }

    pub fn resize(self: *Window, width: c_int, height: c_int) void {
        var rect: RECT = undefined;
        _ = win32.GetWindowRect(self.hwnd, &rect);
        _ = win32.MoveWindow(self.hwnd, rect.left, rect.top, @intCast(c_int, width), @intCast(c_int, height), 1);
    }

    pub fn setTitle(self: *Window, title: [*:0]const u8) void {
        const utf16 = std.unicode.utf8ToUtf16LeWithNull(lib.internal.scratch_allocator, std.mem.span(title)) catch return;
        defer lib.internal.scratch_allocator.free(utf16);

        _ = win32.SetWindowTextW(self.hwnd, utf16);
    }

    pub fn setSourceDpi(self: *Window, dpi: u32) void {
        self.source_dpi = dpi;
    }

    pub fn show(self: *Window) void {
        _ = win32.showWindow(self.hwnd, win32.SW_SHOWDEFAULT);
        _ = win32.UpdateWindow(self.hwnd);
    }

    pub fn close(self: *Window) void {
        _ = win32.showWindow(self.hwnd, win32.SW_HIDE);
        _ = win32.UpdateWindow(self.hwnd);
    }
};

const EventUserData = struct {
    user: EventFunctions = .{},
    class: EventFunctions = .{},
    userdata: usize = 0,
    classUserdata: usize = 0,
    // (very) weak method to detect if a text box's text has actually changed
    last_text_len: win32.INT = 0,
};

inline fn getEventUserData(peer: HWND) *EventUserData {
    return @intToPtr(*EventUserData, win32.GetWindowLongPtr(peer, win32.GWL_USERDATA));
}

pub fn Events(comptime T: type) type {
    return struct {
        const Self = @This();

        pub fn process(hwnd: HWND, wm: c_uint, wp: WPARAM, lp: LPARAM) callconv(WINAPI) LRESULT {
            switch (wm) {
                win32.WM_NOTIFY => {
                    const nmhdr = @intToPtr(*const win32.NMHDR, @bitCast(usize, lp));
                    //std.log.info("code = {d} vs {d}", .{ nmhdr.code, win32.TCN_SELCHANGING });
                    switch (nmhdr.code) {
                        win32.TCN_SELCHANGING => {
                            return 0;
                        },
                        else => {},
                    }
                },
                else => {},
            }
            if (win32.GetWindowLongPtr(hwnd, win32.GWL_USERDATA) == 0) return win32.DefWindowProcA(hwnd, wm, wp, lp);
            switch (wm) {
                win32.WM_COMMAND => {
                    const code = @intCast(u16, wp >> 16);
                    const data = getEventUserData(@intToPtr(HWND, @bitCast(usize, lp)));
                    switch (code) {
                        win32.BN_CLICKED => {
                            if (data.user.clickHandler) |handler|
                                handler(data.userdata);
                        },
                        win32.EN_CHANGE => {
                            // Doesn't appear to work.
                            if (data.user.changedTextHandler) |handler|
                                handler(data.userdata);
                        },
                        else => {},
                    }
                },
                win32.WM_CTLCOLOREDIT => {
                    const data = getEventUserData(@intToPtr(HWND, @bitCast(usize, lp)));
                    const len = win32.GetWindowTextLengthW(@intToPtr(HWND, @bitCast(usize, lp)));
                    // The text box may have changed
                    // TODO: send the event only when the text truly changed
                    if (data.last_text_len != len) {
                        if (data.user.changedTextHandler) |handler|
                            handler(data.userdata);
                        data.last_text_len = len;
                    }
                },
                win32.WM_NOTIFY => {
                    const nmhdr = @intToPtr(*const win32.NMHDR, @bitCast(usize, lp));
                    //std.log.info("code = {d} vs {d}", .{ nmhdr.code, win32.TCN_SELCHANGING });
                    switch (nmhdr.code) {
                        win32.TCN_SELCHANGING => {
                            return 0;
                        },
                        else => {},
                    }
                },
                win32.WM_SIZE => {
                    const data = getEventUserData(hwnd);
                    if (@hasDecl(T, "onResize")) {
                        T.onResize(data, hwnd);
                    }
                    var rect: RECT = undefined;
                    _ = win32.GetWindowRect(hwnd, &rect);

                    if (data.class.resizeHandler) |handler|
                        handler(@intCast(u32, rect.right - rect.left), @intCast(u32, rect.bottom - rect.top), data.userdata);
                    if (data.user.resizeHandler) |handler|
                        handler(@intCast(u32, rect.right - rect.left), @intCast(u32, rect.bottom - rect.top), data.userdata);
                },
                win32.WM_PAINT => {
                    const data = getEventUserData(hwnd);
                    var ps: win32.PAINTSTRUCT = undefined;
                    var hdc: win32.HDC = win32.BeginPaint(hwnd, &ps);
                    defer _ = win32.EndPaint(hwnd, &ps);
                    var graphics = gdi.Graphics.createFromHdc(hdc) catch unreachable;

                    const brush = @ptrCast(win32.HBRUSH, win32.GetStockObject(win32.DC_BRUSH));
                    win32.SelectObject(hdc, @ptrCast(win32.HGDIOBJ, brush));

                    var dc = Canvas.DrawContext{ .hdc = hdc, .graphics = graphics, .hbr = brush, .path = std.ArrayList(Canvas.DrawContext.PathElement)
                        .init(lib.internal.scratch_allocator) };
                    defer dc.path.deinit();

                    if (data.class.drawHandler) |handler|
                        handler(&dc, data.userdata);
                    if (data.user.drawHandler) |handler|
                        handler(&dc, data.userdata);
                },
                win32.WM_DESTROY => win32.PostQuitMessage(0),
                else => {},
            }
            return win32.DefWindowProcA(hwnd, wm, wp, lp);
        }

        pub fn setupEvents(peer: HWND) !void {
            var data = try lib.internal.lasting_allocator.create(EventUserData);
            data.* = EventUserData{}; // ensure that it uses default values
            win32.SetWindowLongPtr(peer, win32.GWL_USERDATA, @ptrToInt(data));
        }

        pub inline fn setUserData(self: *T, data: anytype) void {
            comptime {
                if (!std.meta.trait.isSingleItemPtr(@TypeOf(data))) {
                    @compileError(std.fmt.comptimePrint("Expected single item pointer, got {s}", .{@typeName(@TypeOf(data))}));
                }
            }
            getEventUserData(self.peer).userdata = @ptrToInt(data);
        }

        pub inline fn setCallback(self: *T, comptime eType: EventType, cb: anytype) !void {
            const data = getEventUserData(self.peer);
            switch (eType) {
                .Click => data.user.clickHandler = cb,
                .Draw => data.user.drawHandler = cb,
                .MouseButton => data.user.mouseButtonHandler = cb,
                // TODO: implement mouse motion
                .MouseMotion => data.user.mouseMotionHandler = cb,
                .Scroll => data.user.scrollHandler = cb,
                .TextChanged => data.user.changedTextHandler = cb,
                .Resize => data.user.resizeHandler = cb,
                .KeyType => data.user.keyTypeHandler = cb,
                .KeyPress => data.user.keyPressHandler = cb,
            }
        }

        /// Requests a redraw
        pub fn requestDraw(self: *T) !void {
            var updateRect: RECT = undefined;
            updateRect = .{ .left = 0, .top = 0, .right = 10000, .bottom = 10000 };
            if (win32.InvalidateRect(self.peer, &updateRect, 0) == 0) {
                return Win32Error.UnknownError;
            }
            if (win32.UpdateWindow(self.peer) == 0) {
                return Win32Error.UnknownError;
            }
        }

        pub fn getWidth(self: *const T) c_int {
            var rect: RECT = undefined;
            _ = win32.GetWindowRect(self.peer, &rect);
            return rect.right - rect.left;
        }

        pub fn getHeight(self: *const T) c_int {
            var rect: RECT = undefined;
            _ = win32.GetWindowRect(self.peer, &rect);
            return rect.bottom - rect.top;
        }

        pub fn getPreferredSize(self: *const T) lib.Size {
            // TODO
            _ = self;
            return lib.Size.init(100, 50);
        }

        pub fn setOpacity(self: *const T, opacity: f64) void {
            _ = self;
            _ = opacity;
            // TODO
        }

        pub fn deinit(self: *const T) void {
            _ = self;
            // TODO
        }
    };
}

pub const MouseButton = enum { Left, Middle, Right };

pub const Canvas = struct {
    peer: HWND,
    data: usize = 0,

    pub usingnamespace Events(Canvas);

    pub const DrawContext = struct {
        hdc: win32.HDC,
        graphics: gdi.Graphics,
        hbr: win32.HBRUSH,
        path: std.ArrayList(PathElement),

        const PathElement = union(enum) { SetColor: win32.COLORREF, Rectangle: struct { left: c_int, top: c_int, right: c_int, bottom: c_int } };

        pub const TextLayout = struct {
            font: win32.HFONT,
            /// HDC only used for getting text metrics
            hdc: win32.HDC,
            /// If null, no text wrapping is applied, otherwise the text is wrapping as if this was the maximum width.
            /// TODO: this is not yet implemented in the win32 backend
            wrap: ?f64 = null,

            pub const Font = struct {
                face: [:0]const u8,
                size: f64,
            };

            pub const TextSize = struct { width: u32, height: u32 };

            pub fn init() TextLayout {
                // creates an HDC for the current screen, whatever it means given we can have windows on different screens
                const hdc = win32.CreateCompatibleDC(null).?;

                const defaultFont = @ptrCast(win32.HFONT, win32.GetStockObject(win32.DEFAULT_GUI_FONT));
                win32.SelectObject(hdc, @ptrCast(win32.HGDIOBJ, defaultFont));
                return TextLayout{ .font = defaultFont, .hdc = hdc };
            }

            pub fn setFont(self: *TextLayout, font: Font) void {
                // _ = win32.DeleteObject(@ptrCast(win32.HGDIOBJ, self.font)); // delete old font
                if (win32.CreateFontA(0, // cWidth
                    0, // cHeight
                    0, // cEscapement,
                    0, // cOrientation,
                    win32.FW_NORMAL, // cWeight
                    0, // bItalic
                    0, // bUnderline
                    0, // bStrikeOut
                    0, // iCharSet
                    0, // iOutPrecision
                    0, // iClipPrecision
                    0, // iQuality
                    0, // iPitchAndFamily
                    font.face // pszFaceName
                )) |winFont| {
                    _ = win32.DeleteObject(@ptrCast(win32.HGDIOBJ, self.font));
                    self.font = winFont;
                }
                win32.SelectObject(self.hdc, @ptrCast(win32.HGDIOBJ, self.font));
            }

            pub fn getTextSize(self: *TextLayout, str: []const u8) TextSize {
                var size: win32.SIZE = undefined;
                _ = win32.GetTextExtentPoint32A(self.hdc, str.ptr, @intCast(c_int, str.len), &size);

                return TextSize{ .width = @intCast(u32, size.cx), .height = @intCast(u32, size.cy) };
            }

            pub fn deinit(self: *TextLayout) void {
                _ = win32.DeleteObject(@ptrCast(win32.HGDIOBJ, self.hdc));
                _ = win32.DeleteObject(@ptrCast(win32.HGDIOBJ, self.font));
            }
        };

        // TODO: transparency support using https://docs.microsoft.com/en-us/windows/win32/api/wingdi/nf-wingdi-alphablend
        // or use GDI+ and https://docs.microsoft.com/en-us/windows/win32/gdiplus/-gdiplus-drawing-with-opaque-and-semitransparent-brushes-use
        pub fn setColorByte(self: *DrawContext, color: lib.Color) void {
            const colorref: win32.COLORREF = (@as(win32.COLORREF, color.blue) << 16) |
                (@as(win32.COLORREF, color.green) << 8) | color.red;
            _ = win32.SetDCBrushColor(self.hdc, colorref);
        }

        pub fn setColor(self: *DrawContext, r: f32, g: f32, b: f32) void {
            self.setColorRGBA(r, g, b, 1);
        }

        pub fn setColorRGBA(self: *DrawContext, r: f32, g: f32, b: f32, a: f32) void {
            self.setColorByte(.{ .red = @floatToInt(u8, r * 255), .green = @floatToInt(u8, g * 255), .blue = @floatToInt(u8, b * 255), .alpha = @floatToInt(u8, a * 255) });
        }

        pub fn rectangle(self: *DrawContext, x: u32, y: u32, w: u32, h: u32) void {
            _ = win32.Rectangle(self.hdc, @intCast(c_int, x), @intCast(c_int, y), @intCast(c_int, x + w), @intCast(c_int, y + h));
        }

        pub fn ellipse(self: *DrawContext, x: u32, y: u32, w: f32, h: f32) void {
            const cw = @floatToInt(c_int, w);
            const ch = @floatToInt(c_int, h);

            _ = win32.Ellipse(self.hdc, @intCast(c_int, x) - cw, @intCast(c_int, y) - ch, @intCast(c_int, x) + cw * 2, @intCast(c_int, y) + ch * 2);
        }

        pub fn text(self: *DrawContext, x: i32, y: i32, layout: TextLayout, str: []const u8) void {
            // select current color
            const color = win32.GetDCBrushColor(self.hdc);
            _ = win32.SetTextColor(self.hdc, color);

            // select the font
            win32.SelectObject(self.hdc, @ptrCast(win32.HGDIOBJ, layout.font));

            // and draw
            _ = win32.ExtTextOutA(self.hdc, @intCast(c_int, x), @intCast(c_int, y), 0, null, str.ptr, @intCast(std.os.windows.UINT, str.len), null);
        }

        pub fn line(self: *DrawContext, x1: u32, y1: u32, x2: u32, y2: u32) void {
            _ = win32.MoveToEx(self.hdc, @intCast(c_int, x1), @intCast(c_int, y1), null);
            _ = win32.LineTo(self.hdc, @intCast(c_int, x2), @intCast(c_int, y2));
        }

        pub fn fill(self: *DrawContext) void {
            self.path.clearRetainingCapacity();
        }

        pub fn stroke(self: *DrawContext) void {
            self.path.clearRetainingCapacity();
        }
    };

    var classRegistered = false;

    pub fn create() !Canvas {
        if (!classRegistered) {
            var wc: win32.WNDCLASSEXA = .{
                .style = win32.CS_HREDRAW | win32.CS_VREDRAW,
                .lpfnWndProc = Canvas.process,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = hInst,
                .hIcon = null, // TODO: LoadIcon
                .hCursor = null, // TODO: LoadCursor
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = "zgtCanvasClass",
                .hIconSm = null,
            };

            if ((try win32.registerClassExA(&wc)) == 0) {
                showNativeMessageDialog(.Error, "Could not register window class {s}", .{"zgtCanvasClass"});
                return Win32Error.InitializationError;
            }
            classRegistered = true;
        }

        const hwnd = try win32.createWindowExA(win32.WS_EX_LEFT, // dwExtStyle
            "zgtCanvasClass", // lpClassName
            "", // lpWindowName
            win32.WS_TABSTOP | win32.WS_CHILD, // dwStyle
            10, // X
            10, // Y
            100, // nWidth
            100, // nHeight
            defaultWHWND, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );
        try Canvas.setupEvents(hwnd);

        return Canvas{ .peer = hwnd };
    }
};

pub const TextField = struct {
    peer: HWND,
    arena: std.heap.ArenaAllocator,

    pub usingnamespace Events(TextField);

    pub fn create() !TextField {
        const hwnd = try win32.createWindowExA(win32.WS_EX_LEFT, // dwExtStyle
            "EDIT", // lpClassName
            "", // lpWindowName
            win32.WS_TABSTOP | win32.WS_CHILD | win32.WS_BORDER, // dwStyle
            10, // X
            10, // Y
            100, // nWidth
            100, // nHeight
            defaultWHWND, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );
        try TextField.setupEvents(hwnd);
        _ = win32.SendMessageA(hwnd, win32.WM_SETFONT, @ptrToInt(captionFont), 1);

        return TextField{ .peer = hwnd, .arena = std.heap.ArenaAllocator.init(lib.internal.lasting_allocator) };
    }

    pub fn setText(self: *TextField, text: []const u8) void {
        const allocator = lib.internal.scratch_allocator;
        const wide = std.unicode.utf8ToUtf16LeWithNull(allocator, text) catch return; // invalid utf8 or not enough memory
        defer allocator.free(wide);
        if (win32.SetWindowTextW(self.peer, wide) == 0) {
            std.os.windows.unexpectedError(win32.GetLastError()) catch {};
        }
        
        const len = win32.GetWindowTextLengthW(self.peer);
        getEventUserData(self.peer).last_text_len = len;
    }

    pub fn getText(self: *TextField) [:0]const u8 {
        const allocator = self.arena.allocator();
        const len = win32.GetWindowTextLengthW(self.peer);
        var buf = allocator.allocSentinel(u16, @intCast(usize, len), 0) catch unreachable; // TODO return error
        defer allocator.free(buf);
        const realLen = @intCast(usize, win32.GetWindowTextW(self.peer, buf.ptr, len + 1));
        const utf16Slice = buf[0..realLen];
        const text = std.unicode.utf16leToUtf8AllocZ(allocator, utf16Slice) catch unreachable; // TODO return error
        return text;
    }

    pub fn setReadOnly(self: *TextField, readOnly: bool) void {
        _ = win32.SendMessageA(self.peer, win32.EM_SETREADONLY, @boolToInt(readOnly), undefined);
    }
};

pub const Button = struct {
    peer: HWND,
    arena: std.heap.ArenaAllocator,

    pub usingnamespace Events(Button);

    pub fn create() !Button {
        const hwnd = try win32.createWindowExA(win32.WS_EX_LEFT, // dwExtStyle
            "BUTTON", // lpClassName
            "", // lpWindowName
            win32.WS_TABSTOP | win32.WS_CHILD | win32.BS_PUSHBUTTON | win32.BS_FLAT, // dwStyle
            10, // X
            10, // Y
            100, // nWidth
            100, // nHeight
            defaultWHWND, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );
        try Button.setupEvents(hwnd);
        _ = win32.SendMessageA(hwnd, win32.WM_SETFONT, @ptrToInt(captionFont), 1);

        return Button{ .peer = hwnd, .arena = std.heap.ArenaAllocator.init(lib.internal.lasting_allocator) };
    }

    pub fn setLabel(self: *Button, label: [:0]const u8) void {
        const allocator = lib.internal.scratch_allocator;
        const wide = std.unicode.utf8ToUtf16LeWithNull(allocator, label) catch return; // invalid utf8 or not enough memory
        defer allocator.free(wide);
        if (win32.SetWindowTextW(self.peer, wide) == 0) {
            std.os.windows.unexpectedError(win32.GetLastError()) catch {};
        }
    }

    pub fn getLabel(self: *Button) [:0]const u8 {
        const allocator = self.arena.allocator();
        const len = win32.GetWindowTextLengthW(self.peer);
        var buf = allocator.allocSentinel(u16, @intCast(usize, len), 0) catch unreachable; // TODO return error
        defer allocator.free(buf);
        const realLen = @intCast(usize, win32.GetWindowTextW(self.peer, buf.ptr, len + 1));
        const utf16Slice = buf[0..realLen];
        const text = std.unicode.utf16leToUtf8AllocZ(allocator, utf16Slice) catch unreachable; // TODO return error
        return text;
    }
};

pub const Label = struct {
    peer: HWND,
    arena: std.heap.ArenaAllocator,

    pub usingnamespace Events(Label);

    pub fn create() !Label {
        const hwnd = try win32.createWindowExA(win32.WS_EX_LEFT, // dwExtStyle
            "STATIC", // lpClassName
            "", // lpWindowName
            win32.WS_TABSTOP | win32.WS_CHILD | win32.SS_CENTERIMAGE, // dwStyle
            10, // X
            10, // Y
            100, // nWidth
            100, // nHeight
            defaultWHWND, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );
        try Label.setupEvents(hwnd);
        _ = win32.SendMessageA(hwnd, win32.WM_SETFONT, @ptrToInt(captionFont), 1);

        return Label{ .peer = hwnd, .arena = std.heap.ArenaAllocator.init(lib.internal.lasting_allocator) };
    }

    pub fn setAlignment(self: *Label, alignment: f32) void {
        _ = self;
        _ = alignment;
    }

    pub fn setText(self: *Label, text: [:0]const u8) void {
        const allocator = lib.internal.scratch_allocator;
        const wide = std.unicode.utf8ToUtf16LeWithNull(allocator, text) catch return; // invalid utf8 or not enough memory
        defer allocator.free(wide);
        if (win32.SetWindowTextW(self.peer, wide) == 0) {
            std.os.windows.unexpectedError(win32.GetLastError()) catch {};
        }
    }

    pub fn getText(self: *Label) [:0]const u8 {
        const allocator = self.arena.allocator();
        const len = win32.GetWindowTextLengthW(self.peer);
        var buf = allocator.allocSentinel(u16, @intCast(usize, len), 0) catch unreachable; // TODO return error
        defer allocator.free(buf);
        const utf16Slice = buf[0..@intCast(usize, win32.GetWindowTextW(self.peer, buf.ptr, len + 1))];
        return std.unicode.utf16leToUtf8AllocZ(allocator, utf16Slice) catch unreachable; // TODO return error
    }

    pub fn destroy(self: *Label) void {
        self.arena.deinit();
    }
};

pub const TabContainer = struct {
    /// Container that contains the tab control because win32 requires that
    peer: HWND,
    /// The actual tab control
    tabControl: HWND,
    arena: std.heap.ArenaAllocator,

    pub usingnamespace Events(TabContainer);

    var classRegistered = false;

    pub fn create() !TabContainer {
        if (!classRegistered) {
            var wc: win32.WNDCLASSEXA = .{
                .style = 0,
                .lpfnWndProc = TabContainer.process,
                .hInstance = hInst,
                .hIcon = null, // TODO: LoadIcon
                .hCursor = null, // TODO: LoadCursor
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = "zgtTabClass",
                .hIconSm = null,
            };

            if ((try win32.registerClassExA(&wc)) == 0) {
                showNativeMessageDialog(.Error, "Could not register window class zgtTabClass", .{});
                return Win32Error.InitializationError;
            }
            classRegistered = true;
        }

        const wrapperHwnd = try win32.createWindowExA(win32.WS_EX_LEFT, // dwExtStyle
            "zgtTabClass", // lpClassName
            "", // lpWindowName
            win32.WS_TABSTOP | win32.WS_CHILD | win32.WS_CLIPCHILDREN, // dwStyle
            10, // X
            10, // Y
            100, // nWidth
            100, // nHeight
            defaultWHWND, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );

        const hwnd = try win32.createWindowExA(win32.WS_EX_LEFT, // dwExtStyle
            "SysTabControl32", // lpClassName
            "", // lpWindowName
            win32.WS_TABSTOP | win32.WS_CHILD | win32.WS_CLIPSIBLINGS, // dwStyle
            10, // X
            10, // Y
            100, // nWidth
            100, // nHeight
            defaultWHWND, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );
        try TabContainer.setupEvents(wrapperHwnd);
        _ = win32.SendMessageA(hwnd, win32.WM_SETFONT, @ptrToInt(captionFont), 0);
        _ = win32.SetParent(hwnd, wrapperHwnd);
        _ = win32.showWindow(hwnd, win32.SW_SHOWDEFAULT);
        _ = win32.UpdateWindow(hwnd);

        return TabContainer{ .peer = wrapperHwnd, .tabControl = hwnd, .arena = std.heap.ArenaAllocator.init(lib.internal.lasting_allocator) };
    }

    pub fn insert(self: *const TabContainer, position: usize, peer: PeerType) usize {
        const item = win32.TCITEMA{ .mask = 0 };
        const newIndex = win32.TabCtrl_InsertItemA(self.tabControl, @intCast(c_int, position), &item);
        _ = peer;
        return @intCast(usize, newIndex);
    }

    pub fn setLabel(self: *const TabContainer, position: usize, text: [:0]const u8) void {
        const item = win32.TCITEMA{
            .mask = win32.TCIF_TEXT, // only change the text attribute
            .pszText = text,
            // cchTextMax doesn't need to be set when using SetItem
        };
        win32.TabCtrl_SetItemA(self.tabControl, @intCast(c_int, position), &item);
    }

    pub fn getTabsNumber(self: *const TabContainer) usize {
        return @bitCast(usize, win32.TabCtrl_GetItemCount(self.tabControl));
    }

    fn onResize(_: *EventUserData, hwnd: HWND) void {
        var rect: RECT = undefined;
        _ = win32.GetWindowRect(hwnd, &rect);
        const child = win32.GetWindow(hwnd, win32.GW_CHILD);
        _ = win32.MoveWindow(child, 0, 0, rect.right - rect.left, rect.bottom - rect.top, 1);
    }
};

const ContainerStruct = struct { hwnd: HWND, count: usize, index: usize };

pub const Container = struct {
    peer: HWND,

    pub usingnamespace Events(Container);

    var classRegistered = false;

    pub fn create() !Container {
        if (!classRegistered) {
            var wc: win32.WNDCLASSEXA = .{
                .style = 0,
                .lpfnWndProc = Container.process,
                .cbClsExtra = 0,
                .cbWndExtra = 0,
                .hInstance = hInst,
                .hIcon = null, // TODO: LoadIcon
                .hCursor = null, // TODO: LoadCursor
                .hbrBackground = null,
                .lpszMenuName = null,
                .lpszClassName = "zgtContainerClass",
                .hIconSm = null,
            };

            if ((try win32.registerClassExA(&wc)) == 0) {
                showNativeMessageDialog(.Error, "Could not register window class {s}", .{"zgtContainerClass"});
                return Win32Error.InitializationError;
            }
            classRegistered = true;
        }

        const hwnd = try win32.createWindowExA(win32.WS_EX_LEFT, // dwExtStyle
            "zgtContainerClass", // lpClassName
            "", // lpWindowName
            win32.WS_TABSTOP | win32.WS_CHILD | win32.WS_CLIPCHILDREN, // dwStyle
            10, // X
            10, // Y
            100, // nWidth
            100, // nHeight
            defaultWHWND, // hWindParent
            null, // hMenu
            hInst, // hInstance
            null // lpParam
        );
        try Container.setupEvents(hwnd);

        return Container{ .peer = hwnd };
    }

    pub fn add(self: *Container, peer: PeerType) void {
        _ = win32.SetParent(peer, self.peer);
        const style = win32.GetWindowLongPtr(peer, win32.GWL_STYLE);
        win32.SetWindowLongPtr(peer, win32.GWL_STYLE, style | win32.WS_CHILD);
        _ = win32.showWindow(peer, win32.SW_SHOWDEFAULT);
        _ = win32.UpdateWindow(peer);
    }

    pub fn move(self: *const Container, peer: PeerType, x: u32, y: u32) void {
        _ = self;
        var rect: RECT = undefined;
        _ = win32.GetWindowRect(peer, &rect);
        _ = win32.MoveWindow(peer, @intCast(c_int, x), @intCast(c_int, y), rect.right - rect.left, rect.bottom - rect.top, 1);
    }

    pub fn resize(self: *const Container, peer: PeerType, width: u32, height: u32) void {
        var rect: RECT = undefined;
        _ = win32.GetWindowRect(peer, &rect);
        if (rect.right - rect.left == width and rect.bottom - rect.top == height) {
            return;
        }

        var parent: RECT = undefined;
        _ = win32.GetWindowRect(self.peer, &parent);
        _ = win32.MoveWindow(peer, rect.left - parent.left, rect.top - parent.top, @intCast(c_int, width), @intCast(c_int, height), 1);

        rect.bottom -= rect.top;
        rect.right -= rect.left;
        rect.top = 0;
        rect.left = 0;
        //_ = win32.InvalidateRect(self.peer, &rect, 0);
        _ = win32.UpdateWindow(peer);
    }
};

pub fn runStep(step: shared.EventLoopStep) bool {
    var msg: MSG = undefined;
    switch (step) {
        .Blocking => {
            if (win32.GetMessageA(&msg, null, 0, 0) <= 0) {
                return false; // error or WM_QUIT message
            }
        },
        .Asynchronous => {
            if (win32.PeekMessageA(&msg, null, 0, 0, 1) == 0) {
                return true; // no message available
            }
        },
    }

    if ((msg.message & 0xFF) == 0x012) { // WM_QUIT
        return false;
    }
    _ = win32.TranslateMessage(&msg);
    _ = win32.DispatchMessageA(&msg);
    return true;
}
