@preconcurrency import CloudKit
@preconcurrency import CoreData
import SwiftUI
import UIKit
import UserNotifications

@main
@MainActor
struct MalyshApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = CareActivityRuntime.shared.store
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            configuredContent
                .task {
                    await CareActivityRuntime.shared.ensureReady(checkCloudAccount: false)
                    await store.resumeInvitation()
                }
                .task { await CareActivityRuntime.shared.ensureReady() }
                .onChange(of: store.cloudMirroringEnabled, initial: true) { _, enabled in
                    if enabled {
                        UIApplication.shared.registerForRemoteNotifications()
                    }
                }
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
            DiaryRootView(store: store)
                .dynamicTypeSize(.accessibility3)
                .preferredColorScheme(testColorScheme)
        } else {
            DiaryRootView(store: store)
                .preferredColorScheme(testColorScheme)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    private var watchBridge: WatchPhoneBridge?

    func application(
        _: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        DiaryPDFFile.removeAbandonedFiles()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        SystemFeedingReminderScheduler.registerCategories()
        let arguments = ProcessInfo.processInfo.arguments
        if !arguments.contains("--ui-testing"), !arguments.contains("--initialize-cloudkit-schema") {
            watchBridge = WatchPhoneBridge(runtime: .shared)
            watchBridge?.activate()
        }
        return true
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping @Sendable (UNNotificationPresentationOptions) -> Void
    ) {
        let payload = Self.reminderPayload(notification.request)
        Task { @MainActor in
            guard let payload, await CareActivityRuntime.shared.acceptFeedingReminderDelivery(
                token: payload.token, babyID: payload.babyID
            ) else {
                completionHandler([])
                return
            }
            completionHandler([.banner, .list, .sound])
        }
    }

    nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping @Sendable () -> Void
    ) {
        let payload = Self.reminderPayload(response.notification.request)
        let action = response.actionIdentifier
        Task { @MainActor in
            // iOS can update scene restoration as part of this completion.
            defer { completionHandler() }
            guard let (token, babyID) = payload else { return }
            switch action {
            case FeedingReminderNotification.snoozeActionID:
                await CareActivityRuntime.shared.snoozeFeedingReminder(token: token, babyID: babyID)
            case FeedingReminderNotification.openActionID, UNNotificationDefaultActionIdentifier:
                await CareActivityRuntime.shared.openFeedingReminder(token: token, babyID: babyID)
            default:
                break
            }
        }
    }

    private nonisolated static func reminderPayload(_ request: UNNotificationRequest)
        -> (token: String, babyID: UUID)?
    {
        guard request.identifier == FeedingReminderNotification.requestID,
              request.content.categoryIdentifier == FeedingReminderNotification.categoryID,
              let token = request.content.userInfo[FeedingReminderNotification.tokenKey] as? String,
              let rawBabyID = request.content.userInfo[FeedingReminderNotification.babyIDKey] as? String,
              let babyID = UUID(uuidString: rawBabyID) else { return nil }
        return (token, babyID)
    }

    func accept(_ metadata: CKShare.Metadata) {
        let runtime = CareActivityRuntime.shared
        runtime.store.receiveInvitation(metadata)
        Task { @MainActor in
            await runtime.ensureReady(checkCloudAccount: false)
            await runtime.store.resumeInvitation()
        }
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
