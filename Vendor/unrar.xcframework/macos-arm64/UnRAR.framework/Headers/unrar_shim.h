// =============================================================================
// unrar_shim.h — RARLAB UnRAR 官方源码的纯 C 桥接头（Swift 导入面）
// =============================================================================
//
// 本头文件仅暴露纯 C 类型（const char* UTF-8 路径、uint64_t 大小、普通 int 标志、
// void* handle、C 函数指针），把 UnRAR 官方 dll.hpp 里的 wchar_t / #pragma pack /
// LPARAM / C++ 链接细节全部屏蔽在 unrar_shim.cpp 内。Swift 侧只 `import UnRAR`。
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

#ifndef UNRAR_SHIM_H
#define UNRAR_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 打开模式（对齐 dll.hpp RAR_OM_*）。
enum { UNRAR_OM_LIST = 0, UNRAR_OM_EXTRACT = 1, UNRAR_OM_LIST_INCSPLIT = 2 };

// 处理操作（对齐 RAR_SKIP / RAR_TEST / RAR_EXTRACT）。
enum { UNRAR_OP_SKIP = 0, UNRAR_OP_TEST = 1, UNRAR_OP_EXTRACT = 2 };

// header 信息（shim 拷贝后的干净结构，无 pack / 无 wchar_t）。
typedef struct {
    char     fileName[2048];   // UTF-8，截断保护，始终 NUL 结尾
    uint64_t unpackedSize;     // UnpSize | UnpSizeHigh<<32
    uint64_t packedSize;       // PackSize | PackSizeHigh<<32
    uint32_t flags;            // RHDF_*（RHDF_ENCRYPTED=0x04 / RHDF_DIRECTORY=0x20 / ...）
    int      isDirectory;
    int      isEncrypted;
    int      isSymlink;        // RAR5 RedirType!=0 且 !=FSREDIR_FILECOPY(5)；RAR4 FileAttr&S_IFLNK
    int      splitBefore;
    int      splitAfter;
} UnRARHeader;

// 回调集合（shim 内部把 UCM_* 分派到这三个函数指针）。
// 所有回调均在 UnRAR 库的调用线程上同步执行，不得在其中运行 async 逻辑；
// 数据/缓冲仅在回调返回前有效，必须立即拷贝。
typedef struct {
    // UCM_PROCESSDATA：解压出的一块数据（p1=数据指针，p2=块大小）。
    void (*processData)(void *userData, const unsigned char *data, int size);
    // UCM_CHANGEVOLUME：mode=0(ASK, 需回填 nextVolumeName 并返回 1) / 1(NOTIFY, 返回 1 继续)。
    int  (*changeVolume)(void *userData, char *nextVolumeName, int mode);
    // UCM_NEEDPASSWORD：向 passwordBuffer（容量 maxLen，含结尾 NUL）写入密码；
    // 返回 1=已填 / -1=放弃。
    int  (*needPassword)(void *userData, char *passwordBuffer, int maxLen);
    void *userData;
} UnRARCallbacks;

// 打开归档。成功返回非 NULL handle；失败返回 NULL 且 *openResult 填 ERAR_*。
// arcNameUtf8 为 UTF-8 路径；openMode 取 UNRAR_OM_*；callbacks 可为 NULL。
void *unrar_open(const char *arcNameUtf8, int openMode,
                 const UnRARCallbacks *callbacks, int *openResult);

// 读下一个 header。返回 0=成功（header 已填），1=ERAR_END_ARCHIVE，负=错误码。
int   unrar_read_header(void *handle, UnRARHeader *header);

// 处理当前 header：EXTRACT 把文件写到 destDirUtf8 下（内部用 header 原名，自动建子目录）。
int   unrar_process(void *handle, int operation, const char *destDirUtf8);

// 设置密码（文件级加密可直接用；头部加密需配合 needPassword 回调在 open 时提供）。
void  unrar_set_password(void *handle, const char *passwordUtf8);

// 关闭归档并释放 shim 侧回调上下文。
void  unrar_close(void *handle);

#ifdef __cplusplus
}
#endif
#endif
