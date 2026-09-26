// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';

import 'package:govee_scene/session_controller.dart';
import 'package:govee_scene/session_model.dart';
import 'package:govee_scene/sync_client.dart';
import 'package:govee_scene/sync_host.dart';
import 'package:govee_scene/sync_protocol.dart';

Uint8List _createTestPackZip(String sessionJson) {
  final archive = Archive();
  final bytes = utf8.encode(sessionJson);
  archive.addFile(ArchiveFile('session.json', bytes.length, bytes));
  final zipBytes = ZipEncoder().encode(archive)!;
  return Uint8List.fromList(zipBytes);
}

void main() async {
  print('Running sync smoke test...');

  const sessionJson = '''
{
  "name": "Smoke Test Pack",
  "scenes": [
    {
      "id": "scene_0",
      "name": "Scene Zero",
      "govee_effect": {"ref": "effect_0"},
      "ambient": null,
      "ambient_volume": 50,
      "spotify": {"uri": "", "volume": 50, "start_time": 0},
      "triggers": [
        {
          "id": "trig_0",
          "name": "Trigger Zero",
          "sound": "",
          "govee_flash": {"ref": "flash_0"}
        }
      ]
    },
    {
      "id": "scene_1",
      "name": "Scene One",
      "govee_effect": {"ref": "effect_1"},
      "ambient": null,
      "ambient_volume": 60,
      "spotify": {"uri": "", "volume": 50, "start_time": 0},
      "triggers": []
    }
  ],
  "audio_manifest": {}
}
''';

  final packJson = jsonDecode(sessionJson) as Map<String, dynamic>;
  final pack = SessionPack.fromJson(packJson, '/dummy/path');
  final zipBytes = _createTestPackZip(sessionJson);
  final loadedPack = LoadedPack(pack: pack, zipBytes: zipBytes);

  // 1. Start SyncHost with in-memory test pack
  final host = SyncHost(loadedPack, 'TestHost');
  final started = await host.start();
  if (!started) {
    stderr.writeln('ERROR: SyncHost failed to start');
    exit(1);
  }
  print('✓ SyncHost started on port $kSyncPort');

  final client = SyncClient(
    deviceId: 'smoke_client_tool',
    deviceName: 'SmokeTestToolClient',
  );

  try {
    final welcomeCompleter = Completer<SyncWelcome>();
    client.welcomeStream.listen((w) {
      if (!welcomeCompleter.isCompleted) {
        welcomeCompleter.complete(w);
      }
    });

    // 2. Connect client to 127.0.0.1
    await client.connect(InternetAddress.loopbackIPv4, port: kSyncPort);
    print('✓ SyncClient connected to 127.0.0.1:$kSyncPort');

    // 3. Check welcome arrives with correct pack ID
    final welcome = await welcomeCompleter.future.timeout(
      const Duration(seconds: 5),
    );
    if (welcome.pack == null || welcome.pack!.id != loadedPack.id) {
      stderr.writeln(
        'ERROR: Welcome pack ID mismatch: expected ${loadedPack.id}, got ${welcome.pack?.id}',
      );
      exit(1);
    }
    print('✓ Welcome message received with pack ID ${welcome.pack!.id}');

    // 4. Download pack and compare SHA-256
    final downloadedBytes = await client.downloadPack(loadedPack.id);
    final downloadedSha = sha256.convert(downloadedBytes).toString();
    if (downloadedSha != loadedPack.id) {
      stderr.writeln(
        'ERROR: Downloaded SHA mismatch: expected ${loadedPack.id}, got $downloadedSha',
      );
      exit(1);
    }
    print('✓ Pack downloaded and SHA-256 verified ($downloadedSha)');

    // 5. Attach controller, send enterScene {index: 1}, verify state snapshot
    final controller = SessionController(pack);
    final stateCompleter = Completer<Map<String, dynamic>>();

    client.stateStream.listen((state) {
      if (state['sceneIndex'] == 1 && !stateCompleter.isCompleted) {
        stateCompleter.complete(state);
      }
    });

    host.attachController(controller);
    print('✓ SessionController attached to host');

    client.sendCommand('enterScene', {'index': 1});

    final receivedState = await stateCompleter.future.timeout(
      const Duration(seconds: 5),
    );
    if (receivedState['sceneIndex'] != 1) {
      stderr.writeln(
        'ERROR: Scene index mismatch: expected 1, got ${receivedState['sceneIndex']}',
      );
      exit(1);
    }
    print('✓ State snapshot received on client with sceneIndex == 1');

    host.detachController();
    controller.dispose();
    print('✓ Smoke test passed successfully!');
  } finally {
    await client.close();
    await host.stop();
  }
}
