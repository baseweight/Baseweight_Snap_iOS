// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LlamaBindings",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "LlamaBindings",
            targets: ["LlamaBindings"]),
    ],
    targets: [
        .target(
            name: "LlamaBindings",
            path: "Sources/LlamaBindings",
            cxxSettings: [
                .headerSearchPath("../llama.cpp"),
                .define("GGML_USE_METAL"),
                .define("GGML_USE_ACCELERATE")
            ],
            swiftSettings: [
                .unsafeFlags(["-Xcc", "-fmodule-map-file=Sources/LlamaBindings/module.modulemap"])
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("Accelerate")
            ]
        )
    ],
    cxxLanguageStandard: .cxx17
) 