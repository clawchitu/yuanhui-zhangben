// swift-tools-version: 6.0
// ShopCore：元辉账本的模型与纯逻辑（S12）。不含界面、不含网络。
import PackageDescription

let package = Package(
    name: "ShopCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShopCore", targets: ["ShopCore"]),
    ],
    targets: [
        .target(name: "ShopCore"),
        .testTarget(name: "ShopCoreTests", dependencies: ["ShopCore"]),
    ]
)
