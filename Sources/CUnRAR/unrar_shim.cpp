// =============================================================================
// unrar_shim.cpp — RARLAB UnRAR 官方源码的 C++ 适配层（extern "C"）
// =============================================================================
//
// 职责：
//   1. #include "dll.hpp"（UnRAR 官方 C++ 头），对外只暴露 unrar_shim.h 的纯 C 接口；
//   2. 在 shim 内完成 UTF-8（char*）与 UnRAR 内部的转换——UnRAR 在 macOS（_APPLE）
//      下 CharToWide/WideToChar 即 UTF-8↔wide，故本层无需手写 mbstowcs/wcstombs，
//      也绝不把 wchar_t* / #pragma pack 结构暴露给 Swift；
//   3. 把 UCM_* 回调分派到 UnRARCallbacks 的三个 C 函数指针；
//   4. 用静态 map 维护 handle → ShimCtx，供 unrar_close 释放回调上下文。
//
// 许可（UnRAR license.txt 第 2 条原文，纯解压用途合规）：
//   UnRAR source code may be used in any software to handle
//   RAR archives without limitations free of charge, but cannot be
//   used to develop RAR (WinRAR) compatible archiver and to
//   re-create RAR compression algorithm, which is proprietary.
//   Distribution of modified UnRAR source code in separate form
//   or as a part of other software is permitted, provided that
//   full text of this paragraph, starting from "UnRAR source code"
//   words, is included in license, or in documentation if license
//   is not available, and in source code comments of resulting package.
//
// =============================================================================

// dll.hpp 依赖 _UNIX/_APPLE 决定 CALLBACK/PASCAL/LONG/HANDLE/LPARAM/UINT 定义。
// 编译 libunrar.a 时这些宏由 raros.hpp（经 __APPLE__）间接定义；本适配层单独
// 编译时需在此显式补齐，保证回调 ABI（int(unsigned int, long, long, long)）一致。
#ifndef _UNIX
#define _UNIX
#endif
#ifndef _APPLE
#define _APPLE
#endif

#include "dll.hpp"
#include "unrar_shim.h"

#include <cstdio>
#include <mutex>
#include <unordered_map>

namespace {

// FSREDIR_* 取自 headers.hpp（dll.hpp 未导出）：FSREDIR_NONE=0、FSREDIR_FILECOPY=5。
// FILECOPY 是「文件副本」重定向，非符号链接，应正常解压而非跳过。
constexpr unsigned int kRedirFileCopy = 5;
// HOST_UNIX = 3（headers.hpp 的 HOST_SYSTEM 枚举）；S_IFLNK = 0120000 = 0xA000。
constexpr unsigned int kHostUnix = 3;
constexpr unsigned int kFileTypeMask = 0xF000;

struct ShimCtx {
    UnRARCallbacks cb;
};

std::mutex g_map_mutex;
std::unordered_map<void *, ShimCtx *> g_ctx_map;

// 官方回调分派：msg=UCM_*，UserData 指向 ShimCtx。
int CALLBACK shim_dispatch(UINT msg, LPARAM userData, LPARAM p1, LPARAM p2) {
    auto *ctx = reinterpret_cast<ShimCtx *>(userData);
    if (ctx == nullptr) {
        return -1;
    }
    switch (msg) {
    case UCM_PROCESSDATA:
        if (ctx->cb.processData != nullptr) {
            ctx->cb.processData(ctx->cb.userData,
                                reinterpret_cast<const unsigned char *>(p1),
                                static_cast<int>(p2));
        }
        return 1;
    case UCM_CHANGEVOLUME:
        if (ctx->cb.changeVolume != nullptr) {
            return ctx->cb.changeVolume(ctx->cb.userData,
                                        reinterpret_cast<char *>(p1),
                                        static_cast<int>(p2));
        }
        return -1;
    case UCM_CHANGEVOLUMEW:
        // 宽字符卷名：返回 1 且不修改名称，让 DllVolChange 回退到窄字符
        // UCM_CHANGEVOLUME（若返回 -1 会被直接判定为 abort，不会回退）。
        return 1;
    case UCM_NEEDPASSWORDW:
        // 宽字符密码：返回 -1 让 UnRAR 回退到窄字符 UCM_NEEDPASSWORD。
        return -1;
    case UCM_NEEDPASSWORD:
        if (ctx->cb.needPassword != nullptr) {
            return ctx->cb.needPassword(ctx->cb.userData,
                                        reinterpret_cast<char *>(p1),
                                        static_cast<int>(p2));
        }
        return -1;
    default:
        return 1;
    }
}

} // namespace

extern "C" {

void *unrar_open(const char *arcNameUtf8, int openMode,
                 const UnRARCallbacks *callbacks, int *openResult) {
    ShimCtx *ctx = nullptr;

    RAROpenArchiveDataEx data = {};
    data.ArcName = const_cast<char *>(arcNameUtf8);
    data.OpenMode = static_cast<unsigned int>(openMode);
    data.CmtBuf = nullptr;
    data.CmtBufSize = 0;
    data.OpFlags = 0;

    if (callbacks != nullptr) {
        ctx = new ShimCtx{*callbacks};
        data.Callback = shim_dispatch;
        data.UserData = reinterpret_cast<LPARAM>(ctx);
    }

    HANDLE h = RAROpenArchiveEx(&data);
    if (openResult != nullptr) {
        *openResult = static_cast<int>(data.OpenResult);
    }
    if (h == nullptr) {
        delete ctx;
        return nullptr;
    }
    if (ctx != nullptr) {
        std::lock_guard<std::mutex> lock(g_map_mutex);
        g_ctx_map[h] = ctx;
    }
    return h;
}

int unrar_read_header(void *handle, UnRARHeader *header) {
    if (handle == nullptr || header == nullptr) {
        return -1;
    }
    RARHeaderDataEx hd = {};
    hd.CmtBuf = nullptr;
    hd.CmtBufSize = 0;

    int rc = RARReadHeaderEx(reinterpret_cast<HANDLE>(handle), &hd);
    if (rc != ERAR_SUCCESS) {
        return rc; // 0 之外含 ERAR_END_ARCHIVE(=10) 等错误码
    }

    std::snprintf(header->fileName, sizeof(header->fileName), "%s", hd.FileName);
    header->unpackedSize = (static_cast<uint64_t>(hd.UnpSizeHigh) << 32) | hd.UnpSize;
    header->packedSize = (static_cast<uint64_t>(hd.PackSizeHigh) << 32) | hd.PackSize;
    header->flags = hd.Flags;
    header->isDirectory = (hd.Flags & RHDF_DIRECTORY) != 0;
    header->isEncrypted = (hd.Flags & RHDF_ENCRYPTED) != 0;

    // RAR5：符号链接/交接点/硬链接走 RedirType（FILECOPY 是文件副本，非链接）。
    bool isLink = hd.RedirType != 0 && hd.RedirType != kRedirFileCopy;
    // RAR4：Unix 符号链接编码在 FileAttr 的 S_IFLNK 位（仅当 HostOS==HOST_UNIX）。
    if (!isLink && hd.HostOS == kHostUnix && (hd.FileAttr & kFileTypeMask) == 0xA000) {
        isLink = true;
    }
    header->isSymlink = isLink ? 1 : 0;
    header->splitBefore = (hd.Flags & RHDF_SPLITBEFORE) != 0;
    header->splitAfter = (hd.Flags & RHDF_SPLITAFTER) != 0;
    return 0;
}

int unrar_process(void *handle, int operation, const char *destDirUtf8) {
    if (handle == nullptr) {
        return -1;
    }
    // RAR_EXTRACT 且 destDirUtf8 非空：写盘到该目录下（DestName=NULL 用 header 原名）。
    return RARProcessFile(reinterpret_cast<HANDLE>(handle), operation,
                          const_cast<char *>(destDirUtf8), nullptr);
}

void unrar_set_password(void *handle, const char *passwordUtf8) {
    if (handle == nullptr || passwordUtf8 == nullptr) {
        return;
    }
    RARSetPassword(reinterpret_cast<HANDLE>(handle), const_cast<char *>(passwordUtf8));
}

void unrar_close(void *handle) {
    if (handle == nullptr) {
        return;
    }
    {
        std::lock_guard<std::mutex> lock(g_map_mutex);
        auto it = g_ctx_map.find(handle);
        if (it != g_ctx_map.end()) {
            delete it->second;
            g_ctx_map.erase(it);
        }
    }
    RARCloseArchive(reinterpret_cast<HANDLE>(handle));
}

} // extern "C"
