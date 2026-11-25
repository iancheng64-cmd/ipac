import Foundation

struct MoreRamOperationState {
    enum Kind: Hashable {
        case authentication
        case appIDs
        case capabilityUpdate
    }

    struct Token: Equatable {
        fileprivate let identifier: UUID
        fileprivate let kind: Kind
        fileprivate let teamID: String?
    }

    private var active: [Kind: Token] = [:]

    mutating func begin(_ kind: Kind, teamID: String? = nil) -> Token {
        let token = Token(identifier: UUID(), kind: kind, teamID: teamID)
        active[kind] = token
        return token
    }

    func isCurrent(_ token: Token, selectedTeamID: String? = nil) -> Bool {
        guard active[token.kind] == token else { return false }
        guard let selectedTeamID else { return true }
        return token.teamID == selectedTeamID
    }

    func check(_ token: Token, selectedTeamID: String? = nil) throws {
        try Task.checkCancellation()
        guard isCurrent(token, selectedTeamID: selectedTeamID) else {
            throw CancellationError()
        }
    }

    @discardableResult
    mutating func finish(_ token: Token) -> Bool {
        guard isCurrent(token) else { return false }
        active.removeValue(forKey: token.kind)
        return true
    }

    mutating func invalidate(_ kind: Kind) {
        active.removeValue(forKey: kind)
    }

    mutating func invalidateAll() {
        active.removeAll()
    }
}

enum MoreRamAppIDSelection {
    static func matchesCurrentApp(_ bundleIdentifier: String, currentBundleIdentifier: String) -> Bool {
        !bundleIdentifier.isEmpty
            && !currentBundleIdentifier.isEmpty
            && bundleIdentifier.caseInsensitiveCompare(currentBundleIdentifier) == .orderedSame
    }
}
