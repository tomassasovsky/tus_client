/// This exception is thrown if the server sends a request with an unexpected
/// status code or missing/invalid headers.
class ProtocolException implements Exception {
  final String message;
  final int? code;

  ProtocolException(this.message, [this.code]);

  String toString() => "ProtocolException: ($code) $message";
}
