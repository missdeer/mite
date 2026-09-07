#ifndef MOSTTY_BRIDGE_H
#define MOSTTY_BRIDGE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

typedef struct MosttyTab MosttyTab;

MosttyTab *mostty_tab_create(uint32_t pixel_width, uint32_t pixel_height, float scale);
MosttyTab *mostty_tab_create_with_launcher(uint32_t pixel_width, uint32_t pixel_height,
                                         float scale, const char *command, const char *directory);
void mostty_tab_destroy(MosttyTab *tab);

/* Configuration. Values are read from the file the app watches; `reload` returns
   false when it was unreadable, leaving the previous config in place. */
bool mostty_config_reload(void);
size_t mostty_config_path(uint8_t *buf, size_t cap);
float mostty_config_background_opacity(void);
bool mostty_config_background_blur(void);
bool mostty_config_maximize(void);
bool mostty_config_fullscreen(void);
bool mostty_config_confirm_close(void);
size_t mostty_config_launcher_count(void);
/* Launcher fields: 0 label, 1 command, 2 directory; cap == 0 queries length. */
size_t mostty_config_launcher_text(size_t index, uint32_t field, uint8_t *buf, size_t cap);
size_t mostty_config_refresh_themes(void);
/* Text accessors return the required length for cap == 0, or zero if too small. */
size_t mostty_config_theme_name(size_t index, uint8_t *buf, size_t cap);
size_t mostty_config_active_theme(uint8_t *buf, size_t cap);
bool mostty_config_select_theme(const char *name);
uint32_t mostty_config_render_interval_ms(void);
/* Returns true when the cell metrics changed and the drawable must be re-synced. */
bool mostty_tab_apply_config(MosttyTab *tab);

void *mostty_tab_metal_device(MosttyTab *tab);

intptr_t mostty_tab_read(MosttyTab *tab, uint8_t *buf, size_t cap);
void mostty_tab_feed(MosttyTab *tab, const uint8_t *ptr, size_t len);
void mostty_tab_write(MosttyTab *tab, const uint8_t *ptr, size_t len);

bool mostty_tab_set_surface(MosttyTab *tab, uint32_t pixel_width, uint32_t pixel_height,
                            float scale, uint32_t *out_cols, uint32_t *out_rows);
void *mostty_tab_render(MosttyTab *tab, bool cursor_on, uint32_t *out_cols, uint32_t *out_rows);

size_t mostty_tab_title(MosttyTab *tab, uint8_t *buf, size_t cap);
bool mostty_tab_poll_exit(MosttyTab *tab, int32_t *out_code);

void mostty_tab_cell_size(MosttyTab *tab, uint32_t *out_w, uint32_t *out_h);
void mostty_tab_cursor(MosttyTab *tab, uint32_t *out_col, uint32_t *out_row);

bool mostty_tab_app_cursor_keys(MosttyTab *tab);
bool mostty_tab_app_keypad(MosttyTab *tab);
bool mostty_tab_bracketed_paste(MosttyTab *tab);
bool mostty_tab_cursor_visible(MosttyTab *tab);

void mostty_tab_scroll(MosttyTab *tab, int32_t delta_rows);
void mostty_tab_scroll_to_bottom(MosttyTab *tab);
bool mostty_tab_at_bottom(MosttyTab *tab);

/* cap == 0 queries the required size; an undersized buffer returns zero. */
size_t mostty_tab_selection_text(MosttyTab *tab, uint8_t *buf, size_t cap);
bool mostty_tab_select_word(MosttyTab *tab, uint32_t col, uint32_t row);
bool mostty_tab_hover_url(MosttyTab *tab, bool active, uint32_t col, uint32_t row);
/* Re-detects at the click position; returns zero if absent or the buffer is too small. */
size_t mostty_tab_url_at(MosttyTab *tab, uint32_t col, uint32_t row, uint8_t *buf, size_t cap);
void mostty_tab_set_selection(MosttyTab *tab, bool active, uint32_t start_col, uint32_t start_row,
                              uint32_t end_col, uint32_t end_row);

size_t mostty_encode_key(uint32_t key, uint32_t mods, bool app_cursor, uint8_t *buf, size_t cap);

#endif
