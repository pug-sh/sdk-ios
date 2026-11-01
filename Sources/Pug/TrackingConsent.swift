extension Pug {
  /// The user's choice about tracking. While it is denied, events and identify calls are dropped, and denying it
  /// drops the queued events and forgets the identity stored on the device.
  public enum TrackingConsent: Sendable {
    case granted
    case denied
  }
}
