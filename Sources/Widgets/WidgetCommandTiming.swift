#if DEBUG
    import Foundation

    /// One disposable diagnostic record, containing timing only, never diary content.
    @MainActor
    final class WidgetCommandTiming {
        @TaskLocal static var current: WidgetCommandTiming?
        private let enteredAt = Date()
        private let started = ProcessInfo.processInfo.systemUptime
        private let action: String
        private var phases: [Phase] = []

        private struct Phase: Codable {
            let name: String
            let at: Date
            let elapsedMilliseconds: Double
        }

        private struct Record: Codable {
            let action: String
            let processID: Int32
            let enteredAt: Date
            let phases: [Phase]
            let outcome: String
            let errorDomain: String?
            let errorCode: Int?
        }

        private init(action: String) {
            self.action = action
            mark("intentEnter")
        }

        static func measure(action: String, operation: @MainActor () async throws -> Void) async throws {
            let timing = WidgetCommandTiming(action: action)
            try await $current.withValue(timing) {
                do {
                    try await operation()
                    timing.mark("performExit")
                    timing.write(outcome: "success")
                } catch {
                    timing.mark("performFailure")
                    timing.write(outcome: "failure", error: error as NSError)
                    throw error
                }
            }
        }

        func mark(_ name: String) {
            phases.append(Phase(name: name, at: Date(),
                                elapsedMilliseconds: (ProcessInfo.processInfo.systemUptime - started) * 1000))
            write(outcome: "inProgress")
        }

        private func write(outcome: String, error: NSError? = nil) {
            guard NSClassFromString("XCTestCase") == nil,
                  ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil,
                  let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            else { return }
            let directory = caches.appendingPathComponent("WidgetDiagnostics", isDirectory: true)
            let record = Record(action: action, processID: ProcessInfo.processInfo.processIdentifier,
                                enteredAt: enteredAt, phases: phases, outcome: outcome,
                                errorDomain: error?.domain, errorCode: error?.code)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let data = try JSONEncoder().encode(record)
                try data.write(to: directory.appendingPathComponent("widget-command-timing.json"),
                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                // Diagnostics must not change whether an action succeeds.
            }
        }
    }
#endif
