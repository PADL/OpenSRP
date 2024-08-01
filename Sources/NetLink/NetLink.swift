import CNetLink
import Dispatch
import Glibc
import SystemPackage

protocol NLMessageRepresentable {
  init(msg: OpaquePointer) throws
  var msg: OpaquePointer { get throws }
}

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
  private let _readSource: any DispatchSourceRead
  private let _lastError = ManagedCriticalState<CInt>(0)
  private let _requests = ManagedCriticalState<[UInt32: Continuation]>([:])

  init() throws {
    guard let sk = nl_socket_alloc() else { throw Errno.noMemory }
    _sk = sk

    nl_socket_set_nonblocking(sk)
    let fd = nl_socket_get_fd(sk)

    _readSource = DispatchSource.makeReadSource(fileDescriptor: fd)
    _readSource.activate()
    _readSource.setEventHandler(handler: onReadReady)

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
    _readSource.cancel()
    nl_socket_free(_sk)
  }

  @discardableResult
  func throwingErrno(_ body: () -> CInt) throws -> CInt {
    let r = body()
    guard r >= 0 else {
      throw Errno(rawValue: -r)
    }
    return r
  }

  public func connect(proto: CInt) throws {
    try throwingErrno { nl_connect(_sk, proto) }
  }

  public func addMembership(group: CInt) throws {
    try throwingErrno { nl_socket_add_membership(_sk, group) }
  }

  public func dropMembership(group: CInt) throws {
    try throwingErrno { nl_socket_drop_membership(_sk, group) }
  }

  public func setPassCred(_ value: Bool) throws {
    try throwingErrno { nl_socket_set_passcred(_sk, value ? 1 : 0) }
  }

  public var messageBufferSize: Int {
    get {
      nl_socket_get_msg_buf_size(_sk)
    }
    set {
      nl_socket_set_msg_buf_size(_sk, newValue)
    }
  }

  public func setAutoAck(_ enabled: Bool) {
    enabled ? nl_socket_enable_auto_ack(_sk) : nl_socket_disable_auto_ack(_sk)
  }

  private func onReadReady() {
    let r = nl_recvmsgs_default(_sk)
    guard r >= 0 else {
      _lastError.withCriticalRegion { $0 = -r }
      return
    }
  }

  public func useNextSequenceNumber() -> UInt32 {
    nl_socket_use_seq(_sk)
  }

  fileprivate func resume(
    sequence: UInt32,
    with result: Result<OpaquePointer, Error>
  ) {
    var continuation: Continuation!

    _requests.withCriticalRegion {
      continuation = $0[sequence]
      $0.removeValue(forKey: sequence)
    }

    continuation.resume(with: result)
  }

  private func requestResponse(
    sequence: UInt32,
    _ body: @escaping @Sendable (UInt32) throws -> NLMessage
  ) async throws -> NLMessage {
    try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        _requests.withCriticalRegion { $0[sequence] = continuation }
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
