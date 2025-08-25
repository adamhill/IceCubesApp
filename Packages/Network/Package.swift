// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
  name: "Network",
  defaultLocalization: "en",
  platforms: [
    .iOS(.v17),
    .visionOS(.v1),
  ],
  products: [
    .library(
      name: "Network",
      targets: ["Network"]
    )
  ],
  dependencies: [
    .package(name: "Models", path: "../Models"),
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.8.0")
  ],
  targets: [
    .target(
      name: "Network",
      dependencies: [
        .product(name: "Models", package: "Models"),
        .product(name: "Alamofire", package: "Alamofire")
      ],
      swiftSettings: [
        .swiftLanguageMode(.v6)
      ]
    ),
    .testTarget(
      name: "NetworkTests",
      dependencies: ["Network"]
    ),
  ]
)
