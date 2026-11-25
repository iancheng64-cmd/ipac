import Foundation

@MainActor
private final class SuspendedResponse {
    private var response: CheckedContinuation<Void, Never>?
    private var observer: CheckedContinuation<Void, Never>?

    func suspend() async {
        await withCheckedContinuation { continuation in
            response = continuation
            observer?.resume()
            observer = nil
        }
    }

    func waitUntilSuspended() async {
        guard response == nil else { return }
        await withCheckedContinuation { observer = $0 }
    }

    func resume() {
        response?.resume()
        response = nil
    }
}

@main
struct MoreRamTests {
    @MainActor
    static func main() async {
        let current = "com.henge.app.CURRENTTEAM"
        precondition(MoreRamAppIDSelection.matchesCurrentApp(current, currentBundleIdentifier: current))
        precondition(MoreRamAppIDSelection.matchesCurrentApp(current.lowercased(), currentBundleIdentifier: current))
        for candidate in ["com.other.ipac-helper", "com.henge.app", "\(current).helper", "", "com.example.henge"] {
            precondition(!MoreRamAppIDSelection.matchesCurrentApp(candidate, currentBundleIdentifier: current))
        }
        precondition(!MoreRamAppIDSelection.matchesCurrentApp(current, currentBundleIdentifier: ""))

        var operations = MoreRamOperationState()
        let originalAuth = operations.begin(.authentication)
        let originalList = operations.begin(.appIDs, teamID: "A")
        let originalUpdate = operations.begin(.capabilityUpdate, teamID: "A")
        operations.invalidateAll()
        for token in [originalAuth, originalList, originalUpdate] {
            precondition(!operations.isCurrent(token))
            precondition(!operations.finish(token))
            expectCancelled { try operations.check(token) }
        }

        let latestAuth = operations.begin(.authentication)
        precondition(!operations.finish(originalAuth))
        precondition(operations.isCurrent(latestAuth))
        let listA = operations.begin(.appIDs, teamID: "A")
        let listB = operations.begin(.appIDs, teamID: "B")
        precondition(!operations.isCurrent(listA, selectedTeamID: "B"))
        precondition(!operations.finish(listA))
        precondition(operations.isCurrent(listB, selectedTeamID: "B"))
        expectCancelled { try operations.check(listB, selectedTeamID: "A") }
        precondition(operations.isCurrent(latestAuth))
        precondition(operations.finish(listB))
        precondition(!operations.isCurrent(listA))

        let update = operations.begin(.capabilityUpdate, teamID: "A")
        expectCancelled { try operations.check(update, selectedTeamID: "B") }
        operations.invalidate(.appIDs)
        precondition(operations.isCurrent(update, selectedTeamID: "A"))
        operations.invalidateAll()
        var fallbackRequests = 0
        do {
            try operations.check(update, selectedTeamID: "A")
            fallbackRequests += 1
        } catch is CancellationError {
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
        precondition(fallbackRequests == 0)

        await checkCancelledAuthAndOldDefer()
        await checkOutOfOrderTeamResponses()
        await checkTaskCancellation()
        print("MoreRam: exact App ID, invalidation, stale cleanup, team responses, and task cancellation passed")
    }

    private static func expectCancelled(_ action: () throws -> Void) {
        do {
            try action()
            preconditionFailure("stale operation must throw CancellationError")
        } catch is CancellationError {
        } catch {
            preconditionFailure("unexpected error: \(error)")
        }
    }

    @MainActor
    private static func checkCancelledAuthAndOldDefer() async {
        var operations = MoreRamOperationState()
        let oldAuth = operations.begin(.authentication)
        let pause = SuspendedResponse()
        var credentialWrites = 0
        var authenticating = true
        let task = Task { @MainActor in
            defer {
                if operations.finish(oldAuth) {
                    authenticating = false
                }
            }
            await pause.suspend()
            do {
                try operations.check(oldAuth)
                credentialWrites += 1
            } catch is CancellationError {
            } catch {
                preconditionFailure("unexpected error: \(error)")
            }
        }
        await pause.waitUntilSuspended()
        operations.invalidateAll()
        let newAuth = operations.begin(.authentication)
        pause.resume()
        await task.value
        precondition(credentialWrites == 0)
        precondition(authenticating)
        precondition(operations.isCurrent(newAuth))
    }

    @MainActor
    private static func checkOutOfOrderTeamResponses() async {
        var operations = MoreRamOperationState()
        let pauseA = SuspendedResponse()
        let pauseB = SuspendedResponse()
        var selectedTeam = "A"
        var displayedTeam: String?
        let tokenA = operations.begin(.appIDs, teamID: "A")
        let taskA = Task { @MainActor in
            await pauseA.suspend()
            if operations.isCurrent(tokenA, selectedTeamID: selectedTeam) {
                displayedTeam = "A"
            }
            operations.finish(tokenA)
        }
        await pauseA.waitUntilSuspended()
        operations.invalidate(.appIDs)
        selectedTeam = "B"
        let tokenB = operations.begin(.appIDs, teamID: "B")
        let taskB = Task { @MainActor in
            await pauseB.suspend()
            if operations.isCurrent(tokenB, selectedTeamID: selectedTeam) {
                displayedTeam = "B"
            }
            operations.finish(tokenB)
        }
        await pauseB.waitUntilSuspended()
        pauseB.resume()
        await taskB.value
        precondition(displayedTeam == "B")
        pauseA.resume()
        await taskA.value
        precondition(selectedTeam == "B" && displayedTeam == "B")
    }

    @MainActor
    private static func checkTaskCancellation() async {
        var operations = MoreRamOperationState()
        let token = operations.begin(.authentication)
        let pause = SuspendedResponse()
        let task = Task { @MainActor in
            await pause.suspend()
            expectCancelled { try operations.check(token) }
        }
        await pause.waitUntilSuspended()
        task.cancel()
        pause.resume()
        await task.value
    }
}
