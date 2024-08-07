import 'dart:io';

import 'package:cross_file/cross_file.dart' show XFile;
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:tus_client_dart/tus_client_dart.dart';
import 'package:url_launcher/url_launcher.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'TUS Client Upload Demo',
      theme: ThemeData(
        primarySwatch: Colors.teal,
      ),
      home: UploadPage(),
    );
  }
}

class UploadPage extends StatefulWidget {
  @override
  _UploadPageState createState() => _UploadPageState();
}

class _UploadPageState extends State<UploadPage> {
  double _progress = 0;
  Duration _estimate = Duration();
  XFile? _file;
  TusClient? _client;
  Uri? _fileUrl;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('TUS Client Upload Demo'),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            SizedBox(height: 12),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              child: Text(
                "This demo uses TUS client to upload a file",
                style: TextStyle(fontSize: 18),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: Card(
                color: Colors.teal,
                child: InkWell(
                  onTap: () async {
                    if (!await ensurePermissions()) {
                      return;
                    }

                    _file = await _getXFile();
                    setState(() {
                      _progress = 0;
                      _fileUrl = null;
                    });
                  },
                  child: Container(
                    padding: EdgeInsets.all(20),
                    child: Column(
                      children: <Widget>[
                        Icon(Icons.cloud_upload, color: Colors.white, size: 60),
                        Text(
                          "Upload a file",
                          style: TextStyle(fontSize: 25, color: Colors.white),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _file == null
                          ? null
                          : () async {
                              final tempDir = await getTemporaryDirectory();
                              final tempDirectory = Directory(
                                  '${tempDir.path}/${_file?.name}_uploads');
                              if (!tempDirectory.existsSync()) {
                                tempDirectory.createSync(recursive: true);
                              }

                              // Create a client
                              print("Create a client");
                              _client = TusClient(
                                _file!,
                                store: TusFileStore(tempDirectory),
                                maxChunkSize: 512 * 1024 * 10,
                              );

                              print("Starting upload");
                              await _client!.upload(
                                onStart:
                                    (TusClient client, Duration? estimation) {
                                  print(estimation);
                                },
                                onComplete: () async {
                                  print("Completed!");
                                  tempDirectory.deleteSync(recursive: true);
                                  setState(() => _fileUrl = _client!.uploadUrl);
                                },
                                onProgress: (progress, estimate) {
                                  print("Progress: $progress");
                                  print('Estimate: $estimate');
                                  setState(() {
                                    _progress = progress;
                                    _estimate = estimate;
                                  });
                                },
                                uri: Uri.parse(
                                    "https://tusd.tusdemo.net/files/"),
                                metadata: {
                                  'testMetaData': 'testMetaData',
                                  'testMetaData2': 'testMetaData2',
                                },
                                headers: {
                                  'testHeaders': 'testHeaders',
                                  'testHeaders2': 'testHeaders2',
                                },
                                measureUploadSpeed: true,
                              );
                            },
                      child: Text("Upload"),
                    ),
                  ),
                  SizedBox(width: 8),
                  Expanded(
                    child: ElevatedButton(
                      onPressed: _progress == 0
                          ? null
                          : () async {
                              _client!.pauseUpload();
                            },
                      child: Text("Pause"),
                    ),
                  ),
                ],
              ),
            ),
            Stack(
              children: <Widget>[
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(1),
                  color: Colors.grey,
                  width: double.infinity,
                  child: Text(" "),
                ),
                FractionallySizedBox(
                  widthFactor: _progress / 100,
                  child: Container(
                    margin: const EdgeInsets.all(8),
                    padding: const EdgeInsets.all(1),
                    color: Colors.green,
                    child: Text(" "),
                  ),
                ),
                Container(
                  margin: const EdgeInsets.all(8),
                  padding: const EdgeInsets.all(1),
                  width: double.infinity,
                  child: Text(
                      "Progress: ${_progress.toStringAsFixed(1)}%, estimated time: ${_printDuration(_estimate)}"),
                ),
              ],
            ),
            if (_progress > 0)
              ElevatedButton(
                onPressed: () async {
                  final result = await _client!.cancelUpload();

                  if (result) {
                    setState(() {
                      _progress = 0;
                      _estimate = Duration();
                    });
                  }
                },
                child: Text("Cancel"),
              ),
            GestureDetector(
              onTap: _progress != 100
                  ? null
                  : () async {
                      await launchUrl(_fileUrl!);
                    },
              child: Container(
                color: _progress == 100 ? Colors.green : Colors.grey,
                padding: const EdgeInsets.all(8.0),
                margin: const EdgeInsets.all(8.0),
                child:
                    Text(_progress == 100 ? "Link to view:\n $_fileUrl" : "-"),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _printDuration(Duration duration) {
    String twoDigits(int n) => n.toString().padLeft(2, '0');
    final twoDigitMinutes = twoDigits(duration.inMinutes.remainder(60));
    final twoDigitSeconds = twoDigits(duration.inSeconds.remainder(60));
    return '$twoDigitMinutes:$twoDigitSeconds';
  }

  /// Copy file to temporary directory before uploading
  Future<XFile?> _getXFile() async {
    if (!await ensurePermissions()) {
      return null;
    }

    final result = await FilePicker.platform.pickFiles();

    if (result != null) {
      final chosenFile = result.files.first;
      if (chosenFile.path != null) {
        // Android, iOS, Desktop
        return XFile(chosenFile.path!);
      } else {
        // Web
        return XFile.fromData(
          chosenFile.bytes!,
          name: chosenFile.name,
        );
      }
    }

    return null;
  }

  Future<bool> ensurePermissions() async {
    var enableStorage = true;

    if (Platform.isAndroid) {
      final devicePlugin = DeviceInfoPlugin();
      final androidDeviceInfo = await devicePlugin.androidInfo;
      _androidSdkVersion = androidDeviceInfo.version.sdkInt;
      enableStorage = _androidSdkVersion < 33;
    }

    final storage = enableStorage
        ? await Permission.storage.status
        : PermissionStatus.granted;
    final photos = Platform.isIOS
        ? await Permission.photos.status
        : PermissionStatus.granted;

    return storage.isGranted && photos.isGranted;
  }

  int _androidSdkVersion = 0;
}
