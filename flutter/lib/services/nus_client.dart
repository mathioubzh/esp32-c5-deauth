// Nordic UART Service (NUS) BLE client.
//
// Pairs with the firmware's transport_ble.c GATT layout:
//   Service: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E
//   RX char: 6E400002-…   (write / write-no-rsp — host → device)
//   TX char: 6E400003-…   (notify              — device → host)

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:universal_ble/universal_ble.dart';

class NusUuids {
  static const service = '6e400001-b5a3-f393-e0a9-e50e24dcca9e';
  static const rx = '6e400002-b5a3-f393-e0a9-e50e24dcca9e';
  static const tx = '6e400003-b5a3-f393-e0a9-e50e24dcca9e';
}

class NusConnection {
  NusConnection._({
    required this.device,
    required BleCharacteristic rx,
    required this.incoming,
    required this.disconnected,
    required Future<void> Function() doDisconnect,
  }) : _rx = rx,
       _doDisconnect = doDisconnect;

  final BleDevice device;
  final BleCharacteristic _rx;

  /// Stream of UTF-8 decoded notifications from the TX characteristic.
  final Stream<String> incoming;

  /// Resolves when the BLE link drops for any reason.
  final Future<void> disconnected;

  final Future<void> Function() _doDisconnect;
  bool _disconnectCalled = false;

  /// Sends [text] to the device's RX characteristic. The firmware CLI is
  /// line-buffered, so a trailing newline is appended when needed.
  Future<void> send(String text) async {
    if (!await device.isConnected) return;
    if (!text.endsWith('\n')) text = '$text\n';

    final withoutResponse = _rx.properties.contains(
      CharacteristicProperty.writeWithoutResponse,
    );
    try {
      await _rx.write(utf8.encode(text), withResponse: !withoutResponse);
    } catch (_) {
      // The link may have dropped during the write. The disconnected future
      // drives the UI back to the scan screen.
    }
  }

  Future<void> disconnect() async {
    if (_disconnectCalled) return;
    _disconnectCalled = true;
    await _doDisconnect();
  }
}

class NusClient {
  StreamSubscription<BleDevice>? _scanSub;
  StreamController<List<BleDevice>>? _scanController;
  Timer? _scanTimer;
  final Map<String, BleDevice> _scanResults = {};

  /// Streams matching peripherals until [timeout] expires or [stopScan] is
  /// called. Devices are filtered in Dart so name-based discovery still works
  /// when a platform omits advertised service UUIDs from its scan result.
  Future<Stream<List<BleDevice>>> scan({
    Duration timeout = const Duration(seconds: 8),
  }) async {
    await stopScan();

    // Single-subscription streams buffer any discovery events that arrive
    // between startScan() completing and the UI attaching its listener.
    final controller = StreamController<List<BleDevice>>();
    _scanController = controller;
    _scanResults.clear();

    _scanSub = UniversalBle.scanStream.listen(
      (device) {
        if (!_looksLikeDevice(device)) return;
        _scanResults[device.deviceId] = device;
        final results = _scanResults.values.toList()
          ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
        if (!controller.isClosed) controller.add(results);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!controller.isClosed) controller.addError(error, stackTrace);
        unawaited(stopScan());
      },
    );

    try {
      await UniversalBle.startScan(
        platformConfig: Platform.isAndroid
            ? PlatformConfig(
                android: AndroidOptions(
                  requestLocationPermission: false,
                  scanMode: AndroidScanMode.lowLatency,
                  legacy: true,
                ),
              )
            : null,
      );
    } catch (_) {
      await _closeScan(stopPlatform: false);
      rethrow;
    }

    _scanTimer = Timer(timeout, () => unawaited(stopScan()));
    return controller.stream;
  }

  Future<void> stopScan() => _closeScan(stopPlatform: true);

  Future<void> _closeScan({required bool stopPlatform}) async {
    _scanTimer?.cancel();
    _scanTimer = null;

    final subscription = _scanSub;
    final controller = _scanController;
    _scanSub = null;
    _scanController = null;

    if (stopPlatform) {
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
    await subscription?.cancel();
    if (controller != null && !controller.isClosed) await controller.close();
  }

  bool _looksLikeDevice(BleDevice device) {
    if (device.services.any(
      (uuid) => BleUuidParser.compareStrings(uuid, NusUuids.service),
    )) {
      return true;
    }
    final name = device.name?.toLowerCase() ?? '';
    return name.contains('deauther') || name.contains('esp32c5');
  }

  /// Connects, discovers NUS and exposes a bidirectional text channel.
  Future<NusConnection> connect(BleDevice device) async {
    await stopScan();

    if (await device.isConnected) {
      try {
        await device.disconnect(timeout: const Duration(seconds: 3));
      } catch (_) {}
      await _waitForConnection(device, connected: false);
    }

    await device.connect(
      timeout: const Duration(seconds: 12),
      autoConnect: false,
    );

    try {
      // A larger MTU reduces notification fragmentation. Unsupported platforms
      // safely ignore or reject this best-effort request.
      try {
        await device.requestMtu(247);
      } catch (_) {}

      final services = await device.discoverServices();
      final service = services.firstWhere(
        (candidate) =>
            BleUuidParser.compareStrings(candidate.uuid, NusUuids.service),
        orElse: () => throw StateError('NUS service not found on this device'),
      );
      final rx = service.characteristics.firstWhere(
        (candidate) =>
            BleUuidParser.compareStrings(candidate.uuid, NusUuids.rx),
        orElse: () => throw StateError('NUS RX characteristic missing'),
      );
      final tx = service.characteristics.firstWhere(
        (candidate) =>
            BleUuidParser.compareStrings(candidate.uuid, NusUuids.tx),
        orElse: () => throw StateError('NUS TX characteristic missing'),
      );

      final txSubscription =
          tx.properties.contains(CharacteristicProperty.notify)
          ? tx.notifications
          : tx.indications;
      await txSubscription.subscribe();

      final incoming = tx.onValueReceived.map((bytes) {
        try {
          return utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          return String.fromCharCodes(bytes);
        }
      });

      final disconnectedCompleter = Completer<void>();
      late StreamSubscription<bool> stateSub;
      stateSub = device.connectionStream.listen((connected) {
        if (!connected && !disconnectedCompleter.isCompleted) {
          disconnectedCompleter.complete();
          unawaited(stateSub.cancel());
        }
      });

      Future<void> doDisconnect() async {
        try {
          await txSubscription.unsubscribe();
        } catch (_) {}
        try {
          await device.disconnect(timeout: const Duration(seconds: 3));
        } catch (_) {}
        try {
          await _waitForConnection(device, connected: false);
        } catch (_) {}
        await stateSub.cancel();
        if (!disconnectedCompleter.isCompleted) {
          disconnectedCompleter.complete();
        }
      }

      return NusConnection._(
        device: device,
        rx: rx,
        incoming: incoming,
        disconnected: disconnectedCompleter.future,
        doDisconnect: doDisconnect,
      );
    } catch (error, stackTrace) {
      // Do not leave a half-open Windows GATT session when service discovery
      // or notification setup fails.
      try {
        await device.disconnect(timeout: const Duration(seconds: 3));
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  Future<void> _waitForConnection(
    BleDevice device, {
    required bool connected,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    if ((await device.isConnected) == connected) return;
    await device.connectionStream
        .firstWhere((current) => current == connected)
        .timeout(timeout);
  }
}
