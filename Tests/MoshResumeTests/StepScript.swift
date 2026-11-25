import Foundation
import MoshResume

/// Records the steps the storage takes and plays a crash or a failure at a chosen one.
final class StepScript: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [StorageStep] = []
    private var plan: [Int: StorageHookAction] = [:]

    /// At the step with this index (counted from 0 over the life of the script) do `action`.
    func at(_ index: Int, _ action: StorageHookAction) {
        lock.lock()
        plan[index] = action
        lock.unlock()
    }

    func clearPlan() {
        lock.lock()
        plan.removeAll()
        lock.unlock()
    }

    var steps: [StorageStep] {
        lock.lock()
        defer { lock.unlock() }
        return seen
    }

    var count: Int { steps.count }

    var hook: StorageHook {
        { [self] step in
            lock.lock()
            defer { lock.unlock() }
            let action = plan[seen.count] ?? .proceed
            seen.append(step)
            return action
        }
    }
}

/// Whether a crash with `action` at step `index` of `steps` came before the directory was taken
/// out of the backup (`dir.protect`). Where the platform has backups (`AppleRecordProtection`)
/// such a directory is refused as "not protected"; elsewhere it is "missing". Nothing was in
/// it either way.
func crashedBeforeProtection(_ steps: [StorageStep], at index: Int, _ action: StorageHookAction) -> Bool {
    guard let protect = steps.firstIndex(where: { $0.operation == .protect }) else { return false }
    return index < protect || (index == protect && action != .crashAfter)
}
