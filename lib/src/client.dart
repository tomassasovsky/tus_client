import 'dart:async';
import 'dart:io';
import 'dart:math' show min;
import 'dart:typed_data' show Uint8List, BytesBuilder;
import 'package:tus_client_dart/src/tus_client_base.dart';

import 'exceptions.dart';
import 'package:http/http.dart' as http;

/// This class is used for creating or resuming uploads.
class TusClient extends TusClientBase {
  TusClient(
    super.file, {
    super.store,
    super.maxChunkSize = 512 * 1024,
  }) {
    _fingerprint = generateFingerprint() ?? "";
  }

  /// Override this method to use a custom Client
  http.Client getHttpClient() => http.Client();

  /// Create a new [upload] throwing [ProtocolException] on server error
  Future<void> createUpload() async {
    try {
      _fileSize = await file.length();

      final client = getHttpClient();
      final createHeaders = Map<String, String>.from(headers ?? {})
        ..addAll({
          "Tus-Resumable": tusVersion,
          "Upload-Metadata": _uploadMetadata ?? "",
          "Upload-Length": "$_fileSize",
        });

      final _url = url;

      if (_url == null) {
        throw ProtocolException('Error in request, URL is incorrect');
      }

      final response = await client.post(_url, headers: createHeaders);

      if (!(response.statusCode >= 200 && response.statusCode < 300) &&
          response.statusCode != 404) {
        throw ProtocolException(
            "Unexpected Error while creating upload", response.statusCode);
      }

      String urlStr = response.headers["location"] ?? "";
      if (urlStr.isEmpty) {
        throw ProtocolException(
            "missing upload Uri in response for creating upload");
      }

      _uploadUrl = _parseUrl(urlStr);
      store?.set(_fingerprint, _uploadUrl as Uri);
    } on FileSystemException {
      throw Exception('Cannot find file to upload');
    }
  }

  Future<bool> isResumable() async {
    try {
      _fileSize = await file.length();
      _pauseUpload = false;

      if (!resumingEnabled) {
        return false;
      }

      _uploadUrl = await store?.get(_fingerprint);

      if (_uploadUrl == null) {
        return false;
      }
      return true;
    } on FileSystemException {
      throw Exception('Cannot find file to upload');
    } catch (e) {
      return false;
    }
  }

  /// Start or resume an upload in chunks of [maxChunkSize] throwing
  /// [ProtocolException] on server error
  Future<void> upload({
    Function(double, Duration)? onProgress,
    Function(TusClient)? onStart,
    Function()? onComplete,
    required Uri uri,
    Map<String, String>? metadata = const {},
    Map<String, String>? headers = const {},
  }) async {
    setUploadData(uri, headers, metadata);

    final isResumamble = await isResumable();

    if (!isResumamble) {
      await createUpload();
    }

    // get offset from server
    _offset = await _getOffset();

    // Save the filesize as an int in a variable to avoid having to call
    int totalBytes = _fileSize as int;

    // We start a stopwatch to calculate the upload speed
    final uploadStopwatch = Stopwatch()..start();

    // start upload
    final client = getHttpClient();

    if (onStart != null) {
      onStart(this);
    }

    while (!_pauseUpload && _offset < totalBytes) {
      if (!File(file.path).existsSync()) {
        throw Exception("Cannot find file ${file.path.split('/').last}");
      }
      final uploadHeaders = Map<String, String>.from(headers ?? {})
        ..addAll({
          "Tus-Resumable": tusVersion,
          "Upload-Offset": "$_offset",
          "Content-Type": "application/offset+octet-stream"
        });
      final request = http.Request("PATCH", _uploadUrl as Uri)
        ..headers.addAll(uploadHeaders)
        ..bodyBytes = await _getData();
      _response = await client.send(request);

      if (_response != null) {
        _response?.stream.listen(
          (newBytes) {},
          onDone: () {
            if (onProgress != null && !_pauseUpload) {
              // Total byte sent
              final totalSent = _offset + maxChunkSize;

              // The total upload speed in bytes/ms
              final uploadSpeed =
                  totalSent / uploadStopwatch.elapsedMilliseconds;

              // The data that hasn't been sent yet
              final remainData = totalBytes - totalSent;

              // The time remaining to finish the upload
              final estimate = Duration(
                milliseconds: (remainData / uploadSpeed).round(),
              );

              final progress = totalSent / totalBytes * 100;
              onProgress((progress).clamp(0, 100), estimate);
            }
          },
        );

        // check if correctly uploaded
        if (!(_response!.statusCode >= 200 && _response!.statusCode < 300)) {
          throw ProtocolException(
            "Error while uploadingfile",
            _response!.statusCode,
          );
        }

        int? serverOffset = _parseOffset(_response!.headers["upload-offset"]);
        if (serverOffset == null) {
          throw ProtocolException(
              "Response to PATCH request contains no or invalid Upload-Offset header");
        }
        if (_offset != serverOffset) {
          throw ProtocolException(
              "Response contains different Upload-Offset value ($serverOffset) than expected ($_offset)");
        }

        if (_offset == totalBytes && !_pauseUpload) {
          this.onCompleteUpload();
          if (onComplete != null) {
            onComplete();
          }
        }
      } else {
        throw ProtocolException("Error getting Response from server");
      }
    }
  }

  /// Pause the current upload
  Future<bool> pauseUpload() async {
    try {
      _pauseUpload = true;
      await _response?.stream.timeout(Duration.zero);
      return true;
    } catch (e) {
      throw Exception("Error pausing upload");
    }
  }

  Future<bool> cancelUpload() async {
    try {
      await pauseUpload();
      await store?.remove(_fingerprint);
      return true;
    } catch (_) {
      throw Exception("Error cancelling upload");
    }
  }

  /// Actions to be performed after a successful upload
  Future<void> onCompleteUpload() async {
    await store?.remove(_fingerprint);
  }

  void setUploadData(
    Uri url,
    Map<String, String>? headers,
    Map<String, String>? metadata,
  ) {
    this.url = url;
    this.headers = headers;
    this.metadata = metadata;
    _uploadMetadata = generateMetadata();
  }

  /// Get offset from server throwing [ProtocolException] on error
  Future<int> _getOffset() async {
    final client = getHttpClient();

    final offsetHeaders = Map<String, String>.from(headers ?? {})
      ..addAll({
        "Tus-Resumable": tusVersion,
      });
    final response =
        await client.head(_uploadUrl as Uri, headers: offsetHeaders);

    if (!(response.statusCode >= 200 && response.statusCode < 300)) {
      throw ProtocolException(
        "Unexpected error while resuming upload",
        response.statusCode,
      );
    }

    int? serverOffset = _parseOffset(response.headers["upload-offset"]);
    if (serverOffset == null) {
      throw ProtocolException(
          "missing upload offset in response for resuming upload");
    }
    return serverOffset;
  }

  /// Get data from file to upload

  Future<Uint8List> _getData() async {
    int start = _offset;
    int end = _offset + maxChunkSize;
    end = end > (_fileSize ?? 0) ? _fileSize ?? 0 : end;

    final result = BytesBuilder();
    await for (final chunk in file.openRead(start, end)) {
      result.add(chunk);
    }

    final bytesRead = min(maxChunkSize, result.length);
    _offset = _offset + bytesRead;

    return result.takeBytes();
  }

  int? _parseOffset(String? offset) {
    if (offset == null || offset.isEmpty) {
      return null;
    }
    if (offset.contains(",")) {
      offset = offset.substring(0, offset.indexOf(","));
    }
    return int.tryParse(offset);
  }

  Uri _parseUrl(String urlStr) {
    if (urlStr.contains(",")) {
      urlStr = urlStr.substring(0, urlStr.indexOf(","));
    }
    Uri uploadUrl = Uri.parse(urlStr);
    if (uploadUrl.host.isEmpty) {
      uploadUrl = uploadUrl.replace(host: url?.host, port: url?.port);
    }
    if (uploadUrl.scheme.isEmpty) {
      uploadUrl = uploadUrl.replace(scheme: url?.scheme);
    }
    return uploadUrl;
  }

  http.StreamedResponse? _response;

  int? _fileSize;

  String _fingerprint = "";

  String? _uploadMetadata;

  Uri? _uploadUrl;

  int _offset = 0;

  bool _pauseUpload = false;

  /// The URI on the server for the file
  Uri? get uploadUrl => _uploadUrl;

  /// The fingerprint of the file being uploaded
  String get fingerprint => _fingerprint;

  /// The 'Upload-Metadata' header sent to server
  String get uploadMetadata => _uploadMetadata ?? "";
}
