#ifndef MOSTTY_VULKAN_WIN32_ABI_H
#define MOSTTY_VULKAN_WIN32_ABI_H

// Avoid pulling windows.h through translate-c. Zig 0.16's C translator crashes
// on that header combination; Vulkan only needs these ABI-compatible types.
typedef void* HANDLE;
typedef void* HINSTANCE;
typedef void* HWND;
typedef void* HMONITOR;
typedef const unsigned short* LPCWSTR;
typedef unsigned long DWORD;
typedef struct _SECURITY_ATTRIBUTES SECURITY_ATTRIBUTES;

#include <vulkan/vulkan_core.h>
#include <vulkan/vulkan_win32.h>

#endif
