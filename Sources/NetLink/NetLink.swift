//
// Copyright (c) 2024 PADL Software Pty Ltd
//
// Licensed under the Apache License, Version 2.0 (the License);
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an 'AS IS' BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import AsyncAlgorithms
import AsyncExtensions
import CNetLink
import Dispatch
import Glibc
import SystemPackage

public protocol NLObjectConstructible: Sendable {
  init(object: NLObject) throws
}

public typealias NLData = [UInt8]

public typealias NLObjectConstructor = (_: NLObject) throws -> NLObjectConstructible

extension NLData {
  init?(data: OpaquePointer?) {
    guard let data else { return nil }
    var buffer: UnsafeBufferPointer<UInt8>!
    let size = nl_data_get_size(data)
    nl_data_get(data).withMemoryRebound(to: UInt8.self, capacity: size) {
      buffer = UnsafeBufferPointer<UInt8>(start: $0, count: size)
    }
    self = Array(buffer)
  }

  var nl_data: OpaquePointer {
    withUnsafeBytes {
      nl_data_alloc($0.baseAddress, $0.count)
    }
  }
}

public final class NLObject: @unchecked
Sendable, Equatable, Hashable, CustomStringConvertible {
  public static func == (_ lhs: NLObject, _ rhs: NLObject) -> Bool {
    nl_object_identical(lhs._obj, rhs._obj) != 0
  }

  let _obj: OpaquePointer
  let _constructFromObject: NLObjectConstructor?

  fileprivate func construct() throws -> NLObjectConstructible {
    guard let _constructFromObject else {
      debugPrint("NLObject: no constructor registered")
      throw Errno.invalidArgument
    }
    return try _constructFromObject(self)
  }

  convenience init(msg: OpaquePointer, constructFromObject: NLObjectConstructor? = nil) throws {
    var obj: OpaquePointer!

    try withUnsafeMutablePointer(to: &obj) { objRef in
      _ = try throwingErrno {
        nl_msg_parse(msg, { obj, objRef in
          nl_object_get(obj)
          objRef!
            .withMemoryRebound(
              to: OpaquePointer.self,
              capacity: 1
            ) { objRef in
              objRef.pointee = obj!
            }
        }, objRef)
      }
    }

    self.init(obj: obj, constructFromObject: constructFromObject)
    nl_object_put(obj)
  }

  public init(obj: OpaquePointer, constructFromObject: NLObjectConstructor? = nil) {
    nl_object_get(obj)
    _obj = obj
    _constructFromObject = constructFromObject
  }

  public init(consumingObj obj: OpaquePointer, constructFromObject: NLObjectConstructor? = nil) {
    _obj = obj
    _constructFromObject = constructFromObject
  }

  deinit {
    nl_object_put(_obj)
  }

  public var description: String {
    var buffer = [CChar](repeating: 0, count: 1024)
    buffer.withUnsafeMutableBufferPointer {
      nl_object_dump_buf(_obj, $0.baseAddress!, $0.count)
    }
    return String(cString: buffer)
  }

  public var isMarked: Bool {
    get {
      nl_object_is_marked(_obj) != 0
    }
    set {
      newValue ? nl_object_mark(_obj) : nl_object_unmark(_obj)
    }
  }

  public func hash(into hasher: inout Hasher) {
    var hashkey: UInt32 = 0
    nl_object_keygen(_obj, &hashkey, UInt32(MemoryLayout<UInt32>.size))
    hasher.combine(hashkey)
  }

  public var typeString: String {
    String(cString: nl_object_get_type(_obj))
  }

  public var messageType: Int {
    Int(nl_object_get_msgtype(_obj))
  }

  public var isAttributeMask: UInt32 {
    nl_object_get_id_attrs(_obj)
  }
}

private func NLSocket_CB_VALID(
  _ msg: OpaquePointer!,
  _ arg: UnsafeMutableRawPointer!
) -> CInt {
  let nlSocket = Unmanaged<NLSocket>.fromOpaque(arg).takeUnretainedValue()
  let hdr = nlmsg_hdr(msg)!.pointee

  do {
    let constructFromObject: NLObjectConstructor

    switch nlmsg_get_proto(msg) {
    case NETLINK_ROUTE:
      constructFromObject = RTNLLinkMessage.init
    case NETLINK_NETFILTER:
      constructFromObject = NFNLLogMessage.init
    default:
      debugPrint("NLSocket_CB_VALID: unknown NL message \(nlmsg_get_proto(msg))")
      throw Errno.invalidArgument
    }

    let object = try NLObject(msg: msg, constructFromObject: constructFromObject)
    nlSocket.yield(sequence: hdr.nlmsg_seq, with: Result.success(object))
  } catch {
    nlSocket.yield(sequence: hdr.nlmsg_seq, with: Result.failure(error))
    return CInt(NL_SKIP.rawValue)
  }
  return CInt(NL_OK.rawValue)
}

private func NLSocket_CB_FINISH(
  _ msg: OpaquePointer!,
  _ arg: UnsafeMutableRawPointer!
) -> CInt {
  let nlSocket = Unmanaged<NLSocket>.fromOpaque(arg).takeUnretainedValue()
  let hdr = nlmsg_hdr(msg)!.pointee
  nlSocket.finish(sequence: hdr.nlmsg_seq)
  return CInt(NL_STOP.rawValue)
}

private func NLSocket_CB_ACK(
  _ msg: OpaquePointer!,
  _ arg: UnsafeMutableRawPointer!
) -> CInt {
  let nlSocket = Unmanaged<NLSocket>.fromOpaque(arg).takeUnretainedValue()
  let hdr = nlmsg_hdr(msg)!.pointee
  nlSocket.yield(sequence: hdr.nlmsg_seq)
  return CInt(NL_OK.rawValue)
}

private func NLSocket_ErrCB(
  _ nla: UnsafeMutablePointer<sockaddr_nl>!,
  _ err: UnsafeMutablePointer<nlmsgerr>!,
  _ arg: UnsafeMutableRawPointer!
) -> CInt {
  let nlSocket = Unmanaged<NLSocket>.fromOpaque(arg).takeUnretainedValue()
  let hdr = err.pointee.msg
  debugPrint("NLSocket_ErrCB: error \(err.pointee)")
  nlSocket.yield(sequence: hdr.nlmsg_seq, with: Result.failure(Errno(rawValue: -err.pointee.error)))
  return CInt(NL_OK.rawValue)
}

public final class NLSocket: @unchecked Sendable {
  private typealias Continuation = CheckedContinuation<NLObjectConstructible, Error>
  private typealias Stream = AsyncThrowingStream<NLObjectConstructible, Error>
  private typealias Ack = CheckedContinuation<(), Error>
  public typealias Channel = AsyncThrowingChannel<NLObjectConstructible, Error>

  private enum _Request {
    case continuation(Continuation)
    case stream(Stream.Continuation)
    case ack(Ack)

    var hasMultipleResults: Bool {
      switch self {
      case .stream:
        true
      default:
        false
      }
    }
  }

  let _sk: OpaquePointer!
  private let _readSource: any DispatchSourceRead
  private let _requests = ManagedCriticalState<[UInt32: _Request]>([:])

  public let notifications = Channel()

  public init(protocol: Int32) throws {
    guard let sk = nl_socket_alloc() else { throw Errno.noMemory }
    nl_socket_disable_seq_check(sk)
    _sk = sk

    try throwingErrno {
      nl_connect(sk, `protocol`)
    }
    nl_socket_set_nonblocking(sk)

    let fd = nl_socket_get_fd(sk)
    precondition(fd >= 0)

    _readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
    _readSource.setEventHandler(handler: onReadReady)

    nl_socket_modify_cb(
      sk,
      NL_CB_VALID,
      NL_CB_CUSTOM,
      NLSocket_CB_VALID,
      Unmanaged.passUnretained(self).toOpaque()
    )
    nl_socket_modify_cb(
      sk,
      NL_CB_FINISH,
      NL_CB_CUSTOM,
      NLSocket_CB_FINISH,
      Unmanaged.passUnretained(self).toOpaque()
    )
    nl_socket_modify_cb(
      sk,
      NL_CB_ACK,
      NL_CB_CUSTOM,
      NLSocket_CB_ACK,
      Unmanaged.passUnretained(self).toOpaque()
    )
    nl_socket_modify_err_cb(
      sk,
      NL_CB_CUSTOM,
      NLSocket_ErrCB,
      Unmanaged.passUnretained(self).toOpaque()
    )

    _readSource.resume()
  }

  deinit {
    _readSource.cancel()
    nl_socket_free(_sk)
  }

  public func connect(proto: CInt) throws {
    try throwingErrno { nl_connect(_sk, proto) }
  }

  public func add(membership group: rtnetlink_groups) throws {
    try throwingErrno { nl_socket_add_membership(_sk, CInt(group.rawValue)) }
  }

  public func drop(membership group: rtnetlink_groups) throws {
    try throwingErrno { nl_socket_drop_membership(_sk, CInt(group.rawValue)) }
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
      yield(sequence: 0, with: Result.failure(Errno(rawValue: -r)))
      return
    }
  }

  public func useNextSequenceNumber() -> UInt32 {
    nl_socket_use_seq(_sk)
  }

  private func _lookup(sequence: UInt32, forceRemove: Bool) -> _Request? {
    var request: _Request?

    _requests.withCriticalRegion {
      request = $0[sequence]
      if let request, !request.hasMultipleResults || forceRemove {
        $0.removeValue(forKey: sequence)
      }
    }

    return request
  }

  fileprivate func finish(sequence: UInt32) {
    guard let request = _lookup(sequence: sequence, forceRemove: true),
          case let .stream(continuation) = request
    else {
      return
    }
    continuation.finish()
  }

  fileprivate func yield(sequence: UInt32) {
    if let request = _lookup(sequence: sequence, forceRemove: true),
       case let .ack(continuation) = request
    {
      continuation.resume()
    }
  }

  fileprivate func yield(
    sequence: UInt32,
    with result: Result<NLObject, Error>
  ) {
    let result: Result<NLObjectConstructible, Error> = result.flatMap { result in
      Result(catching: { try result.construct() })
    }

    if sequence != 0, let request = _lookup(sequence: sequence, forceRemove: false) {
      switch request {
      case let .continuation(continuation):
        continuation.resume(with: result)
      case let .stream(continuation):
        continuation.yield(with: result)
      default:
        // shouldn't be reached
        break
      }
    } else {
      Task {
        do {
          try await notifications.send(result.get())
        } catch {
          notifications.fail(error)
        }
      }
    }
  }

  func ackRequest(
    message: consuming NLMessage
  ) async throws {
    let sequence = message.sequence
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        _requests.withCriticalRegion { $0[sequence] = .ack(continuation) }
        do {
          try message.send(on: self)
        } catch {
          yield(sequence: sequence, with: .failure(error))
        }
      }
    }, onCancel: {
      yield(sequence: sequence, with: .failure(CancellationError()))
    })
  }

  func continuationRequest(
    message: consuming NLMessage
  ) async throws -> NLObjectConstructible {
    let sequence = message.sequence
    return try await withTaskCancellationHandler(operation: {
      try await withCheckedThrowingContinuation { continuation in
        _requests.withCriticalRegion { $0[sequence] = .continuation(continuation) }
        do {
          try message.send(on: self)
        } catch {
          yield(sequence: sequence, with: .failure(error))
        }
      }
    }, onCancel: {
      yield(sequence: sequence, with: .failure(CancellationError()))
    })
  }

  func streamRequest(
    message: consuming NLMessage
  ) throws -> AsyncThrowingStream<NLObjectConstructible, Error> {
    let sequence = message.sequence
    var stream: Stream!
    _requests.withCriticalRegion { requests in
      let _stream = Stream { continuation in
        requests[sequence] = .stream(continuation)
        continuation.onTermination = { @Sendable _ in
        }
      }
      stream = _stream
    }
    try message.send(on: self)
    return stream
  }
}

@discardableResult
func throwingErrno(_ body: () -> CInt) throws -> CInt {
  let r = body()
  guard r >= 0 else {
    throw Errno(rawValue: -r)
  }
  return r
}

struct NLAttribute {
  var _nla: UnsafePointer<nlattr>

  var type: CInt {
    nla_type(_nla)
  }

  var length: CInt {
    nla_len(_nla)
  }

  func get(attrtype: CInt) -> UInt32 {
    nla_get_u32(_nla)
  }
}

struct NLMessage: ~Copyable {
  var _msg: OpaquePointer!

  init(type: CInt, flags: CInt) throws {
    _msg = nlmsg_alloc_simple(type, flags)
    guard _msg != nil else { throw Errno.noMemory }
  }

  init(hdr: UnsafeMutablePointer<nlmsghdr>) throws {
    _msg = nlmsg_convert(hdr)
    guard _msg != nil else { throw Errno.noMemory }
  }

  init(
    socket: NLSocket,
    type: Int,
    flags: Int32 = 0
  ) throws {
    try self.init(seq: socket.useNextSequenceNumber(), type: type, flags: flags)
  }

  init(
    pid: UInt32 = UInt32(NL_AUTO_PID),
    seq: UInt32 = UInt32(NL_AUTO_SEQ),
    type: Int,
    flags: Int32 = 0
  ) throws {
    var nlh = nlmsghdr()
    nlh.nlmsg_type = UInt16(type)
    nlh.nlmsg_flags = UInt16(flags)
    nlh.nlmsg_seq = seq
    nlh.nlmsg_pid = pid

    _msg = nlmsg_inherit(&nlh)
  }

  func append(_ data: [UInt8], pad: CInt = CInt(NLMSG_ALIGNTO)) throws {
    var data = data
    try throwingErrno {
      data.withUnsafeMutableBufferPointer {
        nlmsg_append(_msg, $0.baseAddress, $0.count, pad)
      }
    }
  }

  func nestStart(attr: CInt) -> NLAttribute {
    NLAttribute(_nla: nla_nest_start(_msg, attr))
  }

  func nestEnd(attr: NLAttribute) {
    nla_nest_end(_msg, UnsafeMutablePointer(mutating: attr._nla))
  }

  func expand(to newlen: Int) throws {
    try throwingErrno { nlmsg_expand(_msg, newlen) }
  }

  func reserve(length: Int, pad: CInt = CInt(NLMSG_ALIGNTO)) throws -> UnsafeMutableRawPointer {
    let ptr = nlmsg_reserve(_msg, length, pad)
    guard let ptr else { throw Errno.noMemory }
    return ptr
  }

  func put(
    pid: UInt32 = UInt32(NL_AUTO_PID),
    seq: UInt32 = UInt32(NL_AUTO_SEQ),
    type: CInt,
    payload: CInt,
    flags: CInt = 0
  ) throws -> UnsafeMutablePointer<nlmsghdr> {
    guard let msghdr = nlmsg_put(_msg, pid, seq, type, payload, flags) else {
      throw Errno.noMemory
    }
    return msghdr
  }

  func put(u8 value: UInt8, for attrtype: CInt) throws {
    try throwingErrno { nla_put_u8(_msg, attrtype, value) }
  }

  func put(u16 value: UInt16, for attrtype: CInt) throws {
    try throwingErrno { nla_put_u16(_msg, attrtype, value) }
  }

  func put(u32 value: UInt32, for attrtype: CInt) throws {
    try throwingErrno { nla_put_u32(_msg, attrtype, value) }
  }

  func put(u64 value: UInt64, for attrtype: CInt) throws {
    try throwingErrno { nla_put_u64(_msg, attrtype, value) }
  }

  func put(data value: [UInt8], for attrtype: CInt) throws {
    _ = try value.withUnsafeBufferPointer { value in
      try throwingErrno {
        nla_put(_msg, attrtype, Int32(value.count), value.baseAddress)
      }
    }
  }

  func put(opaque value: UnsafePointer<some Any>, for attrtype: CInt) throws {
    _ = try withUnsafeBytes(of: value) { value in
      try throwingErrno {
        nla_put(_msg, attrtype, Int32(value.count), value.baseAddress)
      }
    }
  }

  var sequence: UInt32 {
    let hdr = nlmsg_hdr(_msg)!
    return hdr.pointee.nlmsg_seq
  }

  func send(on socket: NLSocket) throws {
    try throwingErrno { nl_send_auto(socket._sk, _msg) }
  }

  deinit {
    nlmsg_free(_msg)
  }
}
