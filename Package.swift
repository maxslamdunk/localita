// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TurboFieldfare",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
    ],
    products: [
        .library(name: "TurboFieldfare", targets: ["TurboFieldfare"]),
        // A product only so that non-SwiftPM test targets can link it. The iOS
        // device test bundle is an Xcode target, and Xcode can link products
        // but not bare targets; without this the on-device kernel-vs-CPU-
        // reference check cannot import its own comparators.
        .library(
            name: "TurboFieldfareValidationSupport",
            targets: ["TurboFieldfareValidationSupport"]),
        // Products, not bare targets, because the iOS app is an Xcode target
        // and Xcode links products. Same reason `TurboFieldfareValidationSupport`
        // is one: a target the iOS app cannot link is a target the port cannot
        // reuse, which is the whole point of splitting these out of the Mac app.
        .library(name: "TurboFieldfareAppCore", targets: ["TurboFieldfareAppCore"]),
        .library(
            name: "TurboFieldfareAppPresentation",
            targets: ["TurboFieldfareAppPresentation"]),
        .executable(name: "TurboFieldfareRepack", targets: ["TurboFieldfareRepack"]),
        .executable(name: "TurboFieldfareCLI", targets: ["TurboFieldfareCLI"]),
        .executable(name: "TurboFieldfareMac", targets: ["TurboFieldfareMac"]),
        .executable(name: "TurboFieldfareDecodeService", targets: ["TurboFieldfareDecodeService"]),
        .executable(name: "TurboFieldfareServer", targets: ["TurboFieldfareServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
        // Pinned by revision: tag 1.7.3 predates the `\left...\right`
        // duplication fix and typesets 433 of the 607-string coverage sweep
        // against this revision's 479.
        .package(
            url: "https://github.com/mgriebling/SwiftMath.git",
            revision: "1d2c90827e9c3908269d810d055fb03b7da5fd53"),
    ],
    targets: [
        .target(
            name: "TurboFieldfareFormat",
            path: "Sources/TurboFieldfareFormat"
        ),
        .target(
            name: "TurboFieldfare",
            dependencies: [
                "TurboFieldfareFormat",
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Sources/TurboFieldfare",
            resources: [
                .copy("Metal"),
            ]
        ),
        .target(
            name: "TurboFieldfareRepackCore",
            dependencies: ["TurboFieldfareFormat"],
            path: "Sources/TurboFieldfareRepack/Core"
        ),
        .executableTarget(
            name: "TurboFieldfareRepack",
            dependencies: ["TurboFieldfareRepackCore"],
            path: "Sources/TurboFieldfareRepack/Command"
        ),
        .target(
            name: "TurboFieldfareCLICore",
            dependencies: ["TurboFieldfare"],
            path: "Sources/TurboFieldfareCLI",
            exclude: ["Command"]
        ),
        .executableTarget(
            name: "TurboFieldfareCLI",
            dependencies: ["TurboFieldfareCLICore"],
            path: "Sources/TurboFieldfareCLI/Command"
        ),
        .target(
            name: "TurboFieldfareAppCore",
            // No `TurboFieldfareDecodeProtocol`: the only two files that imported
            // it were the decode-service client and its response router, which
            // now live in `TurboFieldfareMacInference`. Dropping the dependency
            // is what keeps the socket transport out of the iOS build.
            dependencies: ["TurboFieldfare", "TurboFieldfareRepackCore"],
            path: "Sources/TurboFieldfareApp/Core",
            resources: [
                .copy("Resources/app-prompts.json"),
            ]
        ),
        // The Mac app runs as two processes so its UI never holds a second
        // model. iOS has no `Process` and a second process would be actively
        // harmful under jetsam, so the socket client is macOS-only by
        // construction — it is the reason `TurboFieldfareAppCore` did not build
        // for iOS. `AppModel`'s default client is the in-process
        // `RealInferenceClient`, which is the one the phone wants; only
        // `TurboFieldfareMacApp` overrides it with this.
        .target(
            name: "TurboFieldfareMacInference",
            dependencies: [
                "TurboFieldfare",
                "TurboFieldfareAppCore",
                "TurboFieldfareDecodeProtocol",
            ],
            path: "Sources/TurboFieldfareApp/MacInference"
        ),
        // Presentation logic with no AppKit in it: streamed-markdown block
        // splitting, fence and math span detection, transcript sync planning,
        // formatting policy. Shared so the iOS views are not a second
        // implementation that drifts from the Mac's and then lies.
        .target(
            name: "TurboFieldfareAppPresentation",
            dependencies: [
                "TurboFieldfare",
                "TurboFieldfareAppCore",
            ],
            path: "Sources/TurboFieldfareApp/Presentation"
        ),
        .target(
            name: "TurboFieldfareMacPresentation",
            dependencies: [
                "TurboFieldfare",
                "TurboFieldfareAppCore",
                "TurboFieldfareAppPresentation",
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            path: "Sources/TurboFieldfareApp/MacPresentation"
        ),
        .target(
            name: "TurboFieldfareDecodeProtocol",
            path: "Sources/TurboFieldfareDecodeProtocol"
        ),
        .executableTarget(
            name: "TurboFieldfareDecodeService",
            dependencies: ["TurboFieldfareAppCore", "TurboFieldfareDecodeProtocol"],
            path: "Sources/TurboFieldfareDecodeService"
        ),
        .target(
            name: "TurboFieldfareServerCore",
            dependencies: [
                "TurboFieldfare",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ],
            path: "Sources/TurboFieldfareServer/Core"
        ),
        .executableTarget(
            name: "TurboFieldfareServer",
            dependencies: ["TurboFieldfareServerCore"],
            path: "Sources/TurboFieldfareServer/Command"
        ),
        .executableTarget(
            name: "TurboFieldfareMac",
            dependencies: [
                "TurboFieldfareAppCore",
                "TurboFieldfareAppPresentation",
                "TurboFieldfareMacInference",
                "TurboFieldfareMacPresentation",
            ],
            path: "Sources/TurboFieldfareApp/Mac",
            resources: [
                .copy("Resources/turbofieldfare-app-icon.png"),
            ]
        ),
        .target(
            name: "TurboFieldfareValidationSupport",
            dependencies: ["TurboFieldfare"],
            path: "Sources/TurboFieldfareValidation/Support"
        ),
        .testTarget(
            name: "TurboFieldfareFormatTests",
            dependencies: ["TurboFieldfareFormat"],
            path: "Tests/TurboFieldfareFormat"
        ),
        .testTarget(
            name: "TurboFieldfareFormatCompatibilityTests",
            dependencies: ["TurboFieldfareFormat", "TurboFieldfare", "TurboFieldfareRepackCore"],
            path: "Tests/TurboFieldfareFormatCompatibility",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TurboFieldfareTestsCore",
            dependencies: [
                "TurboFieldfare",
                "TurboFieldfareValidationSupport",
                "TurboFieldfareRepackCore",
                "TurboFieldfareCLICore",
                .product(name: "Hub", package: "swift-transformers"),
            ],
            path: "Tests/TurboFieldfare/Core",
            resources: [.copy("Runtime/Vision/Fixtures/images")]
        ),
        .testTarget(
            name: "TurboFieldfareRepackTests",
            dependencies: ["TurboFieldfareFormat", "TurboFieldfareRepackCore"],
            path: "Tests/TurboFieldfareRepack/Core"
        ),
        .testTarget(
            name: "TurboFieldfareAppCoreTests",
            dependencies: [
                "TurboFieldfareAppCore", "TurboFieldfare", "TurboFieldfareRepackCore",
                "TurboFieldfareDecodeProtocol",
                // The decode-service client moved out of AppCore; its tests did
                // not, so they reach it from here rather than being split into
                // a target of their own.
                "TurboFieldfareMacInference",
                // `SplitMix64`, for the seeded conversation-history walk. The
                // only seeded generator in the tree; a second copy would drift.
                "TurboFieldfareValidationSupport",
            ],
            path: "Tests/TurboFieldfareApp/Core"
        ),
        .testTarget(
            name: "TurboFieldfareDecodeServiceTests",
            dependencies: ["TurboFieldfareDecodeService", "TurboFieldfareAppCore", "TurboFieldfareDecodeProtocol"],
            path: "Tests/TurboFieldfareDecodeService"
        ),
        .testTarget(
            name: "TurboFieldfareMacPresentationTests",
            dependencies: [
                "TurboFieldfareAppCore",
                "TurboFieldfareAppPresentation",
                "TurboFieldfareMacPresentation",
            ],
            path: "Tests/TurboFieldfareApp/MacPresentation",
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "TurboFieldfareServerTests",
            dependencies: [
                "TurboFieldfareServerCore",
                .product(name: "NIOEmbedded", package: "swift-nio"),
            ],
            path: "Tests/TurboFieldfareServer",
            resources: [.copy("Fixtures")]
        ),
    ]
)
