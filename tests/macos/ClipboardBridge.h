#include "../../src/macos/app/Bridge.h"

void clipboard_test_reset(bool bracketed);
size_t clipboard_test_written(uint8_t *buf, size_t cap);
void clipboard_test_url(const char *url, bool open_success);
const char *clipboard_test_opened_url(void);
bool clipboard_test_hovered_url(void);
void clipboard_test_restore_url_open(void);
