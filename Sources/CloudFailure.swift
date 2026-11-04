import CloudKit
import Foundation

enum CloudFailure {
    static func message(for error: Error) -> String {
        var pending = [error as NSError]
        var visited: Set<ObjectIdentifier> = []
        var codes: Set<Int> = []
        var networkFailure = false
        // The limit also protects against custom errors that produce new wrappers when bridged.
        while let current = pending.popLast(), visited.count < 100 {
            guard visited.insert(ObjectIdentifier(current)).inserted else { continue }
            if current.domain == CKErrorDomain {
                codes.insert(current.code)
            }
            if current.domain == NSURLErrorDomain {
                networkFailure = true
            }
            if let underlying = current.userInfo[NSUnderlyingErrorKey] as? Error {
                pending.append(underlying as NSError)
            }
            if let multiple = current.userInfo[NSMultipleUnderlyingErrorsKey] as? [Error] {
                pending.append(contentsOf: multiple.map { $0 as NSError })
            }
            if let partial = current.userInfo[CKPartialErrorsByItemIDKey] as? [AnyHashable: Error] {
                pending.append(contentsOf: partial.values.map { $0 as NSError })
            }
        }
        if codes.contains(CKError.badContainer.rawValue) {
            return "Контейнер iCloud недоступен. Проверьте команду разработчика и настройку контейнера приложения. Записи сохранены на iPhone."
        }
        if codes.contains(CKError.notAuthenticated.rawValue) {
            return "Войдите в iCloud в настройках iPhone. Записи доступны локально."
        }
        if networkFailure || !codes.isDisjoint(with: [
            CKError.networkUnavailable.rawValue,
            CKError.networkFailure.rawValue,
            CKError.serviceUnavailable.rawValue,
            CKError.requestRateLimited.rawValue,
        ]) {
            return "Не удалось связаться с iCloud. Проверьте сеть и повторите позже. Записи доступны локально."
        }
        return "iCloud временно недоступен. Повторите позже. Записи доступны локально."
    }
}

struct CloudSetupState {
    private var completed: Set<String> = []
    private var failures: [String: String] = [:]

    mutating func begin(identifier: String) {
        completed.remove(identifier)
    }

    mutating func record(identifier: String, error: Error?) {
        if let error {
            completed.remove(identifier)
            failures[identifier] = CloudFailure.message(for: error)
        } else {
            completed.insert(identifier)
            failures.removeValue(forKey: identifier)
        }
    }

    func isReady(expected: Set<String>) -> Bool {
        !expected.isEmpty && expected.isSubset(of: completed) && failure(expected: expected) == nil
    }

    func failure(expected: Set<String>) -> String? {
        expected.sorted().compactMap { failures[$0] }.first
    }
}
