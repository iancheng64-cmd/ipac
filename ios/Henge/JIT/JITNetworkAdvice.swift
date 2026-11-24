// SPDX-License-Identifier: GPL-2.0-or-later
import Foundation

/// What the current network path offers, copied from NWPath by the app so this file stays Foundation-only.
struct NetworkPathSnapshot: Equatable {
    var isSatisfied: Bool
    var usesWiFi: Bool
    var usesCellular: Bool
    var usesWired: Bool
}

enum NetworkSituation: Equatable {
    case wifi
    case cellularOnly
    case wired
    case offline

    init(_ path: NetworkPathSnapshot) {
        if !path.isSatisfied {
            self = .offline
        } else if path.usesWiFi {
            self = .wifi
        } else if path.usesWired {
            self = .wired
        } else {
            // A satisfied path with no known interface type is not the cellular case: it keeps the plain VPN advice.
            self = path.usesCellular ? .cellularOnly : .wifi
        }
    }
}

/// What the user can be offered to do next.
enum JITAdviceAction: Equatable {
    case connectLocalDevVPN
    case pairAgain
}

struct JITAdvice: Equatable {
    var message: String
    var actions: [JITAdviceAction]
}

/// Why the built-in helper could not reach this device, read from its error text.
enum JITConnectionProblem: Equatable {
    /// Nothing answered at LocalDevVPN's address: the VPN is off or not routing, or iOS sent the connection elsewhere.
    case unreachable
    /// The device closed the connection, usually because it no longer accepts
    /// this pairing (every new pairing replaces the last).
    case pairing

    init?(helperMessage: String) {
        let text = helperMessage.lowercased()
        let has = { (needles: [String]) in needles.contains(where: text.contains) }
        if has(["connectionreset", "connection reset", "device refused connection"]) {
            self = .pairing
        } else if has(["connectionrefused", "connection refused", "timedout", "timed out",
                       "networkunreachable", "network unreachable", "hostunreachable",
                       "host unreachable", "no route"]) {
            self = .unreachable
        } else {
            return nil
        }
    }
}

enum JITNetworkAdvice {
    static func advice(forHelperMessage helperMessage: String, situation: NetworkSituation) -> JITAdvice? {
        guard let problem = JITConnectionProblem(helperMessage: helperMessage) else { return nil }
        if problem == .pairing {
            return JITAdvice(
                message: "裝置端關閉了連線，通常是已不接受這份配對檔案。請重新配對，並確認已開啟 LocalDevVPN。",
                actions: [.pairAgain, .connectLocalDevVPN])
        }
        guard situation == .cellularOnly else {
            return JITAdvice(message: "Henge 無法連線到此裝置。請先開啟 LocalDevVPN 後再試一次。",
                             actions: [.connectLocalDevVPN])
        }
        return JITAdvice(
            message: "僅使用行動網路時，即使 LocalDevVPN 顯示已連線，iOS 仍可能誤將流量送到行動網路。請在控制中心關閉「行動數據」2 秒後重開，或暫時連上任一 Wi-Fi（熱點亦可）。保持 LocalDevVPN 連線並關閉 Tailscale 等其他 VPN 後重試。",
            actions: [.connectLocalDevVPN])
    }
}

enum JITRetryDecision: Equatable {
    case retry(after: TimeInterval)
    case giveUp
}

/// Whether to try the helper again by itself after it failed to connect.
///
/// On cellular, iOS tends to send the first connection to 10.7.0.1 out over the mobile network instead of through
/// LocalDevVPN, and later ones go through. So an unreachable error on cellular is retried: at most 2 retries (3
/// attempts in all), 4 seconds apart -- long enough for the routing to settle, short enough to feel like one try.
enum JITRetryPolicy {
    static let maxAttempts = 3

    /// Shown while waiting to try attempt `nextAttempt` (the first retry is attempt 2).
    static func statusText(nextAttempt: Int) -> String {
        "正透過 LocalDevVPN 重新嘗試（第 \(nextAttempt)/\(maxAttempts) 次）…"
    }

    static func decision(situation: NetworkSituation, problem: JITConnectionProblem, attempt: Int) -> JITRetryDecision {
        guard situation == .cellularOnly, problem == .unreachable else { return .giveUp }
        return attempt < maxAttempts ? .retry(after: 4) : .giveUp
    }
}
