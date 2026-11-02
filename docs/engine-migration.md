# macOS RAR 解压工具 · 引擎替换架构方案（libarchive → UnRAR）

- 作者：顾图南（Silas Frame）
- 状态：已定稿，待后端（霍承钧）与 DevOps（韩渡川）执行
- 目标读者：后端 / 适配层成员、DevOps
- 前置事实：libarchive 的 RAR reader（`libarchive/archive_read_support_format_rar5.c:4209 rar5_read_data`）硬编码 `"Reading encrypted data is not currently supported"`，与是否启用 OpenSSL 无关，是设计缺失而非配置问题。**决策已定：集成 RARLAB UnRAR 官方 C++ 源码替换 libarchive 作为唯一解压引擎**，以完整支持 RAR4（AES-128）/ RAR5（AES-256，含文件名加密）。

---

## 1. 决策摘要

| 项 | 结论 |
|---|---|
| 引擎 | RARLAB UnRAR 官方源码（C++），静态编译为 `libunrar.a` |
| 接入方式 | **本地 Vendor 静态库 + C shim 层 + framework 形态 XCFramework（binaryTarget）**，复用现有 libarchive XCFramework 的成熟管线 |
| 桥接 | 一个纯 C 头文件 `unrar_shim.h`（`extern "C"`）+ 一个 `.cpp` 适配层，屏蔽 `wchar_t` / `#pragma pack` / `LPARAM` / C++ 链接 |
| 替换范围 | 仅 Infrastructure 层 `LibArchiveExtractEngine` → `UnRARExtractEngine`；Core 层、PasswordProvider、UserNotifier、RARExtractor 编排逻辑全部不动 |
| 两阶段 | 保留：`RAR_OM_LIST_INCSPLIT` 遍历 header 做校验与命名判定 → 重新 `RAR_OM_EXTRACT` 打开解压到临时目录 → 原子移动 |
| 命名/原子移动 | 不变，引擎内部完成，返回 `ExtractionResult.outputURL` |
| 许可 | 纯解压完全合规，义务为「文档 + 源码注释附许可第 2 条原文」 |

**核心结论（给后端的一句话）**：UnRAR 是「读 header → process 写盘」一体化 API，但 `RARReadHeaderEx` 在 `RAR_OM_LIST*` 模式下可**只读 header 不解压**，天然支持我们现有的「先 scan 校验 + 命名判定，再解压」两阶段；代价是 scan 与 extract 各 open 一次（open 仅解析元数据，成本可忽略，现有 libarchive 实现本来就 open 了两次）。

---

## 2. UnRAR C API 集成方式

### 2.1 总体形态（复用现有 libarchive 管线）

```
Vendor/unrar.xcframework/            # binaryTarget，脚本产出
├── Info.plist
└── macos-arm64/UnRAR.framework/
    ├── Headers/unrar_shim.h          # 纯 C 头（extern "C"），Swift 可见
    ├── Modules/module.modulemap      # module UnRAR { header "unrar_shim.h"; link "c++"; link "pthread" }
    └── UnRAR                          # 静态合并 libunrar.a + unrar_shim.o
```

- `Package.swift` 新增 `.binaryTarget(name: "UnRAR", path: "Vendor/unrar.xcframework")`，`Infrastructure` 依赖改为 `["Core", "UnRAR"]`。
- Swift 侧 `import UnRAR` 直接调用 shim 函数，与现有 `import LibArchive` 同构。
- **为什么不是 binaryTarget 裸 `.a`**：SPM 的 `binaryTarget` 不会为裸静态库自动生成 module map，Swift 无法直接 `import`。必须打成含 `Headers/` + `Modules/module.modulemap` 的 framework 形态 XCFramework（这是本仓库 architecture.md §2.2 已踩过并写明的坑，照搬即可）。
- **为什么不直接把 C++ 源码作为 SPM C++ target**：SwiftPM 的 C++ interop（`cxxSettings` + `-cxx-interoperability-mode`）在 `swift-tools 6.0` 下仍不稳定，且 module map 与 C++ 头混编脆弱；预编译静态库 + C shim 与现有 `build_xcframework.sh` 管线一致，构建可复现、`swift build` 零 C++ 编译成本。

### 2.2 编译脚本 `Scripts/build_unrar.sh`（新增，给 DevOps）

```
1. 下载官方源码 tarball：https://www.rarlab.com/rar/unrarsrc-<VER>.tar.gz
   - 锁定版本（建议当前 7.1.x，DLL 版本 10）；记录 SHA256 做可复现校验
   - 官方不在 GitHub 发布源码，建议同时镜像 tarball 到团队内部做离线缓存
2. 解压到 .build/unrar-build/unrar-<VER>/
3. 编译静态库（官方 makefile 自带 lib 目标）：
   cd unrar-<VER> && make -f makefile lib \
     CXXFLAGS="-arch arm64 -mmacosx-version-min=12.0 -std=c++11 -O2"
   → 产出 libunrar.a（目标名以 vendored makefile 为准，兜底方案：clang++ 手工编全部 *.cpp）
4. 编译 shim：clang++ -arch arm64 -mmacosx-version-min=12.0 -Iunrar-<VER> -c unrar_shim.cpp -o unrar_shim.o
5. 合并：xcrun libtool -D -static -o UnRAR unrar_shim.o libunrar.a
6. 组 framework 骨架：
   UnRAR.framework/{Headers/unrar_shim.h, Modules/module.modulemap, UnRAR}
7. xcodebuild -create-xcframework -framework UnRAR.framework -output Vendor/unrar.xcframework
8. 合规：cp unrar-<VER>/license.txt Vendor/unrar-src/LICENSE
```

### 2.3 C++ 静态库与 Swift 的桥接要点

- UnRAR 官方 `dll.hpp` 已经用 `#ifdef __cplusplus extern "C" { ... }` 包好 C 接口，但它是 **C++ 头**（用 `wchar_t`、`enum`、`#pragma pack(1)`、`LONG/LPARAM`），不能直接被 Swift 的 C module 导入。
- **必须加一层 C shim**：`unrar_shim.cpp`（C++ 编译）`#include "dll.hpp"`，对外只暴露纯 C 类型（`const char*` UTF-8 路径、`uint64_t` 大小、普通 `int` 标志、`void*` handle、C 函数指针）。`unrar_shim.h` 是纯 C 头，Swift 只 import 它。
- 关键隔离点：
  1. **`wchar_t` 在 macOS 是 4 字节**（Windows 是 2 字节），shim 内用 `mbstowcs`/`wcstombs` 或 UnRAR 自带 `CharToWide`/`WideToChar` 做 UTF-8 ↔ wide 转换，绝不把 `wchar_t*` 暴露给 Swift。DestPath/DestName 直接走窄字符 `RARProcessFile`（UnRAR 在 Unix 下窄字符串按 UTF-8 处理）。
  2. **`#pragma pack(1)` 结构体**（`RARHeaderDataEx`、`RAROpenArchiveDataEx`）在 shim 内做字段拷贝，转成无 pack 的干净结构再返回 Swift，避免 Swift 端 pack 布局错位。
  3. **C++ 运行时链接**：UnRAR 是 C++，`module.modulemap` 必须 `link "c++"`；`link "pthread"`；若链接报 `iconv` 缺失再加 `link "iconv"`（以 `otool -L` / 链接错误实测为准）。
  4. **ABI**：静态库与 App 用同一 `-arch arm64`、同一 `-mmacosx-version-min`（本项目 `.macOS(.v13)`，脚本用 12.0 即可兼容）编译；部署目标不一致会导致链接警告/失败。

---

## 3. 替换范围（文件级 diff）

### 3.1 保持不变（零改动）

| 文件 | 说明 |
|---|---|
| `Sources/Core/ExtractEngine.swift` | 协议（Port）不动，`UnRARExtractEngine` 同样 `: ExtractEngine` |
| `Sources/Core/NamingResolver.swift` | 命名判定纯逻辑不动 |
| `Sources/Core/SplitArchiveDetector.swift` | 分卷识别纯逻辑不动 |
| `Sources/Core/PathSafetyValidator.swift` | 路径穿越校验纯逻辑不动 |
| `Sources/Core/Model/*.swift` | ExtractionRequest/Progress/Result/Error 全部不动 |
| `Sources/Infrastructure/PasswordProvider.swift` | 密码弹窗不动 |
| `Sources/Infrastructure/UserNotifier.swift` | 系统通知不动 |
| `Sources/RARExtractor/ExtractionCoordinator.swift` | 编排逻辑不动（只依赖 `ExtractEngine` 协议） |
| `Tests/CoreTests/*.swift` | 24 项单测全部继续通过 |

### 3.2 删除

| 文件 | 说明 |
|---|---|
| `Sources/Infrastructure/LibArchiveExtractEngine.swift` | 被 `UnRARExtractEngine.swift` 替换 |
| `Vendor/libarchive.xcframework/` | 不再使用 |
| `Scripts/build_xcframework.sh` | 被 `Scripts/build_unrar.sh` 替换 |

### 3.3 新增

| 文件 | 说明 |
|---|---|
| `Sources/CUnRAR/unrar_shim.h` | 纯 C 头，Swift 导入面（shim 声明 + 常量） |
| `Sources/CUnRAR/unrar_shim.cpp` | C++ 适配层，`#include "dll.hpp"`，实现 extern "C" 函数 |
| `Sources/Infrastructure/UnRARExtractEngine.swift` | 新引擎实现（含回调桥接） |
| `Scripts/build_unrar.sh` | 静态库 + XCFramework 构建脚本 |
| `Vendor/unrar-src/LICENSE` | UnRAR 官方 license.txt 副本（合规） |

### 3.4 修改

| 文件 | 改动点 |
|---|---|
| `Package.swift` | 删 `LibArchive` binaryTarget → 增 `UnRAR` binaryTarget；`Infrastructure` 依赖 `["Core", "UnRAR"]` |
| `Sources/RARExtractor/main.swift` | DI 装配 `LibArchiveExtractEngine()` → `UnRARExtractEngine()`（仅此一行） |
| `docs/architecture.md` | §2.1「否决 UnRAR」结论作废，改写为「采用 UnRAR」，§5.3 加密降级段更新 |
| `docs/dependency.md` | 整体重写为 UnRAR 依赖说明 |

> 建议引擎命名 **`UnRARExtractEngine`**（区别于可执行 target `RARExtractor`，避免 `RARExtractEngine` 与 `RARExtractor` 混淆）。

---

## 4. UnRAR C API 能力映射（精确常量，取自官方 `dll.hpp`）

以下常量值以 vendored `dll.hpp` 为准（当前 DLL 版本 `RAR_DLL_VERSION 10`，对应 RAR 7.0+）：

```c
// 打开模式 RAR_OM_*
#define RAR_OM_LIST          0   // 只列 header，不解压
#define RAR_OM_EXTRACT       1   // 解压
#define RAR_OM_LIST_INCSPLIT 2   // 列 header（含分卷全部 header）

// RARProcessFile 操作
#define RAR_SKIP             0
#define RAR_TEST             1
#define RAR_EXTRACT          2

// 返回码 ERAR_*
#define ERAR_SUCCESS             0
#define ERAR_END_ARCHIVE        10
#define ERAR_NO_MEMORY          11
#define ERAR_BAD_DATA           12
#define ERAR_BAD_ARCHIVE        13
#define ERAR_UNKNOWN_FORMAT     14
#define ERAR_EOPEN              15
#define ERAR_ECREATE            16
#define ERAR_ECLOSE             17
#define ERAR_EREAD              18
#define ERAR_EWRITE             19
#define ERAR_SMALL_BUF          20
#define ERAR_UNKNOWN            21
#define ERAR_MISSING_PASSWORD   22   // 头部加密：open 时缺密码
#define ERAR_EREFERENCE         23
#define ERAR_BAD_PASSWORD       24   // 密码错误（文件级/头部级）
#define ERAR_LARGE_DICT         25

// RARHeaderDataEx.Flags（RHDF_*）
#define RHDF_SPLITBEFORE 0x01
#define RHDF_SPLITAFTER  0x02
#define RHDF_ENCRYPTED   0x04   // 文件内容加密（文件级，header 可见）
#define RHDF_SOLID       0x10
#define RHDF_DIRECTORY   0x20

// RAROpenArchiveDataEx.Flags（ROADF_*，open 后回填）
#define ROADF_ENCHEADERS   0x0080   // 头部加密（-hp）
#define ROADF_FIRSTVOLUME  0x0100

// 回调消息 UCM_*
// UCM_CHANGEVOLUME=0  UCM_PROCESSDATA=1  UCM_NEEDPASSWORD=2
// UCM_CHANGEVOLUMEW=3 UCM_NEEDPASSWORDW=4 UCM_LARGEDICT=5
```

需求 → API 映射：

| 现有需求 | UnRAR API |
|---|---|
| 加密/密码（文件级 AES） | `RHDF_ENCRYPTED` 标志检测；`RARSetPassword(hArc, pw)` 或 `UCM_NEEDPASSWORD` 回调提供密码 |
| 加密/密码（头部 -hp） | `RAROpenArchiveEx` 返回 NULL 且 `OpenResult == ERAR_MISSING_PASSWORD`（`ROADF_ENCHEADERS` 置位）；密码经 `UCM_NEEDPASSWORD` 回调在 open 时提供 |
| 进度回调 | `RARSetCallback(hArc, cb, userData)` + `UCM_PROCESSDATA`（P1=已写盘数据块指针，P2=块大小，解压过程累计） |
| 分卷 | `UCM_CHANGEVOLUME` 回调（P1=下一卷名指针，P2=`RAR_VOL_ASK(0)`/`RAR_VOL_NOTIFY(1)`）；比 libarchive `open_filenames` 更直接，且 UnRAR 按命名惯例自动找卷 |
| 头部遍历（header scan） | `RAR_OM_LIST_INCSPLIT` 模式 + `RARReadHeaderEx` 循环至 `ERAR_END_ARCHIVE`，不落盘 |
| 路径穿越校验 | UnRAR 自身有路径安全，但**仍保留两阶段设计**：scan 与 extract 两个阶段各跑一次 `PathSafetyValidator`（见 §6） |
| 目录/符号链接 | `RHDF_DIRECTORY` 判目录；符号链接走 `RedirType`（RAR5）/ `FileAttr & S_IFLNK`（RAR4/Unix），本项目策略照旧**跳过符号链接** |

---

## 5. C shim 设计（给后端的精确接口）

### 5.1 `unrar_shim.h`（纯 C，Swift 导入面）

```c
#ifndef UNRAR_SHIM_H
#define UNRAR_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// 打开模式（对齐 dll.hpp RAR_OM_*）
enum { UNRAR_OM_LIST = 0, UNRAR_OM_EXTRACT = 1, UNRAR_OM_LIST_INCSPLIT = 2 };
// 处理操作（对齐 RAR_SKIP/TEST/EXTRACT）
enum { UNRAR_OP_SKIP = 0, UNRAR_OP_TEST = 1, UNRAR_OP_EXTRACT = 2 };

// header 信息（shim 拷贝后的干净结构，无 pack / 无 wchar_t）
typedef struct {
    char     fileName[2048];   // UTF-8，截断保护
    uint64_t unpackedSize;     // UnpSize | UnpSizeHigh<<32
    uint64_t packedSize;       // PackSize | PackSizeHigh<<32
    uint32_t flags;            // RHDF_*
    int      isDirectory;
    int      isEncrypted;
    int      isSymlink;        // RedirType != 0（RAR5）或 FileAttr&S_IFLNK（RAR4）
    int      splitBefore;
    int      splitAfter;
} UnRARHeader;

// 回调集合（shim 内部把 UCM_* 分派到这三个函数指针）
typedef struct {
    // UCM_PROCESSDATA：解压出的一块数据；在回调返回后内存即失效，必须立即拷贝
    void (*processData)(void *userData, const unsigned char *data, int size);
    // UCM_CHANGEVOLUME：mode=0(ASK, 需回填 nextVolumeName 并返回1) / 1(NOTIFY, 返回1继续)
    int  (*changeVolume)(void *userData, char *nextVolumeName, int mode);
    // UCM_NEEDPASSWORD：向 passwordBuffer（容量 maxLen）写入密码；返回1已填 / -1放弃
    int  (*needPassword)(void *userData, char *passwordBuffer, int maxLen);
    void *userData;
} UnRARCallbacks;

// 打开归档。成功返回非 NULL handle；失败返回 NULL 且 *openResult 填 ERAR_*。
// arcName 为 UTF-8 路径。callbacks 可为 NULL（无进度/无分卷/无密码）。
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
```

### 5.2 `unrar_shim.cpp` 调度骨架（伪代码，C++）

```cpp
#include "dll.hpp"
#include "unrar_shim.h"

struct ShimCtx { UnRARCallbacks cb; };

// 官方回调：msg=UCM_*，UserData 指向 ShimCtx
static int CALLBACK dispatch(UINT msg, LPARAM userData, LPARAM p1, LPARAM p2) {
    auto *ctx = reinterpret_cast<ShimCtx*>(userData);
    switch (msg) {
    case UCM_PROCESSDATA:
        ctx->cb.processData(ctx->cb.userData, (const unsigned char*)p1, (int)p2);
        return 1;
    case UCM_CHANGEVOLUME:
        return ctx->cb.changeVolume(ctx->cb.userData, (char*)p1, (int)p2);
    case UCM_NEEDPASSWORD:
        return ctx->cb.needPassword(ctx->cb.userData, (char*)p1, (int)p2);
    default: return 1;
    }
}

void *unrar_open(const char *name, int mode, const UnRARCallbacks *cb, int *out) {
    auto *ctx = cb ? new ShimCtx{*cb} : nullptr;
    RAROpenArchiveDataEx data = {};
    data.ArcName = const_cast<char*>(name);
    data.OpenMode = (unsigned)mode;
    data.CmtBuf = nullptr; data.CmtBufSize = 0;         // 不读注释
    if (ctx) { data.Callback = dispatch; data.UserData = (LPARAM)ctx; }
    void *h = RAROpenArchiveEx(&data);
    if (out) *out = (int)data.OpenResult;               // 失败时区分 MISSING_PASSWORD / BAD_PASSWORD
    if (!h) { delete ctx; return nullptr; }
    // 需要记住 ctx 供 close 释放：用 std::unordered_map<void*, ShimCtx*>（shim 内静态）
    return h;
}

int unrar_read_header(void *h, UnRARHeader *out) {
    RARHeaderDataEx hd = {};
    hd.CmtBuf = nullptr; hd.CmtBufSize = 0;
    int rc = RARReadHeaderEx(h, &hd);
    if (rc != ERAR_SUCCESS) return rc;                  // 0 之外含 ERAR_END_ARCHIVE
    snprintf(out->fileName, sizeof(out->fileName), "%s", hd.FileName);
    out->unpackedSize = ((uint64_t)hd.UnpSizeHigh << 32) | hd.UnpSize;
    out->packedSize   = ((uint64_t)hd.PackSizeHigh << 32) | hd.PackSize;
    out->flags        = hd.Flags;
    out->isDirectory  = (hd.Flags & RHDF_DIRECTORY) != 0;
    out->isEncrypted  = (hd.Flags & RHDF_ENCRYPTED) != 0;
    out->isSymlink    = hd.RedirType != 0;              // RAR5；RAR4 另查 FileAttr&S_IFLNK
    out->splitBefore  = (hd.Flags & RHDF_SPLITBEFORE) != 0;
    out->splitAfter   = (hd.Flags & RHDF_SPLITAFTER) != 0;
    return 0;
}

int unrar_process(void *h, int op, const char *destDir) {
    // RAR_EXTRACT 且 destDir 非空：写盘到 destDir 下；SKIP/TEST 传 NULL
    return RARProcessFile(h, op, const_cast<char*>(destDir), nullptr);
}

void unrar_set_password(void *h, const char *pw) { RARSetPassword(h, const_cast<char*>(pw)); }
void unrar_close(void *h) { RARCloseArchive(h); /* 释放 map 中的 ctx */ }
```

---

## 6. 两阶段设计如何保留（关键）

UnRAR 的 API 是「读 header → process 写盘」一体化，且**打开句柄不可回卷**（一次 `RAR_OM_EXTRACT` 只能顺序读完）。保留现有两阶段的方案是**两次 open**：

```
阶段 A（header scan，不解压）
  unrar_open(arc, UNRAR_OM_LIST_INCSPLIT)          ← 只读 header，含分卷全部 header
  循环 unrar_read_header 直到 ERAR_END_ARCHIVE：
    - PathSafetyValidator.validate(fileName)        ← 路径穿越逐条校验（保留）
    - 收集 topLevelEntries / fileCount / totalBytes（累加 unpackedSize）
    - 记录 hasEncrypted |= isEncrypted
  unrar_close
  NamingResolver.resolve(...)                       ← 命名判定（落盘前）

阶段 B（解压到临时目录，含密码重试）
  loop（密码重试）:
    tempRoot = FileManager.temporaryDirectory / UUID
    必要时先取密码（见 §7 密码流程）
    unrar_open(arc, UNRAR_OM_EXTRACT, callbacks)
    若有密码：unrar_set_password + needPassword 回调（头部加密路径）
    循环 unrar_read_header + unrar_process(EXTRACT, tempRoot.path)
      - 每个 header 再跑一次 PathSafetyValidator（双保险，与 libarchive 一致）
      - 目录 → 建目录后 SKIP；符号链接 → SKIP
      - 文件 → unrar_process(UNRAR_OP_EXTRACT, tempRoot)
      - 遇 ERAR_BAD_PASSWORD → 抛 PasswordFailure（触发外层重试）
    unrar_close
  原子移动：tempRoot → naming.outputURL（同卷 moveItem，逻辑照搬）
```

要点：
1. **scan 用 `RAR_OM_LIST_INCSPLIT`（不是 `RAR_OM_LIST`）**：分卷场景下 LIST 只返回第一卷 header，`LIST_INCSPLIT` 会把后续卷的 header 一并列出，保证 `fileCount/totalBytes` 完整、命名判定基于全部顶层条目。
2. **两次 open 是刻意的**：现有 libarchive 实现也是 scan 与 extract 各 open 一次（`scanHeader` 与 `performExtraction` 各调 `openArchive`），语义完全等价，不引入额外复杂度。
3. **头部加密（-hp）特例**：文件名本身加密，阶段 A 无密码无法列出 header（`unrar_open` 返回 NULL + `OpenResult == ERAR_MISSING_PASSWORD`）。此情况下**先提示密码再 scan**（见 §7），拿到密码后阶段 A 用 `needPassword` 回调提供密码打开。这是唯一需要调整现有「scan 无需密码」假设的边界。

---

## 7. 密码流程（UnRAR 版，替换 libarchive 的 `ARCHIVE_PASSWD` 逻辑）

libarchive 在「解压中途命中加密数据」时才触发密码回调；UnRAR 的加密检测更前置，分两种情况：

1. **文件级加密（RHDF_ENCRYPTED）**：阶段 A 的 LIST 就能读到该标志（文件名可见，仅数据加密）。→ 阶段 A 即可知道 `hasEncrypted`，可在进入阶段 B 前就索要密码（或沿用懒加载：阶段 B 首遇 `ERAR_BAD_PASSWORD` 再重试）。
2. **头部加密（ROADF_ENCHEADERS）**：open 即失败，`OpenResult == ERAR_MISSING_PASSWORD`。

统一流程（保留 `passwordProvider` 回调语义不变）：

```swift
// 阶段 A 前置：尝试无密码 LIST 打开
openResult = unrar_open(arc, LIST_INCSPLIT, callbacksWithoutPassword)
if openResult == ERAR_MISSING_PASSWORD {
    // 头部加密：先索要密码
    pw = try await passwordProvider() ?? throw .passwordRequired
    openResult = unrar_open(arc, LIST_INCSPLIT, callbacks(withPassword: pw))
    // 仍 MISSING/BAD → throw .passwordIncorrect
}
... scan ...  // 记录 hasEncrypted

// 阶段 B：密码重试循环（结构照搬现有 LibArchiveExtractEngine.extract 的 while true）
var password = request.password
while true {
    callbacks.password = password          // 预置进回调桥，供 needPassword 同步取用
    openResult = unrar_open(arc, EXTRACT, callbacks)
    if openResult == ERAR_MISSING_PASSWORD { /* 头部加密密码错 → PasswordFailure */ }
    loop header:
        if header.isEncrypted { unrar_set_password(handle, password) }
        rc = unrar_process(EXTRACT, tempRoot)
        if rc == ERAR_BAD_PASSWORD { throw PasswordFailure() }   // 触发重试
    break
}
```

- `PasswordFailure`（引擎私有错误）与「密码错误/取消」映射逻辑**原样保留**：取消且从未给过密码 → `.passwordRequired`，给过但失败 → `.passwordIncorrect`。
- **回调同步性约束**：`UCM_NEEDPASSWORD` 回调是同步 C 回调，**不能在回调内跑 Swift async**。方案是「预置密码进回调桥 → 同步回调读走」，即重试前先 `await passwordProvider()` 拿到密码字符串，再 open。这正是上面循环的顺序。

---

## 8. 命名判定与原子移动：确认不变

- `NamingResolver.resolve`、`moveIntoPlace`（`.singleTopLevelFolder` / `.newFolder` 两分支、`moveItem` 原子移动、`contentsOfDirectory` 平铺移动）**一行不改**。
- UnRAR 引擎仍「内部完成命名 + 移动，返回 `ExtractionResult.outputURL`」，`ExtractionCoordinator` 只拿 `result.outputURL` 通知与退出，不重复调 `NamingResolver`。
- 唯一差异：阶段 A 的 `topLevelEntries` 来源从 libarchive 的 `archive_entry_pathname` 换成 shim 的 `UnRARHeader.fileName`；目录条目仍需以 `/` 结尾（供 `NamingResolver.isDirectoryEntry` 判定），由引擎在收集时补齐——与现有 `scanHeader` 里「directory 补 `/`」逻辑一致。
- `totalBytes` 用 `unpackedSize` 累加（对应 `UCM_PROCESSDATA` 上报的已写盘字节数，进度条 `completedBytes/totalBytes` 语义一致）。

---

## 9. 风险清单与规避

| 风险 | 说明 | 规避 |
|---|---|---|
| C++ 编译与链接 | UnRAR 是 C++，需链 `libc++`；异常/RTTI、`-std` 版本需对齐 | modulemap `link "c++"`；脚本统一 `-std=c++11 -arch arm64 -mmacosx-version-min=12.0`；静态合并进单一二进制，无 dylib 依赖 |
| `wchar_t` 位宽 | macOS 4 字节 vs Windows 2 字节，直接暴露会错位/崩溃 | shim 内完成 UTF-8 ↔ wide 转换，只暴露 `char*`；DestPath 走窄字符 `RARProcessFile` |
| `#pragma pack(1)` | 结构体按字节紧凑，Swift 端手写 struct 易布局错位 | shim 拷贝字段到干净结构，Swift 不接触 packed 结构 |
| ABI / 部署目标 | 静态库与 App 编译参数不一致导致链接失败 | 脚本与 Package 统一 `-arch` 与 `-mmacosx-version-min` |
| 内存管理 | 回调 P1/P2 内存仅回调期间有效；header 内 `FileName` 等为定长数组无需 free | 回调数据立即拷贝；不保留跨回调指针；`unrar_close` 负责释放 shim 侧 ctx（内部 map handle→ctx） |
| 并发 | UnRAR handle 非线程安全，回调在调用线程同步执行 | 每个 `extract` 局部持有 handle，不跨并发边界（与 libarchive 现状一致）；回调只做轻量转发 |
| 沙盒 / 公证 | 静态链接自包含，无子进程、无额外 dylib | 无 entitlements 变更；公证 `--options runtime` 即可，libc++ 为系统库允许链接；App 内 `Resources` 附 LICENSE |
| 许可合规 | 禁止「重造 RAR 压缩算法 / 开发 WinRAR 兼容压缩器」，我们纯解压合规；义务是附第 2 条原文 | 落地到 4 处（见 §10），并随 .app 分发 license.txt |
| 版本不可复现 | RARLAB 官方源码仅 rarlab.com 发布，无 GitHub 官方源 | 锁定版本 + SHA256 校验 + 团队内部镜像 tarball；`Vendor/unrar-src/LICENSE` 随版本归档 |
| 符号链接条目 | RAR4/RAR5 符号链接检测字段不同 | 保守策略：统一 SKIP 符号链接（与 libarchive 现状一致），RAR5 用 `RedirType`、RAR4 用 `FileAttr&S_IFLNK` |
| 头部加密边界 | -hp 归档 scan 需密码，改变「scan 无需密码」假设 | 明确前置索要密码分支（§7），并补一条 -hp 端到端用例 |

---

## 10. 许可合规落地点（附第 2 条原文）

**原文**（以 vendored `license.txt` 为准；当前 RARLAB 官方措辞如下，较旧版本「clearly stated in the documentation and source comments」表述略有差异）：

> 2. UnRAR source code may be used in any software to handle RAR archives without limitations free of charge, but cannot be used to develop RAR (WinRAR) compatible archiver and to re-create RAR compression algorithm, which is proprietary. Distribution of modified UnRAR source code in separate form or as a part of other software is permitted, provided that full text of this paragraph, starting from "UnRAR source code" words, is included in license, or in documentation if license is not available, and in source code comments of resulting package.

**必须落地的 4 处**：

1. `Vendor/unrar-src/LICENSE` —— 完整 `license.txt` 副本，随构建归档。
2. `docs/architecture.md` §2 —— 技术选型处附第 2 条原文（并说明纯解压合规）。
3. `Sources/CUnRAR/unrar_shim.cpp` 文件头注释 —— 附第 2 条原文（官方明确要求 source code comments 含此段）。
4. `Sources/Infrastructure/UnRARExtractEngine.swift` 文件头注释 —— 附第 2 条原文。

另：`.app/Contents/Resources` 打包 LICENSE（build_app.sh 已按目录复制 Resources，把 license.txt 放入 Resources 即可），分发合规。

---

## 11. 下游执行清单

**DevOps（韩渡川）**
- [ ] 写 `Scripts/build_unrar.sh`（§2.2），产出 `Vendor/unrar.xcframework` + `Vendor/unrar-src/LICENSE`，锁版本 + SHA256。
- [ ] `Package.swift`：删 `LibArchive` binaryTarget，增 `UnRAR` binaryTarget；`Infrastructure` 依赖 `["Core", "UnRAR"]`。
- [ ] 删 `Vendor/libarchive.xcframework`、`Scripts/build_xcframework.sh`。
- [ ] 验证 `swift build` 链接通过（`libc++`/`pthread` 齐全）。

**后端（霍承钧）**
- [ ] 写 `Sources/CUnRAR/unrar_shim.h` + `unrar_shim.cpp`（§5）。
- [ ] 写 `Sources/Infrastructure/UnRARExtractEngine.swift`（§6/§7，含回调桥接），实现 `ExtractEngine`。
- [ ] `main.swift` DI 换 `UnRARExtractEngine()`。
- [ ] 删除 `LibArchiveExtractEngine.swift`。
- [ ] 补端到端用例：非加密 RAR / RAR4 加密 / RAR5 加密 / RAR5 -hp 头部加密 / 分卷 / 路径穿越 / 命名冲突，确认 24 项既有单测仍绿。

**文档（顾图南 收尾）**
- [ ] 更新 `docs/architecture.md` §2、§5.3，重写 `docs/dependency.md`。
