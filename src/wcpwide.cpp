#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cmath>
#include <cstring>
#include <cwchar>

// This proxy supports the exact Enhanced Prophecy build recorded by install.ps1.
static HMODULE selfModule;
static HMODULE realModule;
static unsigned char* graphics;
static bool initialized;
using Draw = unsigned char (__thiscall*)(void*, unsigned char);
using RectangleCall = void (WINAPI*)(int, int, int, int);
static Draw realDraw, realDustDraw;
static RectangleCall realViewport, realScissor;

template<class T> static T& field(void* p, unsigned offset) {
    return *reinterpret_cast<T*>(static_cast<unsigned char*>(p) + offset);
}

struct CameraSave {
    void* camera = nullptr;
    unsigned char bounds[32], projection[16], rightPlane[12], leftPlane[12];
};

static bool widen(void* camera, CameraSave& save) {
    if (!graphics || field<int>(camera, 0x60) != 0 || field<int>(camera, 0x64) != 0 ||
        field<int>(camera, 0x68) != 639 || field<int>(camera, 0x6c) != 479) return false;
    const int width = field<int>(graphics, 8), height = field<int>(graphics, 12);
    const float scale = field<float>(graphics, 0x10);
    if (height < 480 || width <= height * (4.0f / 3.0f) || scale <= 0) return false;
    const int halfWidth = static_cast<int>(std::ceil(width / scale / 2));
    if (halfWidth <= 320 || halfWidth > 2048) return false;
    const float coefficient = field<float>(camera, 0x8c) * 320.0f / halfWidth;
    if (!std::isfinite(coefficient) || coefficient <= 0) return false;
    save.camera = camera;
    std::memcpy(save.bounds, &field<int>(camera, 0x60), sizeof save.bounds);
    std::memcpy(save.projection, &field<float>(camera, 0x8c), sizeof save.projection);
    std::memcpy(save.rightPlane, &field<float>(camera, 0xc0), sizeof save.rightPlane);
    std::memcpy(save.leftPlane, &field<float>(camera, 0xd8), sizeof save.leftPlane);
    field<int>(camera, 0x60) = 320 - halfWidth;
    field<int>(camera, 0x68) = 320 + halfWidth - 1;
    field<int>(camera, 0x70) = halfWidth;
    field<float>(camera, 0x8c) = coefficient;
    const float norm = std::sqrt(coefficient * coefficient + 1);
    field<float>(camera, 0xc0) = coefficient / norm;
    field<float>(camera, 0xc4) = 0;
    field<float>(camera, 0xc8) = -1 / norm;
    field<float>(camera, 0xd8) = -coefficient / norm;
    field<float>(camera, 0xdc) = 0;
    field<float>(camera, 0xe0) = -1 / norm;
    return true;
}

static void restore(const CameraSave& save) {
    if (!save.camera) return;
    std::memcpy(&field<int>(save.camera, 0x60), save.bounds, sizeof save.bounds);
    std::memcpy(&field<float>(save.camera, 0x8c), save.projection, sizeof save.projection);
    std::memcpy(&field<float>(save.camera, 0xc0), save.rightPlane, sizeof save.rightPlane);
    std::memcpy(&field<float>(save.camera, 0xd8), save.leftPlane, sizeof save.leftPlane);
}

static unsigned char __fastcall drawHook(void* camera, void*, unsigned char flag) {
    CameraSave save;
    widen(camera, save);
    const unsigned char result = realDraw(camera, flag);
    restore(save);
    return result;
}

static unsigned char __fastcall dustDrawHook(void* camera, void*, unsigned char flag) {
    CameraSave save;
    widen(camera, save);
    const unsigned char result = realDustDraw(camera, flag);
    restore(save);
    return result;
}

static bool originalFullRectangle(int x, int y, int width, int height) {
    if (!graphics) return false;
    const float scale = field<float>(graphics, 0x10);
    return x == static_cast<int>(field<float>(graphics, 0x18)) &&
           y == static_cast<int>(field<float>(graphics, 0x1c)) &&
           width == static_cast<int>(640 * scale) && height == static_cast<int>(480 * scale);
}

static bool cameraWide() {
    if (!graphics) return false;
    void* camera = field<void*>(graphics, 0xb3c);
    return camera && field<int>(camera, 0x60) < 0 && field<int>(camera, 0x68) > 639;
}

static void WINAPI viewportHook(int x, int y, int width, int height) {
    if (originalFullRectangle(x, y, width, height) && cameraWide()) {
        const int mode = field<int>(graphics, 0xb30);
        if (mode == 0 || mode == 1) {
            void* camera = field<void*>(graphics, 0xb3c);
            const float scale = field<float>(graphics, 0x10);
            x = static_cast<int>(field<float>(graphics, 0x18) + field<int>(camera, 0x60) * scale);
            width = static_cast<int>((field<int>(camera, 0x68) - field<int>(camera, 0x60) + 1) * scale);
        }
    }
    realViewport(x, y, width, height);
}

static void WINAPI scissorHook(int x, int y, int width, int height) {
    if (originalFullRectangle(x, y, width, height) &&
        (cameraWide() || (field<float>(graphics, 0x48) < 0 && field<float>(graphics, 0x50) > 640))) {
        x = 0;
        width = field<int>(graphics, 8);
    }
    realScissor(x, y, width, height);
}

static void** importSlot(const char* name) {
    auto base = reinterpret_cast<unsigned char*>(realModule);
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(base);
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(base + dos->e_lfanew);
    const DWORD rva = nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress;
    auto dll = reinterpret_cast<IMAGE_IMPORT_DESCRIPTOR*>(base + rva);
    for (; dll->Name; ++dll) {
        if (_stricmp(reinterpret_cast<char*>(base + dll->Name), "OPENGL32.DLL")) continue;
        if (!dll->OriginalFirstThunk) return nullptr;
        auto names = reinterpret_cast<IMAGE_THUNK_DATA*>(base + dll->OriginalFirstThunk);
        auto slots = reinterpret_cast<IMAGE_THUNK_DATA*>(base + dll->FirstThunk);
        for (; names->u1.AddressOfData; ++names, ++slots) {
            if (IMAGE_SNAP_BY_ORDINAL(names->u1.Ordinal)) continue;
            auto imported = reinterpret_cast<IMAGE_IMPORT_BY_NAME*>(base + names->u1.AddressOfData);
            if (!std::strcmp(reinterpret_cast<char*>(imported->Name), name))
                return reinterpret_cast<void**>(&slots->u1.Function);
        }
    }
    return nullptr;
}

static bool replace(void** slot, void* value) {
    DWORD protection;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &protection)) return false;
    InterlockedExchangePointer(reinterpret_cast<void* volatile*>(slot), value);
    DWORD unused;
    VirtualProtect(slot, sizeof(void*), protection, &unused);
    return true;
}

static void logResult(const char* message) {
    wchar_t path[MAX_PATH];
    const DWORD n = GetModuleFileNameW(selfModule, path, MAX_PATH);
    if (!n || n >= MAX_PATH) return;
    wchar_t* file = std::wcsrchr(path, L'\\');
    if (!file) return;
    wcscpy_s(file + 1, MAX_PATH - (file + 1 - path), L"wcpwide.log");
    HANDLE output = CreateFileW(path, GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (output == INVALID_HANDLE_VALUE) return;
    DWORD written;
    WriteFile(output, message, static_cast<DWORD>(std::strlen(message)), &written, nullptr);
    CloseHandle(output);
}

static void installHooks() {
    auto host = reinterpret_cast<unsigned char*>(GetModuleHandleW(nullptr));
    auto dos = reinterpret_cast<IMAGE_DOS_HEADER*>(host);
    auto nt = reinterpret_cast<IMAGE_NT_HEADERS*>(host + dos->e_lfanew);
    if (host != reinterpret_cast<unsigned char*>(0x400000) || nt->OptionalHeader.SizeOfImage < 0xdad30) {
        logResult("Widescreen disabled: unsupported host image.\r\n");
        return;
    }
    const unsigned char expected[] = {0x68, 0, 0, 0x70, 0x42};
    auto baseSlot = reinterpret_cast<void**>(0x4da720 + 0x1c);
    auto dustSlot = reinterpret_cast<void**>(0x4dad08 + 0x1c);
    void** viewportSlot = importSlot("glViewport");
    void** scissorSlot = importSlot("glScissor");
    if (std::memcmp(reinterpret_cast<void*>(0x47ea97), expected, sizeof expected) ||
        *baseSlot != reinterpret_cast<void*>(0x410a00) || *dustSlot != reinterpret_cast<void*>(0x41c4d0) ||
        !viewportSlot || !scissorSlot) {
        logResult("Widescreen disabled: executable or renderer does not match the supported build.\r\n");
        return;
    }
    realDraw = reinterpret_cast<Draw>(*baseSlot);
    realDustDraw = reinterpret_cast<Draw>(*dustSlot);
    realViewport = reinterpret_cast<RectangleCall>(*viewportSlot);
    realScissor = reinterpret_cast<RectangleCall>(*scissorSlot);
    HMODULE pinned;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_PIN,
                           reinterpret_cast<LPCWSTR>(&installHooks), &pinned)) {
        logResult("Widescreen disabled: proxy lifetime could not be secured.\r\n");
        return;
    }
    if (!replace(baseSlot, reinterpret_cast<void*>(drawHook)) ||
        !replace(dustSlot, reinterpret_cast<void*>(dustDrawHook)) ||
        !replace(viewportSlot, reinterpret_cast<void*>(viewportHook)) ||
        !replace(scissorSlot, reinterpret_cast<void*>(scissorHook))) {
        replace(baseSlot, reinterpret_cast<void*>(realDraw));
        replace(dustSlot, reinterpret_cast<void*>(realDustDraw));
        replace(viewportSlot, reinterpret_cast<void*>(realViewport));
        replace(scissorSlot, reinterpret_cast<void*>(realScissor));
        logResult("Widescreen disabled: memory pointer replacement failed.\r\n");
        return;
    }
    logResult("Widescreen enabled: camera and visibility planes, flight viewport, final composition clip.\r\n");
}

static bool loadOriginal() {
    if (!realModule) {
        wchar_t path[MAX_PATH];
        const DWORD n = GetModuleFileNameW(selfModule, path, MAX_PATH);
        if (!n || n >= MAX_PATH) return false;
        wchar_t* file = std::wcsrchr(path, L'\\');
        if (!file) return false;
        wcscpy_s(file + 1, MAX_PATH - (file + 1 - path), L"gl_00007_original.dll");
        realModule = LoadLibraryExW(path, nullptr, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!realModule) {
            logResult("Widescreen disabled: original renderer or its dependencies could not load.\r\n");
            return false;
        }
    }
    return true;
}

extern "C" __declspec(dllexport) void __cdecl InitGl() {
    if (!loadOriginal()) return;
    auto init = reinterpret_cast<void (__cdecl*)()>(GetProcAddress(realModule, "InitGl"));
    if (init) init();
}

extern "C" __declspec(dllexport) void* __cdecl CreateGl() {
    if (!loadOriginal()) return nullptr;
    auto factory = reinterpret_cast<void* (__cdecl*)()>(GetProcAddress(realModule, "CreateGl"));
    if (!factory) return nullptr;
    graphics = static_cast<unsigned char*>(factory());
    if (graphics && !initialized) {
        initialized = true;
        installHooks();
    }
    return graphics;
}

extern "C" __declspec(dllexport) void __cdecl DestroyGl(void* object) {
    if (!realModule) return;
    if (graphics == object) graphics = nullptr;
    auto destroy = reinterpret_cast<void (__cdecl*)(void*)>(GetProcAddress(realModule, "DestroyGl"));
    if (destroy) destroy(object);
}

BOOL WINAPI DllMain(HINSTANCE module, DWORD reason, LPVOID) {
    if (reason == DLL_PROCESS_ATTACH) {
        selfModule = module;
        DisableThreadLibraryCalls(module);
    }
    return TRUE;
}

#ifdef WCPWIDE_SELFTEST
#include <cassert>
#include <cstdio>
int wmain(int argc, wchar_t** argv) {
    alignas(16) unsigned char mockGraphics[0xf10] = {}, camera[0x200] = {};
    graphics = mockGraphics;
    field<int>(graphics, 8) = 2560; field<int>(graphics, 12) = 1440;
    field<float>(graphics, 0x10) = 3; field<float>(graphics, 0x18) = 320;
    field<int>(camera, 0x68) = 639; field<int>(camera, 0x6c) = 479;
    field<int>(camera, 0x70) = 320; field<int>(camera, 0x74) = 240;
    field<int>(camera, 0x78) = 320; field<int>(camera, 0x7c) = 240;
    field<float>(camera, 0x8c) = std::sqrt(3.0f);
    field<float>(camera, 0x90) = 2.41421356f;
    field<float>(camera, 0x94) = 320 * std::sqrt(3.0f);
    unsigned char before[sizeof camera]; std::memcpy(before, camera, sizeof camera);
    CameraSave saved, nested;
    assert(widen(camera, saved));
    assert(!widen(camera, nested));
    assert(field<int>(camera, 0x60) * 3 + 320 <= 0);
    assert((field<int>(camera, 0x68) + 1) * 3 + 320 >= 2560);
    assert(std::memcmp(camera + 0x90, before + 0x90, 12) == 0);
    const float x = std::tan(35.0f * 3.14159265f / 180.0f);
    assert(x * std::sqrt(3.0f) > 1); // Old 30-degree horizontal boundary rejects this point.
    assert(field<float>(camera, 0xc0) * x + field<float>(camera, 0xc8) < 0);
    assert(std::fabs(field<float>(camera, 0xc0) * field<float>(camera, 0xc0) +
                     field<float>(camera, 0xc8) * field<float>(camera, 0xc8) - 1) < 0.00001f);
    restore(nested); restore(saved);
    assert(std::memcmp(before, camera, sizeof camera) == 0);
    field<int>(camera, 0x60) = 500; field<int>(camera, 0x64) = 17;
    field<int>(camera, 0x68) = 595; field<int>(camera, 0x6c) = 112;
    assert(!widen(camera, saved));
    assert(originalFullRectangle(320, 0, 1920, 1440));
    assert(!originalFullRectangle(1820, 1101, 288, 288));
    std::puts("PASS: expanded horizontal visibility, preserved vertical view/pixel scale, exact restoration, nested and VDU exclusions.");
    if (argc == 3 && !std::wcscmp(argv[1], L"--proxy-smoke")) {
        wchar_t dependencies[MAX_PATH];
        const DWORD length = GetFullPathNameW(argv[2], MAX_PATH, dependencies, nullptr);
        assert(length && length < MAX_PATH);
        assert(SetDllDirectoryW(dependencies));
        HMODULE proxy = LoadLibraryW(L".\\gl_00007.dll");
        assert(proxy);
        auto init = reinterpret_cast<void (__cdecl*)()>(GetProcAddress(proxy, "InitGl"));
        auto create = reinterpret_cast<void* (__cdecl*)()>(GetProcAddress(proxy, "CreateGl"));
        auto destroy = reinterpret_cast<void (__cdecl*)(void*)>(GetProcAddress(proxy, "DestroyGl"));
        assert(init && create && destroy);
        assert(GetProcAddress(proxy, MAKEINTRESOURCEA(1)) == reinterpret_cast<FARPROC>(create));
        assert(GetProcAddress(proxy, MAKEINTRESOURCEA(2)) == reinterpret_cast<FARPROC>(destroy));
        assert(GetProcAddress(proxy, MAKEINTRESOURCEA(3)) == reinterpret_cast<FARPROC>(init));
        init();
        void* object = create();
        assert(object);
        destroy(object);
        FreeLibrary(proxy);
        std::puts("PASS: proxy loading, export names/ordinals, original factory/destructor, unsupported-host fallback.");
    }
}
#endif
