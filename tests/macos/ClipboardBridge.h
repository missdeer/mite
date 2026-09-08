#include "../../src/macos/app/Bridge.h"
#import <AppKit/AppKit.h>

void clipboard_test_reset(bool bracketed);
size_t clipboard_test_written(uint8_t *buf, size_t cap);
void clipboard_test_keypad_mode(bool enabled);
size_t clipboard_test_keypad_queries(void);
void clipboard_test_url(const char *url, bool open_success);
const char *clipboard_test_opened_url(void);
bool clipboard_test_hovered_url(void);
void clipboard_test_restore_url_open(void);
id<NSDraggingInfo> clipboard_test_drag(NSPasteboard *pasteboard, NSDragOperation operation);
MosttyTab *clipboard_test_created_tab(void);
MosttyTab *clipboard_test_write_tab(void);
void clipboard_test_mouse_mode(bool enabled);
uint32_t clipboard_test_mouse_count(void);
uint32_t clipboard_test_mouse_action(void);
uint32_t clipboard_test_mouse_button(void);
int32_t clipboard_test_mouse_x(void);
int32_t clipboard_test_mouse_y(void);
void clipboard_test_scrollback(MosttyTab *tab, uint64_t total, uint64_t offset, uint64_t visible);
