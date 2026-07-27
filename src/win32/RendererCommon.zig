const RendererCommon = @This();

const win32 = @import("win32").everything;

cell_size: win32.SIZE,
tab_bar_height: i32,
font_ligatures: bool,
remote_or_software_adapter: bool,
