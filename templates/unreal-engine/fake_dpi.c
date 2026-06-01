#include <dlfcn.h>
#include <stdlib.h>

// Intercept SDL_GetDisplayDPI and force a fixed DPI for Unreal Engine on HiDPI displays
// UE quantizes DPI into coarse steps (1.0, 1.5, 2.0, etc.), so 96 vs 115 both become 1.0
// 144 gives 1.5x scale, which is noticeably larger and looks good on HiDPI displays
// Compile: gcc -shared -fPIC -o fake_dpi.so fake_dpi.c

#define TARGET_DPI 144.0f

int SDL_GetDisplayDPI(int displayIndex, float *ddpi, float *hdpi, float *vdpi) {
    if (ddpi) *ddpi = TARGET_DPI;
    if (hdpi) *hdpi = TARGET_DPI;
    if (vdpi) *vdpi = TARGET_DPI;
    return 0;  // SDL_SUCCESS
}
