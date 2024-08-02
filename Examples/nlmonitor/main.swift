import CNetLink
import Dispatch
import NetLink

@main
struct nlmonitor {
  public static func main() async throws {
    let socket = try NLSocket(protocol: NETLINK_ROUTE)
    try socket.notifyRtLinks()
    for try await link in socket.notifications {
      debugPrint("found link \(link)")
    }
  }
}
