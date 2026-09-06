const std = @import("std");
const vt = @import("vt");

// Default word-boundary codepoints. Conservative on purpose: dots, slashes,
// dashes, underscores, '$' and ':' stay non-boundary so URLs, file paths,
// and shell variables (`https://x/y`, `$HOME`, `key:value` literals) select
// as a single token. '@' IS a boundary so shell prompts like
// `user@host MINGW64 /path` split as user / host / MINGW64 / path
// (matches xterm/ghostty default — trade-off: `user@example.com` and
// scoped npm packages split too).
//
// CJK punctuation block: without these, an entire Chinese/Japanese sentence
// would select as one "word" because the CJK ideographs themselves are
// non-boundary. We include the fullwidth analogues of the ASCII boundaries
// plus the ideographic comma/period/quotation brackets so a Chinese sentence
// double-click selects a phrase, not the whole line.
pub const WORD_BOUNDARIES = [_]u21{
    0,   ' ', '\t', '\'', '"', '`', '|', ';',
    ',', '(', ')',  '[',  ']', '{', '}', '<',
    '>', '@', 0x2502, // '│' TUI pane separator
    // CJK / fullwidth punctuation
    0x3000, // 　 ideographic space
    0x3001, // 、 ideographic comma
    0x3002, // 。 ideographic full stop
    0x3008, 0x3009, // 〈〉
    0x300A, 0x300B, // 《》
    0x300C, 0x300D, // 「」
    0x300E, 0x300F, // 『』
    0x3010, 0x3011, // 【】
    0xFF01, // ！
    0xFF08, 0xFF09, // （）
    0xFF0C, // ，
    0xFF1A, // ：
    0xFF1B, // ；
    0xFF1F, // ？
    0x2018, 0x2019, // '' smart single quotes
    0x201C, 0x201D, // "" smart double quotes
    0x00B7, // · Latin middle dot (Chinese names: 奥利弗·特威斯特)
    0x30FB, // ・ katakana middle dot (Japanese lists / loanword separators)
};

// Wide CJK character occupies two cells: a primary cell with the codepoint
// and a spacer_tail cell to its right whose codepoint is 0. Ghostty's
// Screen.selectWord short-circuits on the spacer_tail because hasText() is
// false there, which collapses any CJK-word selection down to a single
// character. This is a spacer-aware reimplementation: spacer_tail (and the
// soft-wrap spacer_head) are treated as continuation cells, not as word
// boundaries, so consecutive CJK ideographs select as one word.
pub fn selectWordCJK(pin: vt.Pin, boundary_codepoints: []const u21) ?vt.Selection {
    const start_cell = pin.rowAndCell().cell;
    if (!start_cell.hasText()) return null;

    const expect_boundary = std.mem.indexOfScalar(
        u21,
        boundary_codepoints,
        start_cell.content.codepoint.data,
    ) != null;

    const end: vt.Pin = end: {
        if (pin.x == pin.node.cols() - 1 and !pin.rowAndCell().row.wrap) break :end pin;
        var it = pin.cellIterator(.right_down, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;
            const last_col = p.x == p.node.cols() - 1;

            // spacer_tail is the right half of a wide char on the current row;
            // it travels with the primary, so include it in `prev` so the
            // selection's end pin can sit on it (the formatter skips spacers
            // after emitting the primary, so copy text comes out clean).
            //
            // spacer_head is end-of-row filler reserved for a wide char that
            // wrapped to the NEXT row. Visually it belongs to the wrapped
            // character, not to the current word. If we advanced `prev` onto
            // it and the next-row character turned out to be a boundary,
            // `selectionString`'s unwrap would expand end-on-spacer_head to
            // (next row, col 0), pulling that boundary char into the copy.
            // So skip spacer_head WITHOUT updating prev.
            switch (cell.wide) {
                .spacer_tail => {
                    if (last_col and !rac.row.wrap) break :end p;
                    prev = p;
                    continue;
                },
                .spacer_head => {
                    if (last_col and !rac.row.wrap) break :end prev;
                    continue;
                },
                .narrow, .wide => {},
            }

            if (!cell.hasText()) break :end prev;

            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                cell.content.codepoint.data,
            ) != null;
            if (this_boundary != expect_boundary) break :end prev;

            if (last_col and !rac.row.wrap) break :end p;

            prev = p;
        }
        break :end prev;
    };

    const start: vt.Pin = start: {
        var it = pin.cellIterator(.left_up, null);
        var prev = it.next().?;
        while (it.next()) |p| {
            const rac = p.rowAndCell();
            const cell = rac.cell;

            // Backwards crossing into the previous row's last column: if that
            // row isn't wrapped to ours, stop. Matches ghostty selectWord.
            if (p.x == p.node.cols() - 1 and !rac.row.wrap) break :start prev;

            // spacer_tail belongs to the wide char to its LEFT, which the
            // backward walk hasn't visited yet. Skip without updating prev so
            // that if the wide primary turns out to be a boundary, start
            // doesn't land on the spacer (formatter expands start-on-tail to
            // include the boundary char). Mirror of forward's spacer_head.
            //
            // spacer_head sits at the end of the previous row before our
            // wrapped wide character. The primary on the current row is
            // already in `prev`, so advancing prev onto spacer_head is safe:
            // formatter unwraps start-on-head back to (next row, col 0) =
            // that same primary, so the start pin doesn't shift.
            switch (cell.wide) {
                .spacer_tail => continue,
                .spacer_head => {
                    prev = p;
                    continue;
                },
                .narrow, .wide => {},
            }

            if (!cell.hasText()) break :start prev;

            const this_boundary = std.mem.indexOfScalar(
                u21,
                boundary_codepoints,
                cell.content.codepoint.data,
            ) != null;
            if (this_boundary != expect_boundary) break :start prev;

            prev = p;
        }
        break :start prev;
    };

    return vt.Selection.init(start, end, false);
}
