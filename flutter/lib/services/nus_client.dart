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

import 'app_logger.dart';

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
  final AppLogger _logger = AppLogger.instance;
  StreamSubscription<BleDevice>? _scanSub;
  StreamController<List<BleDevice>>? _scanController;
  Timer? _scanTimer;
  final Map<String, BleDevice> _scanResults = {};
  final Set<String> _seenDeviceIds = {};
  final Map<String, String> _advertisementSignatures = {};

  /// Number of distinct BLE peripherals reported by the operating system in
  /// the current scan, including devices that do not look like the controller.
  int get seenDeviceCount => _seenDeviceIds.length;

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
    _seenDeviceIds.clear();
    _advertisementSignatures.clear();
    _logger.info('BLE scan requested; timeout=${timeout.inSeconds}s');

    void addDevice(BleDevice device) {
      final firstSighting = _seenDeviceIds.add(device.deviceId);
      final signature = _advertisementSignature(device);
      if (firstSighting || _advertisementSignatures[device.deviceId] != signature) {
        _advertisementSignatures[device.deviceId] = signature;
        _logger.info('BLE advertisement: ${_describeDevice(device)}');
      }
      if (looksLikeController(device) ||
          (Platform.isWindows && _hasNoUsefulName(device))) {
        _scanResults[device.deviceId] = device;
      } else if (!firstSighting) {
        return;
      }

      final results = _scanResults.values.toList()
        ..sort((a, b) => (b.rssi ?? -999).compareTo(a.rssi ?? -999));
      if (!controller.isClosed) controller.add(results);
    }

    _scanSub = UniversalBle.scanStream.listen(
      addDevice,
      onError: (Object error, StackTrace stackTrace) {
        _logger.error('BLE scan stream failed', error, stackTrace);
        if (!controller.isClosed) controller.addError(error, stackTrace);
        unawaited(stopScan());
      },
    );

    try {
      // On Windows, a peripheral that is already connected through a previous
      // session or another application is omitted from advertisement scan
      // results. Universal BLE exposes those devices through this separate
      // system-device query.
      if (Platform.isWindows) {
        try {
          final systemDevices = await UniversalBle.getSystemDevices(
            withServices: const [NusUuids.service],
          );
          _logger.info(
            'Windows NUS system-device query returned '
            '${systemDevices.length} device(s)',
          );
          for (final device in systemDevices) {
            addDevice(device);
          }
        } catch (error, stackTrace) {
          _logger.error(
            'Windows NUS system-device query failed',
            error,
            stackTrace,
          );
          // A normal advertisement scan can still discover the controller.
        }
      }

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
      _logger.info('Platform BLE scan started');
    } catch (error, stackTrace) {
      _logger.error('Unable to start platform BLE scan', error, stackTrace);
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
    final hadActiveScan = subscription != null || controller != null;
    _scanSub = null;
    _scanController = null;

    if (stopPlatform) {
      try {
        await UniversalBle.stopScan();
      } catch (_) {}
    }
    await subscription?.cancel();
    if (controller != null && !controller.isClosed) await controller.close();
    if (hadActiveScan) {
      _logger.info(
        'BLE scan stopped; seen=${_seenDeviceIds.length}, '
        'candidates=${_scanResults.length}',
      );
    }
  }

  /// Whether the advertisement contains the expected NUS UUID or controller
  /// name. Windows sometimes reports the same advertisement without either,
  /// so unnamed devices are also shown as manual diagnostic candidates there.
  bool looksLikeController(BleDevice device) {
    if (device.services.any(
      (uuid) => BleUuidParser.compareStrings(uuid, NusUuids.service),
    )) {
      return true;
    }
    final name = device.name?.toLowerCase() ?? '';
    return name.contains('deauther') || name.contains('esp32c5');
  }

  bool _hasNoUsefulName(BleDevice device) {
    final name = device.name?.trim().toLowerCase() ?? '';
    return name.isEmpty || name == 'unknown' || name == 'appareil inconnu';
  }

  /// Connects, discovers NUS and exposes a bidirectional text channel.
  Future<NusConnection> connect(BleDevice device) async {
    await stopScan();

    _logger.info('Connection attempt: ${_describeDevice(device)}');

    final alreadyConnected = await device.isConnected;
    _logger.info('Initial connected state: $alreadyConnected');
    if (alreadyConnected) {
      try {
        _logger.info('Disconnecting stale GATT session');
        await device.disconnect(timeout: const Duration(seconds: 3));
      } catch (error, stackTrace) {
        _logger.error('Stale-session disconnect failed', error, stackTrace);
      }
      await _waitForConnection(device, connected: false);
    }

    _logger.info('Calling BLE connect (timeout=12s, autoConnect=false)');
    await device.connect(
      timeout: const Duration(seconds: 12),
      autoConnect: false,
    );
    _logger.info('BLE connect completed');

    try {
      // A larger MTU reduces notification fragmentation. Unsupported platforms
      // safely ignore or reject this best-effort request.
      try {
        final mtu = await device.requestMtu(247);
        _logger.info('Effective MTU/PDU request result: $mtu');
      } catch (error) {
        _logger.warning('MTU request was not available: $error');
      }

      final services = await device.discoverServices();
      _logger.info(
        'GATT discovery returned ${services.length} service(s):\n'
        '${_describeServices(services)}',
      );
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
      _logger.info('Subscribed to NUS TX notifications/indications');

      final incoming = tx.onValueReceived.map((bytes) {
        _logger.info('NUS RX ${bytes.length} byte(s): ${_hex(bytes)}');
        try {
          return utf8.decode(bytes, allowMalformed: true);
        } catch (_) {
          return String.fromCharCodes(bytes);
        }
      });

      final disconnectedCompleter = Completer<void>();
      late StreamSubscription<bool> stateSub;
      stateSub = device.connectionStream.listen((connected) {
        _logger.info('BLE connection state changed: connected=$connected');
        if (!connected && !disconnectedCompleter.isCompleted) {
          disconnectedCompleter.complete();
          unawaited(stateSub.cancel());
        }
      });

      Future<void> doDisconnect() async {
        _logger.info('Disconnect requested by application');
        try {
          await txSubscription.unsubscribe();
        } catch (error) {
          _logger.warning('NUS unsubscribe failed: $error');
        }
        try {
          await device.disconnect(timeout: const Duration(seconds: 3));
        } catch (error) {
          _logger.warning('BLE disconnect failed: $error');
        }
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
      _logger.error('Connection or GATT discovery failed', error, stackTrace);
      // Do not leave a half-open Windows GATT session when service discovery
      // or notification setup fails.
      try {
        await device.disconnect(timeout: const Duration(seconds: 3));
      } catch (_) {}
      Error.throwWithStackTrace(error, stackTrace);
    }
  }

  String _advertisementSignature(BleDevice device) {
    return <String>[
      '${device.name}',
      '${device.rawName}',
      '${device.paired}',
      '${device.isSystemDevice}',
      device.services.join(','),
      device.manufacturerDataList
          .map((data) => '${data.companyIdRadix16}:${data.payloadRadix16}')
          .join(','),
      device.serviceData.entries
          .map((entry) => '${entry.key}:${_hex(entry.value)}')
          .join(','),
    ].join('|');
  }

  String _describeDevice(BleDevice device) {
    final manufacturerData = device.manufacturerDataList.isEmpty
        ? 'none'
        : device.manufacturerDataList
              .map(
                (data) =>
                    'company=0x${data.companyIdRadix16},payload=${data.payloadRadix16}',
              )
              .join('; ');
    final serviceData = device.serviceData.isEmpty
        ? 'none'
        : device.serviceData.entries
              .map((entry) => '${entry.key}=${_hex(entry.value)}')
              .join('; ');
    return 'id=${device.deviceId}, name=${device.name ?? '<null>'}, '
        'rawName=${device.rawName ?? '<null>'}, rssi=${device.rssi}, '
        'paired=${device.paired}, system=${device.isSystemDevice}, '
        'timestamp=${device.timestamp}, services=${device.services}, '
        'manufacturer={$manufacturerData}, serviceData={$serviceData}';
  }

  String _describeServices(List<BleService> services) {
    if (services.isEmpty) return '  <no services>';
    return services.map((service) {
      final characteristics = service.characteristics.isEmpty
          ? '    <no characteristics>'
          : service.characteristics
                .map(
                  (characteristic) =>
                      '    characteristic=${characteristic.uuid} '
                      'properties=${characteristic.properties.map((p) => p.name).toList()}',
                )
                .join('\n');
      return '  service=${service.uuid}\n$characteristics';
    }).join('\n');
  }

  String _hex(Iterable<int> bytes) => bytes
      .map((byte) => byte.toRadixString(16).padLeft(2, '0'))
      .join();

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
