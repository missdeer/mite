const std = @import("std");

/// Shape a shell-provided window title into what a tab should display. When the
/// title looks like a filesystem path (contains a `/` or `\`), only the final
/// path component is returned so the tab reads as the current directory name; a
/// title without a separator is returned unchanged. This is the shared,
/// platform-neutral presentation rule applied identically on Windows and macOS —
/// the caller keeps the full title as canonical state and this only shapes the
/// displayed value. A root or trailing-separator title reduces to an empty
/// slice; the caller decides what an empty result means for its surface.
pub fn displayTitle(title: []const u8) []const u8 {
    var i: usize = title.len;
    while (i > 0) {
        i -= 1;
        if (title[i] == '\\' or title[i] == '/') {
            return title[i + 1 ..];
        }
    }
    return title;
}

test "displayTitle reduces a path-shaped title to its final component" {
    // The rule that makes the tab track the current path: a path title collapses
    // to the current directory / leaf name, not some arbitrary substring.
    try std.testing.expectEqualStrings("mostty", displayTitle("/Users/foo/Development/mostty"));
    try std.testing.expectEqualStrings("mostty", displayTitle("C:\\Users\\foo\\Development\\mostty"));
    // Both separators are recognized, so a mixed / cross-platform path still
    // reduces to the segment after the last separator of either kind.
    try std.testing.expectEqualStrings("file.txt", displayTitle("/a/b\\file.txt"));
}

test "displayTitle leaves a separator-free title unchanged" {
    // Program-name titles carry no path, so they must pass through verbatim.
    try std.testing.expectEqualStrings("zsh", displayTitle("zsh"));
    try std.testing.expectEqualStrings("node", displayTitle("node"));
    try std.testing.expectEqualStrings("", displayTitle(""));
}

test "displayTitle reduces a root or trailing-separator title to empty" {
    // Boundary: a filesystem root or a trailing separator has no final component.
    // The rule reports empty; the presentation caller (macOS) treats empty as
    // "no update" so the tab never blanks, while Windows keeps its draw semantics.
    try std.testing.expectEqualStrings("", displayTitle("/"));
    try std.testing.expectEqualStrings("", displayTitle("/Users/foo/"));
    try std.testing.expectEqualStrings("", displayTitle("C:\\"));
}
