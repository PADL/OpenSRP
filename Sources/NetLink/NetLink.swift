import CNetLink
import Dispatch
import Glibc
import SystemPackage

typealias NLMessage = OpaquePointer

private func NLSocket_CB(
  _ msg: OpaquePointer!,
  _ arg: UnsafeMutableRawPointer!
) -> CInt {
  let nlSocket = Unmanaged<NLSocket>.fromOpaque(arg).takeUnretainedValue()
  let hdr = nlmsg_hdr(msg)!
  nlSocket.resume(sequence: hdr.pointee.nlmsg_seq, with: Result.success(msg))
  return 0
}

private func NLSocket_ErrCB(
  _ nla: UnsafeMutablePointer<sockaddr_nl>?,
  _ err: UnsafeMutablePointer<nlmsgerr>?,
  _ arg: UnsafeMutableRawPointer?
) -> CInt {
  0
}

public final class NLSocket {
  private typealias Continuation = CheckedContinuation<OpaquePointer, Error>

  private let _sk: OpaquePointer!
  private let _source: any DispatchSourceRead
  private var _lastError: CInt = 0 // TODO: managedCriticalState

  private var requests = [UInt32: Continuation]()

  init() throws {
    guard let sk = nl_socket_alloc() else { throw Errno.noMemory }
    _sk = sk

    nl_socket_set_nonblocking(sk)
    let fd = nl_socket_get_fd(sk)

    _source = DispatchSource.makeReadSource(fileDescriptor: fd)
    _source.activate()
    _source.setEventHandler(handler: onEvent)

    nl_socket_modify_cb(
      sk,
      NL_CB_VALID,
      NL_CB_CUSTOM,
      NLSocket_CB,
      Unmanaged.passUnretained(self).toOpaque()
    )
    nl_socket_modify_err_cb(
      sk,
      NL_CB_CUSTOM,
      NLSocket_ErrCB,
      Unmanaged.passUnretained(self).toOpaque()
    )
  }

  deinit {
    _source.cancel()
    nl_socket_free(_sk)
  }

  private func onEvent() {
    if nl_recvmsgs_default(_sk) < 0 {
      _lastError = errno
    }
  }

  private func allocateSequenceNumber() -> UInt32 {
    nl_socket_use_seq(_sk)
  }

  fileprivate func resume(
    sequence: UInt32,
    with result: Result<OpaquePointer, Error>
  ) {
    guard let continuation = requests[sequence] else {
      return
    }
    requests.removeValue(forKey: sequence)
    continuation.resume(with: result)
  }

  private func requestResponse(
    sequence: UInt32,
    _ body: @escaping @Sendable (UInt32) throws -> NLMessage
  ) async throws -> NLMessage {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        requests[sequence] = continuation
        Task {
          let message = try body(sequence)
          if nl_send_auto(_sk, message) < 0 {
            resume(sequence: sequence, with: .failure(Errno(rawValue: errno)))
          }
        }
      }
    }, onCancel: {
      Task { resume(sequence: sequence, with: .failure(CancellationError())) }
    })
  }
}
