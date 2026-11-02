# macOS RAR 解压工具 · 架构设计文档

- 项目代号：MacRAR
- 作者：顾图南（Silas Frame）
- 目标：双击 `.rar` 自动解压到所在目录，对齐 macOS 原生 zip 体验，产物为可安装 dmg
- 技术栈：Swift 6 + SwiftUI（AppKit 处理 open-file Apple Event）+ UnRAR（官方源码 7.3.2）
- 目标系统：macOS 13+（开发机 macOS 27.0.1 / Xcode 27.0 / Swift 6.4 / arm64）

---

## 1. 模块划分

采用 **SPM 可执行 target 结构**，三层单向依赖（`App → Core`、`App → Infrastructure`、`Infrastructure → Core`），**Core 不依赖任何层**，保证无环。

### 1.1 目录结构树

```
mac_rar/
├── Package.swift
├── Sources/
│   ├── RARExtractor/                # 可执行层（App 装配 + UI + 系统事件）
│   │   ├── main.swift               # 入口：构造 App + DI 组装
│   │   ├── AppDelegate.swift        # NSApplicationDelegate，处理 open-file Apple Event
│   │   ├── ExtractionCoordinator.swift  # 编排：事件→解压→命名→通知→退出 的主流程
│   │   └── UI/
│   │       ├── RootView.swift       # SwiftUI 极简状态视图（菜单栏/进度/错误）
│   │       └── PasswordSheet.swift  # 密码输入弹窗
│   ├── Core/                        # 领域层（纯 Swift，无 UI / 无系统框架依赖）
│   │   ├── Model/
│   │   │   ├── ExtractionRequest.swift
│   │   │   ├── ExtractionProgress.swift
│   │   │   ├── ExtractionResult.swift
│   │   │   └── ExtractionError.swift
│   │   ├── ExtractEngine.swift      # 解压引擎协议（Port/抽象）
│   │   ├── NamingResolver.swift     # 命名判定（单顶层文件夹 vs 新建+序号）
│   │   ├── SplitArchiveDetector.swift # 分卷识别
│   │   └── PathSafetyValidator.swift  # 路径穿越校验（纯函数）
│   ├── Infrastructure/              # 适配层（平台能力落地）
│   │   ├── UnRARExtractEngine.swift # 实现 ExtractEngine 协议（封装 UnRAR C shim）
│   │   ├── PasswordProvider.swift   # 系统弹窗索要密码（NSAlert）
│   │   └── UserNotifier.swift       # UserNotifications 系统通知
│   └── CUnRAR/                      # UnRAR C 桥接（纯 C 头 + C++ shim，屏蔽 wchar_t/pack 等）
│       ├── unrar_shim.h             # Swift 导入面（extern "C"）
│       └── unrar_shim.cpp           # C++ 适配层，封装 RARLAB dll.hpp
├── Vendor/
│   ├── unrar.xcframework/           # 预编译 XCFramework（arm64，含 libunrar.a + shim）
│   └── unrar-src/LICENSE            # UnRAR 官方 license.txt 副本（合规）
├── Tests/
│   └── CoreTests/                   # NamingResolver / PathSafety / 分卷识别 单测
├── Resources/
│   └── Info.plist                   # UTI 注册 + 文档类型声明
├── Scripts/
│   ├── build_unrar.sh               # 构建 UnRAR XCFramework
│   ├── build_dmg.sh                 # dmg 打包（预留 --codesign / --notarize 接口）
│   └── register_ls.sh               # Launch Services 手动注册脚本
└── docs/
    └── architecture.md
```

### 1.2 各模块单一职责

| 模块 | 职责 | 依赖 |
|---|---|---|
| `RARExtractor`（可执行） | 应用生命周期、open-file 事件入口、DI 组装、UI 呈现、编排退出 | Core + Infrastructure |
| `Core`（领域层） | 解压引擎抽象、命名判定、分卷识别、路径安全校验、错误与数据模型。**可独立单测，不 import AppKit/Foundation 之外的 UI 框架** | 无（仅 Foundation） |
| `Infrastructure`（适配层） | UnRAR C shim 封装与流式解压实现、密码弹窗、系统通知 | Core（实现其协议） |
| `CUnRAR`（桥接 target） | 把 UnRAR C++ 源码以 C module 暴露给 Swift（unrar_shim.h/.cpp + module.modulemap，链接 c++/pthread） | Vendor XCFramework |

### 1.3 依赖方向（无环）

```
        ┌─────────────────┐
        │   RARExtractor  │  (可执行层：装配 + 编排 + UI)
        └───┬─────────┬───┘
            │ 组装/编排 │ 调用平台实现
            ▼         ▼
      ┌─────────┐  ┌──────────────────┐
      │  Core   │◄─┤ Infrastructure   │   Infrastructure 实现 Core 的协议
      │ (抽象)  │  │ (实现)           │
      └─────────┘  └────────┬─────────┘
                            │ import C module
                            ▼
                     ┌──────────────────┐
                     │      UnRAR       │
                     │ (C shim → libunrar)│
                     └──────────────────┘
```

规则：**Core 只定义协议与纯逻辑；Infrastructure 依赖 Core 实现其协议；App 仅依赖两者做依赖注入**。任何实现细节（UnRAR、NSAlert、UNUserNotification）不得出现在 Core。

---

## 2. 技术选型：UnRAR 集成

### 2.1 为何选 UnRAR 官方源码（弃用 libarchive）

> 本节结论已于引擎迁移定稿（`docs/engine-migration.md`）改写：libarchive 的 RAR reader
> 硬编码「不支持加密数据」（`rar5.c` 中 `"Reading encrypted data is not currently supported"`），
> 与是否启用 OpenSSL 无关，是设计缺失。因此**改用 RARLAB UnRAR 官方源码（C++）作为唯一解压引擎**，
> 完整支持 RAR4（AES-128）/ RAR5（AES-256，含文件名加密 -hp）。

| 方案 | 结论 | 理由 |
|---|---|---|
| **UnRAR 官方源码（RARLAB）** | ✅ 采用 | ① 官方解压实现，完整支持 RAR4/RAR5 加密（含 -hp 头部加密），这是核心诉求；② 提供 DLL 形态 C API（`RARReadHeaderEx` / `RARProcessFile` / 回调），可做进度、密码、分卷回调；③ 静态编译为 `libunrar.a` + C shim 打成 framework 形态 XCFramework，复用现有 binaryTarget 管线 |
| libarchive | ❌ 弃用 | RAR reader 硬编码不支持加密数据（与 OpenSSL 无关），无法满足「RAR5 加密解压」核心需求 |
| 外部 `unrar`/`unar` 命令 | ❌ 否决 | macOS 默认**不预装** unrar；子进程调用在沙盒/公证环境受限，无法流式拿进度、错误处理脆弱、依赖外部二进制存在 |

**许可合规（UnRAR license.txt 第 2 条原文，纯解压用途合规）**：

> UnRAR source code may be used in any software to handle
> RAR archives without limitations free of charge, but cannot be
> used to develop RAR (WinRAR) compatible archiver and to
> re-create RAR compression algorithm, which is proprietary.
> Distribution of modified UnRAR source code in separate form
> or as a part of other software is permitted, provided that
> full text of this paragraph, starting from "UnRAR source code"
> words, is included in license, or in documentation if license
> is not available, and in source code comments of resulting package.

本项目仅做**解压**（纯解压完全合规），不重造 RAR 压缩算法、不开发 WinRAR 兼容压缩器。
完整许可副本见 `Vendor/unrar-src/LICENSE`，随 `.app` 分发。

### 2.2 SPM 集成写法

`Package.swift`（`swift-tools-version: 6.0`）：

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRAR",
    platforms: [.macOS(.v13)],
    targets: [
        // ① 预编译 UnRAR，以 framework 形态打包（内含 Headers/unrar_shim.h +
        //    Modules/module.modulemap），Swift 可直接 `import UnRAR`
        .binaryTarget(
            name: "UnRAR",
            path: "Vendor/unrar.xcframework"
        ),
        // ② 领域层
        .target(name: "Core", dependencies: []),
        // ③ 适配层
        .target(
            name: "Infrastructure",
            dependencies: ["Core", "UnRAR"]
        ),
        // ④ 可执行层
        .executableTarget(
            name: "RARExtractor",
            dependencies: ["Core", "Infrastructure"]
        ),
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"]
        ),
    ]
)
```

> 关键点：`binaryTarget` 不会自动生成 module map，因此 UnRAR 必须打包为 **framework 形态的 XCFramework**（包含 `Headers/` 与 `Modules/module.modulemap`，`module.modulemap` 内容：`framework module UnRAR { header "unrar_shim.h"; export *; link "c++"; link "pthread" }`）。裸静态库无法被 Swift 直接 `import`，这是 SPM 最常见的坑。UnRAR 是 C++，静态库与 shim 合并后仍需链接 `libc++`（`link "c++"`）。

### 2.3 XCFramework 构建要点（`Scripts/build_unrar.sh`）

```
1. 下载 UnRAR 官方源码 tarball（rarlab.com/rar/unrarsrc-7.3.2.tar.gz），锁定版本 + SHA256 校验。
2. 静态编译 libunrar.a：官方 makefile `make -f makefile lib`，
   CXXFLAGS="-arch arm64 -mmacosx-version-min=12.0 -std=c++11 -O2"
3. 编译 C shim：clang++ -I<unrar-src> -c unrar_shim.cpp -o unrar_shim.o
4. 合并：xcrun libtool -D -static -o UnRAR unrar_shim.o libunrar.a
5. 构造 framework 骨架：
   UnRAR.framework/{Headers/unrar_shim.h, Modules/module.modulemap, UnRAR(二进制)}
6. xcodebuild -create-xcframework -framework UnRAR.framework -output Vendor/unrar.xcframework
7. 合规：cp <unrar-src>/license.txt Vendor/unrar-src/LICENSE
```

> 注：UnRAR 是 C++，运行时依赖 `libc++` 与 `pthread`（系统库，经 module.modulemap 的 `link "c++"` / `link "pthread"` 声明，无需内嵌）。构建时统一 `-arch arm64` 与 `-mmacosx-version-min=12.0`，避免 ABI / 部署目标不一致。

---

## 3. 核心数据流（双击 → 解压 → 通知 → 退出）

```
用户双击 name.rar
  │
  ▼
[1] LaunchServices 查 Info.plist 注册的 CFBundleDocumentTypes
    （若 App 未运行则冷启动）
  │
  ▼
[2] 系统回调 AppDelegate.application(_:openFile:)        ← 模块 RARExtractor/AppDelegate
  │
  ▼
[3] ExtractionCoordinator.start(url)                      ← 模块 RARExtractor
  │
  ├─[4] SplitArchiveDetector.detect(url)                  ← 模块 Core
  │       判定主卷/分卷；只处理主卷，忽略 .part2+
  │
  ├─[5] 构造 ExtractionRequest
  │       destinationDirectory = url.deletingLastPathComponent()
  │
  ▼
[6] UnRARExtractEngine.extract(request, progress, passwordProvider)
                                                          ← 模块 Infrastructure
  │   阶段 A（header scan，不解压数据）：
  │     - 遍历归档所有 header，收集顶层路径 + 总字节数（供命名判定与进度）
  │     - 对每个 header 调用 PathSafetyValidator.validate()（路径穿越校验）
  │   阶段 B（流式解压到临时目录）：
  │     - 临时目录 = FileManager.temporaryDirectory / UUID
  │     - 逐 header process → 写盘，触发 progress 回调
  │     - 遇 RHDF_ENCRYPTED（文件级）→ 回调 passwordProvider
  │       · 头部加密(-hp)在 open 时 OpenResult==ERAR_MISSING_PASSWORD → 先索要密码
  │       · 弹窗索要密码 → RARSetPassword / needPassword 回调 → 重试
  │       · 用户取消 → 抛 passwordRequired，清理临时目录并退出
  │
  ▼
[7] NamingResolver.resolve(archiveURL, tempOutput)        ← 模块 Core
  │   依据 header scan 结果判定：
  │   - 单顶层文件夹 → 原样输出
  │   - 否则 → 新建文件夹（名 = basename 去扩展名）
  │   冲突时追加序号（Name 2, Name 3, ...）
  │
  ▼
[8] 原子移动：临时目录 → 最终目标目录（RAR 同目录）     ← 模块 Infrastructure
  │   失败则清理临时目录
  │
  ▼
[9] UserNotifier.post(.success/.failure)                  ← 模块 Infrastructure
  │
  ▼
[10] NSApp.terminate()（单文件场景）或回到菜单栏          ← 模块 RARExtractor
```

时序示意（简化）：

```
LaunchServices ──> AppDelegate ──> Coordinator ──> ExtractEngine ──> UnRAR
                                                        │
                                           (需密码) ──> PasswordProvider ──> 用户
                                                        │
                                    ──> NamingResolver ──> 移动文件 ──> UserNotifier
```

---

## 4. 关键接口设计

### 4.1 错误类型（Core/Model/ExtractionError.swift）

```swift
public enum ExtractionError: Error, LocalizedError {
    case archiveNotFound(URL)                 // 归档不存在
    case unsupportedFormat(String)            // 不支持的分卷 / 非 RAR
    case corruptedArchive(String)             // 数据损坏 / 分卷缺失
    case passwordRequired                     // 需要密码但用户取消
    case passwordIncorrect                    // 密码错误
    case pathTraversalAttempt(String)         // 路径穿越（entry 名）
    case diskFull                             // 磁盘不足
    case targetExists(URL)                    // 目标冲突且无法命名
    case underlying(Error)                    // UnRAR 底层错误
}
```

### 4.2 数据模型

```swift
public struct ExtractionRequest: Sendable {
    public let archiveURL: URL
    public let destinationDirectory: URL      // 默认 = archiveURL.deletingLastPathComponent()
    public var password: String?              // 预置密码（可空）
    public let isSplit: Bool                  // 分卷主卷标记（SplitArchiveDetector 填入）
}

public struct ExtractionProgress: Sendable {
    public let completedBytes: Int64
    public let totalBytes: Int64              // 由 header scan 阶段估算
    public let currentEntry: String
}

public enum NamingDecision: Sendable {
    case singleTopLevelFolder(name: String)   // 单顶层文件夹，原样输出
    case newFolder(name: String)              // 新建文件夹（已含序号消歧）
}

public struct ExtractionResult: Sendable {
    public let outputURL: URL                 // 最终落盘目录
    public let extractedFileCount: Int
    public let totalBytes: Int64
    public let namingDecision: NamingDecision
}
```

### 4.3 ExtractEngine 协议（Core/ExtractEngine.swift）

```swift
public protocol ExtractEngine: Sendable {
    /// 解压单个归档到目标目录，返回最终输出目录 URL。
    /// - Parameters:
    ///   - request: 解压请求
    ///   - progress: 进度回调（主线程派发）
    ///   - passwordProvider: 需要密码时被调用；返回 nil 表示用户取消
    /// - Throws: ExtractionError
    func extract(
        _ request: ExtractionRequest,
        progress: @escaping @Sendable (ExtractionProgress) -> Void,
        passwordProvider: @escaping @Sendable () async throws -> String?
    ) async throws -> ExtractionResult
}
```

> Swift 6 严格并发要求：协议与回调均标记 `Sendable`；UnRAR C 句柄仅在 `extract` 同步作用域内局部使用，不跨并发边界，回调同步转发，无需额外隔离。

### 4.4 命名判定算法伪代码（NamingResolver）

```text
// 输入：header scan 得到的顶层条目列表 topLevelEntries（不含已拒绝的非法路径）
//       archiveURL、临时解压根目录 tempRoot
// 输出：最终输出目录 URL + NamingDecision

function resolve(archiveURL, topLevelEntries, tempRoot):
    topLevel = 去重(topLevelEntries 的每个 entry 的首段路径组件)

    if topLevel.count == 1 and isDirectory(topLevel[0]):
        // 情形 1：单顶层文件夹 → 原样输出该文件夹，不额外包一层
        folderName = topLevel[0]
        finalURL = uniquify(tempRoot.deletingLastPathComponent() / folderName)
        return (finalURL, .singleTopLevelFolder(name: folderName))
    else:
        // 情形 2：多个顶层条目 或 单个顶层文件 → 新建文件夹
        base = archiveURL.deletingPathExtension().lastPathComponent
        finalURL = uniquify(archiveURL.deletingLastPathComponent() / base)
        return (finalURL, .newFolder(name: base))

function uniquify(candidate):
    // 对齐 macOS Finder 追加序号风格：Name, Name 2, Name 3, ...
    result = candidate
    counter = 2
    while FileManager.fileExists(result):
        result = 候选目录 / (候选名 + " " + counter)   // 例如 "photo 2"
        counter += 1
    return result
```

**关键决策说明**：
- 命名判定必须在**解压落盘前**完成，因此引擎采用「**header scan → 判定命名 → 流式解压到临时目录 → 原子移动到最终目录**」两阶段，保证 `ExtractionResult.outputURL` 语义正确，且移动为同卷原子操作。
- 多顶层条目时，macOS 原生 zip 会合并进同名文件夹；本方案按团队决策**统一新建文件夹 + 序号消歧**，避免静默覆盖用户已有文件。

---

## 5. 风险与规避

### 5.1 路径穿越校验（Zip Slip 的 RAR 变体）

- **落地**：`PathSafetyValidator.validate(entryPath) -> URL` 纯函数，双保险：
  1. 拒绝绝对路径、含 `..` 组件、空路径的 entry；
  2. 拼接后 `URL.standardized` 归一化，校验 `resolved.path.hasPrefix(targetDir.path + "/")`，确保落点仍在目标目录内；
  3. 默认**跳过符号链接 entry**（不解链），或仅对已校验安全目标解链。
- 校验在 **header scan 阶段就逐条执行**，任何非法 entry 直接抛 `pathTraversalAttempt` 并中止，不写盘。

### 5.2 分卷识别

- **命名模式**（`SplitArchiveDetector`）：
  - 新式：`name.part1.rar` / `name.part01.rar` → 正则 `^(.*)\.part(\d+)\.rar$`
  - 旧式：`name.r00`（配合 `name.rar`）→ 正则 `^(.*)\.r(\d{2})$`
- **策略**：仅当用户双击**主卷**（`name.rar` 或 `name.part1.rar`）时启动；`.part2+` / `.r01+` 忽略，避免重复解压。
- **UnRAR 多卷**：通过 `UCM_CHANGEVOLUME` 回调，UnRAR 按命名惯例自动找卷，回调处理换卷与缺失提示；分卷缺失 → 抛 `corruptedArchive`。

### 5.3 加密归档（密码流程）

- 检测：文件级加密通过 header 的 `RHDF_ENCRYPTED` 标志（LIST 阶段即可见）；头部加密(-hp)在 open 时返回 `ERAR_MISSING_PASSWORD`（`ROADF_ENCHEADERS` 置位）。
- **密码流程**：弹 `NSAlert` 索要密码 → `RARSetPassword` 或 `UCM_NEEDPASSWORD` 回调注入 → 密码错误（`ERAR_BAD_PASSWORD`）从重试循环重来；用户取消 → 抛 `passwordRequired`，清理临时目录，不产生产物。
- 完整支持 RAR4（AES-128）/ RAR5（AES-256），**含 -hp 头部加密**（文件名加密）：头部加密归档需在 header scan 前先索要密码（scan 依赖密码才能列出文件名），详见 `docs/engine-migration.md` §7。

### 5.4 沙盒 / 权限

- 第一版（未签名本地可用版）：**不启用 App Sandbox**，无 entitlements 限制。
- dmg 打包脚本**预留** `--entitlements` 参数，为后续公证做准备。若启用沙盒需声明：
  - `com.apple.security.files.user-selected.read-write`（对 open-file 事件授予的文件及其同目录写权限的关键 entitlement）
  - `com.apple.security.app-sandbox`
- TCC 注意：`~/Downloads`、`~/Desktop` 受 TCC 保护，未签名版依赖系统 open-file 事件授予的访问权；公证版需按需申请 `com.apple.security.files.downloads.read-write` 等。

### 5.5 Launch Services 注册

- 在 `Info.plist` 声明：
  - `UTImportedTypeDeclarations`：自定义 UTI（如 `com.akelab.rar-archive`），`conformsTo: [public.data, public.archive]`，extension `rar`；
  - `CFBundleDocumentTypes` + `LSItemContentTypes` + `CFBundleTypeRole: Viewer`；
  - `LSHandlerRank: Alternate`。
- 安装到 `/Applications` 后 LaunchServices 自动注册；开发期提供 `register_ls.sh`（`lsregister -f <app>`）手动刷新。
- 核心事件入口是 AppDelegate 的 `application(_:openFile:)`（非 `onOpenURL`，后者只处理 URL scheme）。

---

## 6. 开发顺序建议（供排期参考）

1. `CUnRAR` shim + `build_unrar.sh` 打通（先能 `import UnRAR` 解压单个无密码 RAR）
2. `Core` 纯逻辑 + `CoreTests`（NamingResolver / PathSafety / SplitDetector 先测）
3. `Infrastructure.UnRARExtractEngine` 流式解压 + 进度 + 密码回调
4. `RARExtractor` AppDelegate + Coordinator + UI + Info.plist 注册
5. 加密（含 -hp）、分卷、路径穿越端到端联调
6. `build_dmg.sh` + 签名/公证接口预留
