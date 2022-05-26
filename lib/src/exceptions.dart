/// This exception is thrown if the server sends a request with an unexpected
/// status code or missing/invalid headers.
class ProtocolException implements Exception {
  final String message;
  final int code;

  ProtocolException(this.code, this.message);

  String toString() => "ProtocolException: ($code) $message";
}
