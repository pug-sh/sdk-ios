/// The Connect error codes, as error bodies name them.
enum RPCCode: String, CaseIterable, Sendable {
  case canceled
  case unknown
  case invalidArgument = "invalid_argument"
  case deadlineExceeded = "deadline_exceeded"
  case notFound = "not_found"
  case alreadyExists = "already_exists"
  case permissionDenied = "permission_denied"
  case resourceExhausted = "resource_exhausted"
  case failedPrecondition = "failed_precondition"
  case aborted
  case outOfRange = "out_of_range"
  case unimplemented
  case `internal`
  case unavailable
  case dataLoss = "data_loss"
  case unauthenticated

  /// The code for an error body that is not Connect JSON, such as a proxy, CDN or WAF page. As in sdk-web, any other
  /// 4xx is permanent, so that a 413 is not retried forever.
  init(httpStatus: Int) {
    switch httpStatus {
    case 401:
      self = .unauthenticated
    case 403:
      self = .permissionDenied
    case 404:
      self = .unimplemented
    case 408, 429:
      self = .unavailable
    case 400..<500:
      self = .invalidArgument
    default:
      self = .unavailable
    }
  }

  /// Codes a retry cannot fix, sdk-web's `PERMANENT_GRPC_CODES`.
  var isPermanent: Bool {
    switch self {
    case .invalidArgument, .notFound, .alreadyExists, .permissionDenied, .failedPrecondition, .unimplemented,
      .unauthenticated:
      return true
    default:
      return false
    }
  }
}
