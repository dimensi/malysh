import ProjectDescription

let settings: Settings = .settings(base: [
    "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete",
    "DEVELOPMENT_TEAM": "YBBAN7R28K", "CODE_SIGN_STYLE": "Automatic",
    "APS_ENVIRONMENT": "development",
    "IPHONEOS_DEPLOYMENT_TARGET": "26.0", "TARGETED_DEVICE_FAMILY": "1",
    "MARKETING_VERSION": "1.0.0", "CURRENT_PROJECT_VERSION": "1",
], configurations: [
    .debug(name: "Debug", settings: ["CLOUDKIT_ENVIRONMENT": "Development"]),
    .release(name: "Release", settings: ["CLOUDKIT_ENVIRONMENT": "Production"]),
])
let project = Project(name: "Malysh", settings: settings, targets: [
    .target(name: "Malysh", destinations: [.iPhone], product: .app,
            bundleId: "dev.dimensi.malysh", deploymentTargets: .iOS("26.0"),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "Малыш", "CFBundleDevelopmentRegion": "ru",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:], "UIBackgroundModes": ["remote-notification"],
                "CKSharingSupported": true,
                "ITSAppUsesNonExemptEncryption": false,
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false],
            ]), sources: ["Sources/**"], resources: ["Resources/Assets.xcassets", "Resources/PrivacyInfo.xcprivacy"],
            entitlements: .file(path: "Resources/Malysh.entitlements"),
            coreDataModels: [.coreDataModel("Resources/Malysh.xcdatamodeld")]),
    .target(name: "MalyshTests", destinations: [.iPhone], product: .unitTests,
            bundleId: "dev.dimensi.malysh.tests", deploymentTargets: .iOS("26.0"),
            infoPlist: .default, sources: ["Tests/**"], dependencies: [.target(name: "Malysh")]),
    .target(name: "MalyshUITests", destinations: [.iPhone], product: .uiTests,
            bundleId: "dev.dimensi.malysh.uitests", deploymentTargets: .iOS("26.0"),
            infoPlist: .default, sources: ["UITests/**"], dependencies: [.target(name: "Malysh")]),
], schemes: [.scheme(name: "Malysh", shared: true, buildAction: .buildAction(targets: ["Malysh"]),
                     testAction: .targets(["MalyshTests", "MalyshUITests"], configuration: .debug),
                     runAction: .runAction(configuration: .debug))])
