// swift-tools-version: 6.0
// ShopCore：元辉账本的模型与纯逻辑（S12）、本地库与 outbox（S13）。不含界面、不含网络。
import PackageDescription

let package = Package(
    name: "ShopCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ShopCore", targets: ["ShopCore"]),
    ],
    dependencies: [
        // 本地库（§1、§3.4）。钉死版本，xcodeproj 不进仓库，CI 每次按这个版本解析。
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.9.0"),
    ],
    targets: [
        .target(name: "ShopCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "ShopCoreTests", dependencies: ["ShopCore", .product(name: "GRDB", package: "GRDB.swift")]),
    ]
)
