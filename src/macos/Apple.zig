const std = @import("std");
const Apple = @This();

const CFIndex = c_long;
const CFStringEncoding = u32;
const CTFontSymbolicTraits = u32;
const CTFontOrientation = u32;
const CGGlyph = u16;

const CFStringRef = *anyopaque;
const CTFontDescriptorRef = *anyopaque;
const CTFontRef = *anyopaque;
const CGColorSpaceRef = *anyopaque;
const CGContextRef = *anyopaque;

extern "c" fn CFStringCreateWithBytes(
    allocator: ?*anyopaque,
    bytes: [*]const u8,
    count: CFIndex,
    encoding: CFStringEncoding,
    external_representation: bool,
) ?CFStringRef;
extern "c" fn CFStringCreateWithCharacters(
    allocator: ?*anyopaque,
    characters: [*]const u16,
    count: CFIndex,
) ?CFStringRef;
extern "c" fn CFRelease(value: *anyopaque) void;
extern "c" fn CFRetain(value: *anyopaque) *anyopaque;

extern "c" fn CTFontDescriptorCreateWithNameAndSize(name: CFStringRef, size: f64) ?CTFontDescriptorRef;
extern "c" fn CTFontCreateWithFontDescriptor(
    descriptor: CTFontDescriptorRef,
    size: f64,
    matrix: ?*const AffineTransform,
) ?CTFontRef;
extern "c" fn CTFontCreateCopyWithSymbolicTraits(
    font: CTFontRef,
    size: f64,
    matrix: ?*const AffineTransform,
    value: CTFontSymbolicTraits,
    mask: CTFontSymbolicTraits,
) ?CTFontRef;
extern "c" fn CTFontCreateForString(font: CTFontRef, string: CFStringRef, range: Range) ?CTFontRef;
extern "c" fn CTFontGetGlyphsForCharacters(
    font: CTFontRef,
    characters: [*]const u16,
    glyphs: [*]CGGlyph,
    count: CFIndex,
) bool;
extern "c" fn CTFontGetAdvancesForGlyphs(
    font: CTFontRef,
    orientation: CTFontOrientation,
    glyphs: [*]const CGGlyph,
    advances: ?[*]Size,
    count: CFIndex,
) f64;
extern "c" fn CTFontDrawGlyphs(
    font: CTFontRef,
    glyphs: [*]const CGGlyph,
    positions: [*]const Point,
    count: usize,
    context: CGContextRef,
) void;
extern "c" fn CTFontGetAscent(font: CTFontRef) f64;
extern "c" fn CTFontGetDescent(font: CTFontRef) f64;
extern "c" fn CTFontGetLeading(font: CTFontRef) f64;
extern "c" fn CTFontGetUnderlinePosition(font: CTFontRef) f64;
extern "c" fn CTFontGetUnderlineThickness(font: CTFontRef) f64;
extern "c" fn CTFontGetXHeight(font: CTFontRef) f64;

extern "c" fn CGColorSpaceCreateDeviceRGB() ?CGColorSpaceRef;
extern "c" fn CGColorSpaceRelease(space: CGColorSpaceRef) void;
extern "c" fn CGBitmapContextCreate(
    data: ?*anyopaque,
    width: usize,
    height: usize,
    bits_per_component: usize,
    bytes_per_row: usize,
    color_space: CGColorSpaceRef,
    bitmap_info: u32,
) ?CGContextRef;
extern "c" fn CGContextRelease(context: CGContextRef) void;
extern "c" fn CGContextSetAllowsAntialiasing(context: CGContextRef, value: bool) void;
extern "c" fn CGContextSetShouldAntialias(context: CGContextRef, value: bool) void;
extern "c" fn CGContextSetShouldSmoothFonts(context: CGContextRef, value: bool) void;
extern "c" fn CGContextSetTextDrawingMode(context: CGContextRef, mode: c_int) void;
extern "c" fn CGContextSetTextMatrix(context: CGContextRef, transform: AffineTransform) void;
extern "c" fn CGContextSetRGBFillColor(context: CGContextRef, red: f64, green: f64, blue: f64, alpha: f64) void;
extern "c" fn CGContextFillRect(context: CGContextRef, rect: Rect) void;

pub const foundation = struct {
    pub const StringEncoding = enum(u32) {
        utf8 = 0x08000100,
    };

    pub const String = opaque {
        pub fn createWithBytes(bytes: []const u8, encoding: StringEncoding, external: bool) !*String {
            return @ptrCast(CFStringCreateWithBytes(
                null,
                bytes.ptr,
                @intCast(bytes.len),
                @intFromEnum(encoding),
                external,
            ) orelse return error.OutOfMemory);
        }

        pub fn createWithCharacters(characters: []const u16) !*String {
            return @ptrCast(CFStringCreateWithCharacters(
                null,
                characters.ptr,
                @intCast(characters.len),
            ) orelse return error.OutOfMemory);
        }

        pub fn release(self: *String) void {
            CFRelease(@ptrCast(self));
        }
    };

    pub const Range = Apple.Range;
};

pub const Range = extern struct {
    location: CFIndex,
    length: CFIndex,

    pub fn init(location: usize, length: usize) Range {
        return .{ .location = @intCast(location), .length = @intCast(length) };
    }
};

pub const graphics = struct {
    pub const Glyph = CGGlyph;
    pub const Point = Apple.Point;
    pub const Size = Apple.Size;
    pub const Rect = Apple.Rect;
    pub const AffineTransform = Apple.AffineTransform;

    pub const BitmapInfo = enum(u32) {
        byte_order_32_little = 2 << 12,
    };

    pub const ImageAlphaInfo = enum(u32) {
        premultiplied_first = 2,
    };

    pub const ColorSpace = opaque {
        pub fn createDeviceRGB() !*ColorSpace {
            return @ptrCast(CGColorSpaceCreateDeviceRGB() orelse return error.OutOfMemory);
        }

        pub fn release(self: *ColorSpace) void {
            CGColorSpaceRelease(@ptrCast(self));
        }
    };

    pub const BitmapContext = opaque {
        pub const context = Context;

        pub fn create(
            data: []u8,
            width: usize,
            height: usize,
            bits_per_component: usize,
            bytes_per_row: usize,
            color_space: *ColorSpace,
            bitmap_info: u32,
        ) !*BitmapContext {
            return @ptrCast(CGBitmapContextCreate(
                data.ptr,
                width,
                height,
                bits_per_component,
                bytes_per_row,
                @ptrCast(color_space),
                bitmap_info,
            ) orelse return error.OutOfMemory);
        }
    };

    pub const Context = struct {
        pub fn release(value: *BitmapContext) void {
            CGContextRelease(@ptrCast(value));
        }

        pub fn setAllowsAntialiasing(value: *BitmapContext, enabled: bool) void {
            CGContextSetAllowsAntialiasing(@ptrCast(value), enabled);
        }

        pub fn setShouldAntialias(value: *BitmapContext, enabled: bool) void {
            CGContextSetShouldAntialias(@ptrCast(value), enabled);
        }

        pub fn setShouldSmoothFonts(value: *BitmapContext, enabled: bool) void {
            CGContextSetShouldSmoothFonts(@ptrCast(value), enabled);
        }

        pub fn setTextDrawingMode(value: *BitmapContext, mode: TextDrawingMode) void {
            CGContextSetTextDrawingMode(@ptrCast(value), @intFromEnum(mode));
        }

        pub fn setTextMatrix(value: *BitmapContext, transform: Apple.AffineTransform) void {
            CGContextSetTextMatrix(@ptrCast(value), transform);
        }

        pub fn setRGBFillColor(value: *BitmapContext, red: f64, green: f64, blue: f64, alpha: f64) void {
            CGContextSetRGBFillColor(@ptrCast(value), red, green, blue, alpha);
        }

        pub fn fillRect(value: *BitmapContext, rect: Apple.Rect) void {
            CGContextFillRect(@ptrCast(value), rect);
        }
    };

    pub const TextDrawingMode = enum(c_int) {
        fill = 0,
    };
};

pub const text = struct {
    pub const FontSymbolicTraits = packed struct(u32) {
        italic: bool = false,
        bold: bool = false,
        _padding: u30 = 0,
    };

    pub const FontDescriptor = opaque {
        pub fn createWithNameAndSize(name: *foundation.String, size: f64) !*FontDescriptor {
            return @ptrCast(CTFontDescriptorCreateWithNameAndSize(
                @ptrCast(name),
                size,
            ) orelse return error.OutOfMemory);
        }

        pub fn release(self: *FontDescriptor) void {
            CFRelease(@ptrCast(self));
        }
    };

    pub const Font = opaque {
        pub fn createWithFontDescriptor(descriptor: *FontDescriptor, size: f64) !*Font {
            return @ptrCast(CTFontCreateWithFontDescriptor(
                @ptrCast(descriptor),
                size,
                null,
            ) orelse return error.OutOfMemory);
        }

        pub fn copyWithSymbolicTraits(self: *Font, traits: FontSymbolicTraits) ?*Font {
            const raw: CTFontSymbolicTraits = @bitCast(traits);
            return @ptrCast(CTFontCreateCopyWithSymbolicTraits(
                @ptrCast(self),
                0,
                null,
                raw,
                raw,
            ) orelse return null);
        }

        pub fn createForString(self: *Font, string: *foundation.String, range: Range) ?*Font {
            return @ptrCast(CTFontCreateForString(
                @ptrCast(self),
                @ptrCast(string),
                range,
            ) orelse return null);
        }

        pub fn retain(self: *Font) void {
            _ = CFRetain(@ptrCast(self));
        }

        pub fn release(self: *Font) void {
            CFRelease(@ptrCast(self));
        }

        pub fn getGlyphsForCharacters(self: *Font, characters: []const u16, glyphs: []graphics.Glyph) bool {
            std.debug.assert(characters.len == glyphs.len);
            return CTFontGetGlyphsForCharacters(
                @ptrCast(self),
                characters.ptr,
                glyphs.ptr,
                @intCast(characters.len),
            );
        }

        pub fn getAdvancesForGlyphs(
            self: *Font,
            orientation: FontOrientation,
            glyphs: []const graphics.Glyph,
            advances: ?[]graphics.Size,
        ) f64 {
            if (advances) |values| std.debug.assert(values.len == glyphs.len);
            return CTFontGetAdvancesForGlyphs(
                @ptrCast(self),
                @intFromEnum(orientation),
                glyphs.ptr,
                if (advances) |values| values.ptr else null,
                @intCast(glyphs.len),
            );
        }

        pub fn drawGlyphs(
            self: *Font,
            glyphs: []const graphics.Glyph,
            positions: []const graphics.Point,
            context: *graphics.BitmapContext,
        ) void {
            std.debug.assert(glyphs.len == positions.len);
            CTFontDrawGlyphs(
                @ptrCast(self),
                glyphs.ptr,
                positions.ptr,
                glyphs.len,
                @ptrCast(context),
            );
        }

        pub fn getAscent(self: *Font) f64 {
            return CTFontGetAscent(@ptrCast(self));
        }
        pub fn getDescent(self: *Font) f64 {
            return CTFontGetDescent(@ptrCast(self));
        }
        pub fn getLeading(self: *Font) f64 {
            return CTFontGetLeading(@ptrCast(self));
        }
        pub fn getUnderlinePosition(self: *Font) f64 {
            return CTFontGetUnderlinePosition(@ptrCast(self));
        }
        pub fn getUnderlineThickness(self: *Font) f64 {
            return CTFontGetUnderlineThickness(@ptrCast(self));
        }
        pub fn getXHeight(self: *Font) f64 {
            return CTFontGetXHeight(@ptrCast(self));
        }
    };

    pub const FontOrientation = enum(u32) {
        horizontal = 1,
    };
};

pub const Point = extern struct {
    x: f64,
    y: f64,
};

pub const Size = extern struct {
    width: f64,
    height: f64,
};

pub const Rect = extern struct {
    origin: Point,
    size: Size,

    pub fn init(x: f64, y: f64, width: f64, height: f64) Rect {
        return .{ .origin = .{ .x = x, .y = y }, .size = .{ .width = width, .height = height } };
    }
};

pub const AffineTransform = extern struct {
    a: f64,
    b: f64,
    c: f64,
    d: f64,
    tx: f64,
    ty: f64,

    pub fn identity() AffineTransform {
        return .{ .a = 1, .b = 0, .c = 0, .d = 1, .tx = 0, .ty = 0 };
    }
};
