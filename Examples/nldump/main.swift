import CNetLink
import NetLink
import Dispatch

@main
struct nldump {
  public static func main() async throws {
    let socket = try NLSocket(protocol: NETLINK_ROUTE)
    for try await link in try await socket.getRtLinks() {
      debugPrint("found link \(link)")
    }
  }
}
