// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacRAR",
    platforms: [.macOS(.v13)],
    dependencies: [],
    targets: [
        // ① RARLAB UnRAR 官方源码（C++，静态编译为 libunrar.a + C shim），
        //    由 Scripts/build_unrar.sh 生成 framework 形态 XCFramework，
        //    支持 RAR4/RAR5 加密解压（libarchive 不支持 RAR 加密）。
        //    详见 docs/dependency.md 与脚本头部说明。
        .binaryTarget(
            name: "UnRAR",
            path: "Vendor/unrar.xcframework"
        ),

        // ③ 领域层：纯 Swift，无 UI / 无系统框架依赖
        .target(name: "Core", dependencies: []),

        // ④ 适配层：实现 Core 的 ExtractEngine 协议，内部封装 UnRAR shim C API
        .target(
            name: "Infrastructure",
            dependencies: [
                "Core",
                "UnRAR"
            ]
        ),

        // ⑤ 可执行层：App 装配 + UI（前端成员补全 UI 文件）
        .executableTarget(
            name: "RARExtractor",
            dependencies: ["Core", "Infrastructure"]
        ),

        // 测试
        .testTarget(
            name: "CoreTests",
            dependencies: ["Core"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
