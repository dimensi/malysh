import ProjectDescription

let minimumIOS = "27.1"

let settings: Settings = .settings(base: [
    "SWIFT_VERSION": "6.0", "SWIFT_STRICT_CONCURRENCY": "complete",
    "DEVELOPMENT_TEAM": "YBBAN7R28K", "CODE_SIGN_STYLE": "Automatic",
    "APS_ENVIRONMENT": "development",
    "IPHONEOS_DEPLOYMENT_TARGET": .string(minimumIOS), "TARGETED_DEVICE_FAMILY": "1",
    "MARKETING_VERSION": "1.0.0", "CURRENT_PROJECT_VERSION": "1",
], configurations: [
    .debug(name: "Debug", settings: ["CLOUDKIT_ENVIRONMENT": "Development"]),
    .release(name: "Release", settings: ["CLOUDKIT_ENVIRONMENT": "Production"]),
])
let project = Project(name: "Malysh", settings: settings, targets: [
    .target(name: "Malysh", destinations: [.iPhone], product: .app,
            bundleId: "dev.dimensi.malysh", deploymentTargets: .iOS(minimumIOS),
            infoPlist: .extendingDefault(with: [
                "NSCameraUsageDescription": "Сфотографировать малыша и добавить снимок в семейный дневник.",
                "NSPhotoLibraryAddUsageDescription": "Сохранить оригинал снимка в Фото на этом iPhone.",
                "CFBundleDisplayName": "$(INFOPLIST_KEY_CFBundleDisplayName)", "CFBundleDevelopmentRegion": "ru",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "UILaunchScreen": [:], "UIBackgroundModes": ["remote-notification"],
                "CKSharingSupported": true,
                "NSSupportsLiveActivities": true,
                "CFBundleURLTypes": [["CFBundleURLName": "dev.dimensi.malysh.widgets",
                                      "CFBundleURLSchemes": ["malysh"]]],
                "ITSAppUsesNonExemptEncryption": false,
                "UISupportedInterfaceOrientations": ["UIInterfaceOrientationPortrait"],
                "UIApplicationSceneManifest": ["UIApplicationSupportsMultipleScenes": false],
            ]), sources: ["Sources/**"], resources: ["Resources/Assets.xcassets", "Resources/PrivacyInfo.xcprivacy"],
            entitlements: .file(path: "Resources/Malysh.entitlements"),
            dependencies: [.target(name: "MalyshWidgets")],
            settings: .settings(base: [
                "INFOPLIST_KEY_CFBundleDisplayName": "Малыш",
                "PROVISIONING_PROFILE_SPECIFIER": "$(MALYSH_PROFILE_UUID)",
            ]),
            coreDataModels: [.coreDataModel("Resources/Malysh.xcdatamodeld")]),
    .target(name: "MalyshWidgets", destinations: [.iPhone], product: .appExtension,
            bundleId: "dev.dimensi.malysh.widgets", deploymentTargets: .iOS(minimumIOS),
            infoPlist: .extendingDefault(with: [
                "CFBundleDisplayName": "$(INFOPLIST_KEY_CFBundleDisplayName)", "CFBundleDevelopmentRegion": "ru",
                "CFBundleShortVersionString": "$(MARKETING_VERSION)",
                "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
                "NSExtension": ["NSExtensionPointIdentifier": "com.apple.widgetkit-extension"],
            ]), sources: ["WidgetExtension/**", "Sources/Domain.swift", "Sources/DesignSystem.swift",
                          "Sources/Widgets/**",
                          "Sources/LiveActivities/CareActivityAttributes.swift",
                          "Sources/LiveActivities/CareActivityIntents.swift"],
            resources: ["Resources/Assets.xcassets", "Resources/PrivacyInfo.xcprivacy"],
            entitlements: .file(path: "Resources/MalyshWidgets.entitlements"),
            settings: .settings(base: [
                "APPLICATION_EXTENSION_API_ONLY": "YES", "SKIP_INSTALL": "YES",
                "INFOPLIST_KEY_CFBundleDisplayName": "Малыш · виджеты",
                "PROVISIONING_PROFILE_SPECIFIER": "$(MALYSH_WIDGET_PROFILE_UUID)",
                "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "$(inherited) MALYSH_WIDGET_EXTENSION",
            ])),
    .target(name: "MalyshTests", destinations: [.iPhone], product: .unitTests,
            bundleId: "dev.dimensi.malysh.tests", deploymentTargets: .iOS(minimumIOS),
            infoPlist: .default, sources: ["Tests/**"],
            dependencies: [.target(name: "Malysh")]),
    .target(name: "MalyshUITests", destinations: [.iPhone], product: .uiTests,
            bundleId: "dev.dimensi.malysh.uitests", deploymentTargets: .iOS(minimumIOS),
            infoPlist: .default, sources: ["UITests/**"], dependencies: [.target(name: "Malysh")]),
], schemes: [.scheme(name: "Malysh", shared: true, buildAction: .buildAction(targets: ["Malysh"]),
                     testAction: .targets(["MalyshTests", "MalyshUITests"], configuration: .debug),
                     runAction: .runAction(configuration: .debug))])
