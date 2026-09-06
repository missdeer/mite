#import <Metal/Metal.h>
#include <assert.h>
#include <string.h>
#include "ClipboardBridge.h"

// Replace only the C bridge: the tests run the production AppKit handlers.
static uint8_t written[4096];
static size_t written_count;
static bool bracketed_paste;
static bool selection_active;
static uint32_t selection_end;
static id<MTLDevice> device;

void clipboard_test_reset(bool bracketed) { written_count = 0; bracketed_paste = bracketed; }
size_t clipboard_test_written(uint8_t *buf, size_t cap) {
    assert(written_count <= cap);
    memcpy(buf, written, written_count);
    return written_count;
}

MosttyTab *mostty_tab_create(uint32_t w, uint32_t h, float scale) { return (MosttyTab *)&written_count; }
void mostty_tab_destroy(MosttyTab *tab) {}
float mostty_config_background_opacity(void) { return 1; }
uint32_t mostty_config_render_interval_ms(void) { return 16; }
bool mostty_tab_apply_config(MosttyTab *tab) { return false; }
void *mostty_tab_metal_device(MosttyTab *tab) {
    if (!device) device = MTLCreateSystemDefaultDevice();
    return (__bridge void *)device;
}
intptr_t mostty_tab_read(MosttyTab *tab, uint8_t *buf, size_t cap) { return 0; }
void mostty_tab_feed(MosttyTab *tab, const uint8_t *ptr, size_t len) {}
void mostty_tab_write(MosttyTab *tab, const uint8_t *ptr, size_t len) {
    assert(len <= sizeof(written) - written_count);
    memcpy(written + written_count, ptr, len);
    written_count += len;
}
bool mostty_tab_set_surface(MosttyTab *tab, uint32_t w, uint32_t h, float scale, uint32_t *cols, uint32_t *rows) {
    *cols = w / 10; *rows = h / 20; return true;
}
void *mostty_tab_render(MosttyTab *tab, bool cursor, uint32_t *cols, uint32_t *rows) { return NULL; }
size_t mostty_tab_title(MosttyTab *tab, uint8_t *buf, size_t cap) { return 0; }
bool mostty_tab_poll_exit(MosttyTab *tab, int32_t *code) { return false; }
void mostty_tab_cell_size(MosttyTab *tab, uint32_t *w, uint32_t *h) { *w = 10; *h = 20; }
void mostty_tab_cursor(MosttyTab *tab, uint32_t *col, uint32_t *row) { *col = 0; *row = 0; }
bool mostty_tab_app_cursor_keys(MosttyTab *tab) { return false; }
bool mostty_tab_bracketed_paste(MosttyTab *tab) { return bracketed_paste; }
void mostty_tab_scroll(MosttyTab *tab, int32_t rows) {}
void mostty_tab_scroll_to_bottom(MosttyTab *tab) {}
void mostty_tab_set_selection(MosttyTab *tab, bool active, uint32_t sc, uint32_t sr, uint32_t ec, uint32_t er) {
    selection_active = active; selection_end = ec;
}
size_t mostty_tab_selection_text(MosttyTab *tab, uint32_t sc, uint32_t sr, uint32_t ec, uint32_t er, uint8_t *buf, size_t cap) {
    // Reject stale drag coordinates: release must publish its final endpoint.
    assert(selection_active && selection_end == ec);
    const char *text = ec == 4 ? "hello" : "hel";
    size_t len = strlen(text);
    assert(len <= cap);
    memcpy(buf, text, len);
    return len;
}
size_t mostty_encode_key(uint32_t key, uint32_t mods, bool app_cursor, uint8_t *buf, size_t cap) { return 0; }
