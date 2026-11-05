@preconcurrency import CloudKit
@preconcurrency import CoreData
import SwiftUI
import UIKit

@main
@MainActor
struct MalyshApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = CareActivityRuntime.shared.store
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            configuredContent
                .onAppear { delegate.store = store }
                .task { await CareActivityRuntime.shared.ensureReady() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, store.ready {
                        store.perform { try store.reload() }
                    }
                }
        }
    }

    private var testColorScheme: ColorScheme? {
        guard ProcessInfo.processInfo.arguments.contains("--ui-testing") else { return nil }
        if ProcessInfo.processInfo.arguments.contains("--dark-mode") {
            return .dark
        }
        if ProcessInfo.processInfo.arguments.contains("--light-mode") {
            return .light
        }
        return nil
    }

    @ViewBuilder private var configuredContent: some View {
        if ProcessInfo.processInfo.arguments.contains("--large-text") {
            ContentView(store: store)
                .dynamicTypeSize(.accessibility3)
                .preferredColorScheme(testColorScheme)
        } else {
            ContentView(store: store)
                .preferredColorScheme(testColorScheme)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    var store: AppStore? {
        didSet {
            guard let store else { return }
            let invitations = pendingInvitations
            pendingInvitations.removeAll()
            Task { @MainActor in
                for metadata in invitations {
                    await store.accept(metadata)
                }
            }
            if store.persistence.cloudEnabled {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }

    private var pendingInvitations: [CKShare.Metadata] = []

    func accept(_ metadata: CKShare.Metadata) {
        guard let store else { pendingInvitations.append(metadata); return }
        Task { @MainActor in await store.accept(metadata) }
    }

    func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        SceneDelegate.appDelegate = self
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_: UIApplication, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        accept(cloudKitShareMetadata)
    }
}

@MainActor
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    weak static var appDelegate: AppDelegate?
    func scene(_: UIScene, willConnectTo _: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        for context in connectionOptions.urlContexts {
            WidgetRouteInbox.shared.receive(context.url)
        }
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Self.appDelegate?.accept(metadata)
        }
    }

    func scene(_: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        for context in contexts {
            WidgetRouteInbox.shared.receive(context.url)
        }
    }

    func windowScene(_: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Self.appDelegate?.accept(cloudKitShareMetadata)
    }
}
