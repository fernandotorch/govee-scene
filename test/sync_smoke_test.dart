import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  HttpOverrides.global = null;

  test('Local loopback LAN sync smoke test', () async {
    HttpOverrides.global = null;
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
    final host = SyncHost(loadedPack, 'TestHost', port: 0);
    final started = await host.start();
    expect(started, isTrue, reason: 'SyncHost must bind and start successfully');

    final client = SyncClient(
      deviceId: 'smoke_client_1',
      deviceName: 'SmokeTestClient',
    );

    try {
      final welcomeCompleter = Completer<SyncWelcome>();
      client.welcomeStream.listen((w) {
        if (!welcomeCompleter.isCompleted) {
          welcomeCompleter.complete(w);
        }
      });

      // 2. Connect client to 127.0.0.1
      await client.connect(InternetAddress.loopbackIPv4, port: host.actualPort);

      // 3. Check welcome arrives with correct pack ID
      final welcome = await welcomeCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      expect(welcome.pack, isNotNull);
      expect(welcome.pack!.id, equals(loadedPack.id));
      expect(welcome.pack!.name, equals('Smoke Test Pack'));

      // Verify pingInterval is set to 3s on client and server sockets
      expect(client.socket?.pingInterval, equals(const Duration(seconds: 3)));
      expect(host.clientSockets.isNotEmpty, isTrue);
      expect(host.clientSockets.first.pingInterval, equals(const Duration(seconds: 3)));

      // 4. Download pack and compare SHA-256
      final downloadedBytes = await client.downloadPack(loadedPack.id);
      final downloadedSha = sha256.convert(downloadedBytes).toString();
      expect(downloadedSha, equals(loadedPack.id));
      expect(downloadedBytes, equals(loadedPack.zipBytes));

      // 5. Attach controller, test input validation and bad messages
      final controller = SessionController(pack);
      final stateCompleter = Completer<Map<String, dynamic>>();

      client.stateStream.listen((state) {
        if (state['sceneIndex'] == 1 && !stateCompleter.isCompleted) {
          stateCompleter.complete(state);
        }
      });

      host.attachController(controller);

      // Verify host ignores invalid indices and malformed payloads without throwing
      client.sendCommand('enterScene', {'index': -1});
      client.sendCommand('enterScene', {'index': 99});
      client.sendCommand('enterScene', {'index': 'not_an_int'});
      client.sendCommand('fireTrigger', {'sceneIndex': 0, 'index': -1});
      client.sendCommand('fireTrigger', {'sceneIndex': 0, 'index': 99});
      client.sendCommand('fireTrigger', {'sceneIndex': 99, 'index': 0});
      client.socket?.add(jsonEncode({'type': 'command', 'name': 12345}));
      client.socket?.add(jsonEncode({'type': 'command', 'name': 'enterScene', 'args': 'bad_args'}));
      client.socket?.add('not valid json {');
      await Future.delayed(const Duration(milliseconds: 100));
      expect(controller.sceneIndex, equals(0));

      // Valid enterScene works
      client.sendCommand('enterScene', {'index': 1});

      final receivedState = await stateCompleter.future.timeout(
        const Duration(seconds: 5),
      );
      expect(receivedState['sceneIndex'], equals(1));
      expect(controller.sceneIndex, equals(1));

      host.detachController();
      controller.dispose();
    } finally {
      await client.close();
      await host.stop();
    }
  });

  test('RemoteSessionController immediate slider updates and snapshot protection', () async {
    const sessionJson = '''
{
  "name": "Slider Test Pack",
  "scenes": [
    {
      "id": "scene_0",
      "name": "Scene Zero",
      "govee_effect": {"ref": "effect_0"},
      "ambient": null,
      "ambient_volume": 50,
      "spotify": {"uri": "", "volume": 50, "start_time": 0},
      "triggers": []
    }
  ],
  "audio_manifest": {}
}
''';
    final packJson = jsonDecode(sessionJson) as Map<String, dynamic>;
    final pack = SessionPack.fromJson(packJson, '/dummy/path');
    final dummyClient = SyncClient(deviceId: 'test_client');
    final remote = RemoteSessionController(pack: pack, client: dummyClient);

    expect(remote.ambientVolume, equals(50.0));
    expect(remote.triggerVolume, equals(80.0));

    int notifyCount = 0;
    remote.addListener(() {
      notifyCount++;
    });

    // 1. setAmbientVolume sets local field immediately and notifies before sendCommand
    remote.setAmbientVolume(25.0);
    expect(remote.ambientVolume, equals(25.0));
    expect(notifyCount, equals(1));

    // 2. Incoming snapshot from host during 400ms window does not overwrite ambientVolume
    remote.applySnapshot({'ambientVolume': 90.0});
    expect(remote.ambientVolume, equals(25.0));

    // 3. setTriggerVolume sets local field immediately and notifies before sendCommand
    remote.setTriggerVolume(40.0);
    expect(remote.triggerVolume, equals(40.0));
    expect(notifyCount, equals(3)); // 1 from setAmbient, 1 from applySnapshot, 1 from setTrigger

    // 4. Incoming snapshot during 400ms window does not overwrite triggerVolume
    remote.applySnapshot({'triggerVolume': 95.0});
    expect(remote.triggerVolume, equals(40.0));

    // 5. After 400ms passes, snapshot overwrites volumes
    await Future.delayed(const Duration(milliseconds: 450));
    remote.applySnapshot({'ambientVolume': 70.0, 'triggerVolume': 65.0});
    expect(remote.ambientVolume, equals(70.0));
    expect(remote.triggerVolume, equals(65.0));

    remote.dispose();
    await dummyClient.close();
  });

  test('SessionController real trigger timing, duration update, and endTrigger', () async {
    const sessionJson = '''
{
  "name": "Trigger Timing Test Pack",
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
          "sound": "sound_0",
          "govee_flash": null
        },
        {
          "id": "trig_flash",
          "name": "Flash Only",
          "sound": "",
          "govee_flash": {"ref": "flash_0"}
        }
      ]
    }
  ],
  "audio_manifest": {
    "sound_0": {
      "file": "sound_0.mp3",
      "duration_ms": 5000
    }
  }
}
''';
    final packJson = jsonDecode(sessionJson) as Map<String, dynamic>;
    final pack = SessionPack.fromJson(packJson, '/dummy/path');
    final controller = SessionController(pack);

    final events = <SessionEvent>[];
    controller.events.listen(events.add);

    // Flash-only trigger emits playId = -1
    controller.fireTrigger(1);
    await pumpEventQueue();
    expect(events.last, isA<TriggerFired>());
    final flashEvent = events.last as TriggerFired;
    expect(flashEvent.playId, equals(-1));
    expect(flashEvent.toJson()['playId'], equals(-1));
    expect(TriggerFired.fromJson(flashEvent.toJson()).playId, equals(-1));

    // 1. Fire a trigger whose manifest duration is 5000 ms, then call updateTriggerDuration(playId, 800ms).
    // It must be gone after about 900 ms.
    controller.fireTrigger(0);
    await pumpEventQueue();
    expect(controller.activeTriggers.containsKey(0), isTrue);
    final active = controller.activeTriggers[0]!;
    expect(active.duration, equals(const Duration(milliseconds: 5000)));
    final playId1 = active.playId;
    expect(playId1, isPositive);
    expect(events.last, isA<TriggerFired>());
    expect((events.last as TriggerFired).playId, equals(playId1));

    controller.updateTriggerDuration(playId1, const Duration(milliseconds: 800));
    expect(controller.activeTriggers.containsKey(0), isTrue);
    expect(controller.activeTriggers[0]!.duration, equals(const Duration(milliseconds: 800)));

    // Still present after 400ms
    await Future.delayed(const Duration(milliseconds: 400));
    expect(controller.activeTriggers.containsKey(0), isTrue);

    // Gone after about 900ms total
    await Future.delayed(const Duration(milliseconds: 550));
    expect(controller.activeTriggers.containsKey(0), isFalse);

    // 2. Fire again and call endTrigger(playId). It must be gone immediately.
    controller.fireTrigger(0);
    expect(controller.activeTriggers.containsKey(0), isTrue);
    final playId2 = controller.activeTriggers[0]!.playId;
    expect(playId2, isNot(equals(playId1)));

    controller.endTrigger(playId2);
    expect(controller.activeTriggers.containsKey(0), isFalse);

    // 3. Calling endTrigger with an old playId after the same index has been re-fired
    // must NOT remove the new one.
    controller.fireTrigger(0);
    expect(controller.activeTriggers.containsKey(0), isTrue);
    final oldPlayId = controller.activeTriggers[0]!.playId;

    controller.fireTrigger(0);
    expect(controller.activeTriggers.containsKey(0), isTrue);
    final newPlayId = controller.activeTriggers[0]!.playId;
    expect(newPlayId, isNot(equals(oldPlayId)));

    // Calling endTrigger with oldPlayId must NOT remove the new one
    controller.endTrigger(oldPlayId);
    expect(controller.activeTriggers.containsKey(0), isTrue);
    expect(controller.activeTriggers[0]!.playId, equals(newPlayId));

    // Calling endTrigger with newPlayId removes it
    controller.endTrigger(newPlayId);
    expect(controller.activeTriggers.containsKey(0), isFalse);

    controller.dispose();
  });
}
