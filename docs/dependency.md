# UnRAR 依赖落地说明（RARLAB 官方源码 + 本地 XCFramework）

> 文档维护：韩渡川（DevOps）　日期：2026-11-01
> 目标读者：后端 / 适配层成员（Infrastructure、RARExtractor target）
> 前置背景：libarchive 不支持 RAR 加密，引擎已迁移到 RARLAB UnRAR 官方源码，
> 详见 `docs/engine-migration.md`。

## 1. 结论速览

| 项 | 值 |
|---|---|
| 源码来源 | RARLAB 官方 `unrarsrc-7.3.2.tar.gz`（https://www.rarlab.com/rar/） |
| 锁定版本 | 7.3.2（`RAR_DLL_VERSION 11`；7.1.6 在「回调 + 分卷」场景有 BAD_DATA 缺陷，已弃用） |
| SHA256 | `f61a1160d6e2ebbda2ad353c8e82f62ab4312f97fde23c6c2c982d25e0014f99` |
| 二进制形态 | 本地 framework 形态 XCFramework（`Vendor/unrar.xcframework`，arm64 静态库） |
| binaryTarget 名 / module 名 | `UnRAR`（`import UnRAR`） |
| 桥接层 | `Sources/CUnRAR/unrar_shim.h` + `unrar_shim.cpp`（extern "C" 纯 C 接口） |
| 最低 macOS | 12.0（脚本 `-mmacosx-version-min=12.0`，本项目 `.macOS(.v13)` 兼容） |
| 许可 | UnRAR freeware（纯解压合规；须附 license.txt 第 2 条原文） |
| 链接依赖 | `link "c++"` + `link "pthread"`（在 module.modulemap 内声明） |

## 2. 构建（`Scripts/build_unrar.sh`）

流程：下载并校验 SHA256 → `make -f makefile lib` 编译 arm64 `libunrar.a` →
`clang++` 编译 shim → `xcrun libtool -static` 合并 → 组 `UnRAR.framework` 骨架 →
`xcodebuild -create-xcframework` 产出 → 复制 `license.txt` 到 `Vendor/unrar-src/LICENSE`。

```bash
Scripts/build_unrar.sh            # 产出 Vendor/unrar.xcframework + Vendor/unrar-src/LICENSE
```

产出结构：

```
Vendor/unrar.xcframework/
└── macos-arm64/UnRAR.framework/
    ├── Headers/unrar_shim.h
    ├── Modules/module.modulemap   # framework module UnRAR { header "unrar_shim.h"; link "c++"; link "pthread" }
    └── UnRAR                      # libunrar.a + unrar_shim.o 静态合并（ar archive）
```

## 3. `Package.swift` 依赖声明

```swift
.target(
    name: "Infrastructure",
    dependencies: ["Core", "UnRAR"]
),
.binaryTarget(name: "UnRAR", path: "Vendor/unrar.xcframework")
```

代码内 `import UnRAR` 即可调用 shim 函数：`unrar_open` / `unrar_read_header` /
`unrar_process` / `unrar_set_password` / `unrar_close`（详见 `unrar_shim.h`）。

## 4. 关键要点（避坑）

1. **必须打成 framework 形态 XCFramework**：SPM `binaryTarget` 不会为裸静态库自动生成
   module map，Swift 无法直接 `import`；framework 内 `Headers/` + `Modules/module.modulemap`
   才是正确形态（与旧 libarchive 管线同源）。
2. **C++ 链接**：UnRAR 是 C++，`module.modulemap` 必须 `link "c++"`；回调与线程池需要
   `link "pthread"`。shim 内已屏蔽 `wchar_t` / `#pragma pack` / `LPARAM` 细节。
3. **回调同步性**：`UCM_*` 回调是同步 C 回调，不能在其中跑 async；引擎采用
   「先 await 拿密码 → 预置进回调桥 → open」顺序。
4. **版本可复现**：脚本锁定版本 + SHA256 校验；tarball 缓存在 `.build/unrar-build/`。

## 5. 许可合规

UnRAR license.txt 第 2 条原文已落地到 4 处：
1. `Vendor/unrar-src/LICENSE`（完整副本）
2. `docs/architecture.md` §2.1
3. `Sources/CUnRAR/unrar_shim.cpp` 文件头注释
4. `Sources/Infrastructure/UnRARExtractEngine.swift` 文件头注释

纯解压用途完全合规；禁止用于开发 WinRAR 兼容压缩器 / 重造 RAR 压缩算法。
