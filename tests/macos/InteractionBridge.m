#import "InteractionBridge.h"
#import <objc/runtime.h>
#include <string.h>

static bool confirm_enabled = true;
static bool accept_close;
static size_t alerts;
static const char *active_theme = "Dark";
static NSString *config_path;

static NSModalResponse respondToAlert(id alert, SEL selector) {
    alerts++;
    return accept_close ? NSAlertSecondButtonReturn : NSAlertFirstButtonReturn;
}

void interaction_test_confirmation(bool enabled, bool accept) {
    confirm_enabled = enabled;
    accept_close = accept;
    alerts = 0;
    method_setImplementation(class_getInstanceMethod(NSAlert.class, @selector(runModal)), (IMP)respondToAlert);
}
size_t interaction_test_alerts(void) { return alerts; }
bool mostty_config_confirm_close(void) { return confirm_enabled; }
bool mostty_config_reload(void) { return true; }
void interaction_test_config_path(const char *path) { config_path = [NSString stringWithUTF8String:path]; }
size_t mostty_config_path(uint8_t *buf, size_t cap) {
    const char *path = config_path.UTF8String;
    if (!path || strlen(path) > cap) return 0;
    memcpy(buf, path, strlen(path));
    return strlen(path);
}
bool mostty_config_background_blur(void) { return false; }
bool mostty_config_maximize(void) { return false; }
bool mostty_config_fullscreen(void) { return false; }
size_t mostty_config_launcher_count(void) { return 2; }
static size_t text(const char *value, uint8_t *buf, size_t cap) {
    size_t count = strlen(value);
    if (!cap) return count;
    if (count > cap) return 0;
    memcpy(buf, value, count);
    return count;
}
size_t mostty_config_launcher_text(size_t index, uint32_t field, uint8_t *buf, size_t cap) {
    const char *values[2][3] = {{"First", "echo first", "/usr"}, {"Second", "echo second", "/var"}};
    return index < 2 && field < 3 ? text(values[index][field], buf, cap) : 0;
}
size_t mostty_config_refresh_themes(void) { return 2; }
size_t mostty_config_theme_name(size_t index, uint8_t *buf, size_t cap) {
    return index < 2 ? text(index ? "Light" : "Dark", buf, cap) : 0;
}
size_t mostty_config_active_theme(uint8_t *buf, size_t cap) { return text(active_theme, buf, cap); }
bool mostty_config_select_theme(const char *name) {
    if (strcmp(name, "Dark") == 0) active_theme = "Dark";
    else if (strcmp(name, "Light") == 0) active_theme = "Light";
    else return false;
    return true;
}
