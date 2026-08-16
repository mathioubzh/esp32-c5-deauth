import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';

import '../services/api_server.dart';
import '../services/device_controller.dart';
import '../services/nus_client.dart';
import 'device_screen.dart';
import 'settings_screen.dart';

class ScanScreen extends StatefulWidget {
  const ScanScreen({super.key, this.autoStart = true});

  /// Disabled by widget tests that run without a native BLE adapter/plugin.
  final bool autoStart;

  @override
  State<ScanScreen> createState() => _ScanScreenState();
}

class _ScanScreenState extends State<ScanScreen> {
  final NusClient _client = NusClient();
  StreamSubscription<List<BleDevice>>? _resultsSub;
  StreamSubscription<AvailabilityState>? _adapterSub;
  List<BleDevice> _results = [];
  bool _scanning = false;
  bool _connecting = false;
  bool _rescanEnabled = true;
  int _seenDeviceCount = 0;
  Timer? _rescanTimer;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (!widget.autoStart) return;
    _adapterSub = UniversalBle.availabilityStream.listen(
      (state) {
        if (state == AvailabilityState.poweredOn &&
            !_scanning &&
            !_connecting &&
            mounted) {
          unawaited(_maybeStartScan());
        }
      },
      onError: (Object error) {
        if (mounted) setState(() => _error = 'Bluetooth error: $error');
      },
    );
    unawaited(_maybeStartScan());
  }

  @override
  void dispose() {
    _rescanTimer?.cancel();
    unawaited(_resultsSub?.cancel());
    unawaited(_adapterSub?.cancel());
    if (widget.autoStart) {
      unawaited(_client.stopScan());
    }
    super.dispose();
  }

  Future<void> _maybeStartScan() async {
    if (_scanning || _connecting) return;
    if (!await _ensurePermissions()) return;
    if (!await _ensureAdapterOn()) return;
    await _startScan();
  }

  Future<bool> _ensurePermissions() async {
    try {
      await UniversalBle.requestPermissions(withAndroidFineLocation: false);
      return true;
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'Bluetooth permissions denied: $error');
      }
      return false;
    }
  }

  Future<bool> _ensureAdapterOn() async {
    AvailabilityState state;
    try {
      state = await UniversalBle.getBluetoothAvailabilityState();
    } catch (error) {
      if (mounted) setState(() => _error = 'Bluetooth unavailable: $error');
      return false;
    }

    if (state == AvailabilityState.poweredOn) return true;

    if (Platform.isAndroid || Platform.isWindows || Platform.isLinux) {
      try {
        await UniversalBle.enableBluetooth();
        // The availability listener starts scanning after the radio reports it
        // is fully powered on.
        return false;
      } catch (_) {}
    }

    if (mounted) {
      final message = switch (state) {
        AvailabilityState.unsupported =>
          'Bluetooth Low Energy is not supported on this computer.',
        AvailabilityState.unauthorized =>
          'Bluetooth access is not authorised for this app.',
        _ => 'Bluetooth is off — enable it and retry.',
      };
      setState(() => _error = message);
    }
    return false;
  }

  Future<void> _startScan() async {
    _rescanTimer?.cancel();
    await _resultsSub?.cancel();
    if (!mounted) return;

    setState(() {
      _error = null;
      _results = [];
      _seenDeviceCount = 0;
      _scanning = true;
    });

    try {
      final stream = await _client.scan();
      if (!mounted) {
        await _client.stopScan();
        return;
      }
      _resultsSub = stream.listen(
        (devices) {
          if (!mounted) return;
          setState(() {
            _results = devices;
            _seenDeviceCount = _client.seenDeviceCount;
          });
          if (devices.length == 1 && !_connecting) {
            unawaited(_connect(devices.first));
          }
        },
        onError: (Object error) {
          if (mounted) setState(() => _error = 'Scan error: $error');
        },
        onDone: _onScanEnded,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _scanning = false;
        _error = 'Scan error: $error';
      });
      _scheduleRescan();
    }
  }

  void _onScanEnded() {
    if (!mounted) return;
    setState(() => _scanning = false);
    _scheduleRescan();
  }

  void _scheduleRescan() {
    if (!_rescanEnabled || _connecting || !mounted) return;
    _rescanTimer?.cancel();
    _rescanTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_connecting && _rescanEnabled) {
        unawaited(_maybeStartScan());
      }
    });
  }

  Future<void> _connect(BleDevice device) async {
    if (_connecting) return;
    _rescanEnabled = false;
    _rescanTimer?.cancel();
    await _client.stopScan();
    if (!mounted) return;

    setState(() {
      _error = null;
      _connecting = true;
      _scanning = false;
    });
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const Center(child: CircularProgressIndicator()),
      ),
    );

    DeviceController? controller;
    ApiServer? api;
    var apiAttached = false;
    var dialogVisible = true;
    try {
      final connection = await _client.connect(device);
      controller = DeviceController(connection);
      if (!mounted) {
        await connection.disconnect();
        return;
      }
      api = context.read<ApiServer>();
      api.attach(controller);
      apiAttached = true;
      Navigator.of(context).pop();
      dialogVisible = false;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DeviceScreen(controller: controller!),
        ),
      );
      api.detach();
      apiAttached = false;
      await controller.conn.disconnect();
    } catch (error) {
      if (!mounted) return;
      if (dialogVisible && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
      setState(() => _error = '$error');
    } finally {
      if (apiAttached) {
        api?.detach();
      }
      controller?.dispose();
      if (mounted) {
        setState(() => _connecting = false);
        _rescanEnabled = true;
        await Future<void>.delayed(const Duration(seconds: 2));
        if (mounted) unawaited(_maybeStartScan());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ESP32-C5 Deauther'),
        actions: [
          IconButton(
            icon: Icon(_scanning ? Icons.stop : Icons.refresh),
            tooltip: _scanning ? 'Stop scan' : 'Scan',
            onPressed: () {
              if (_scanning) {
                _rescanEnabled = false;
                _rescanTimer?.cancel();
                unawaited(_client.stopScan());
              } else {
                _rescanEnabled = true;
                unawaited(_maybeStartScan());
              }
            },
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.menu),
            onSelected: (value) {
              if (value == 'settings') {
                unawaited(
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const SettingsScreen()),
                  ),
                );
              }
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'settings', child: Text('Settings')),
            ],
          ),
        ],
      ),
      body: Column(
        children: [
          if (_scanning) const LinearProgressIndicator(),
          if (_error != null)
            Container(
              width: double.infinity,
              color: Colors.red.shade100,
              padding: const EdgeInsets.all(12),
              child: Text(_error!, style: const TextStyle(color: Colors.red)),
            ),
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _scanning ? 'Scanning…' : 'No controller found',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'BLE devices seen by Windows: $_seenDeviceCount',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                        if (!_scanning && _seenDeviceCount > 0) ...[
                          const SizedBox(height: 8),
                          const Text(
                            'Power-cycle the ESP32-C5 and scan again.',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: _results.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) =>
                        _resultTile(_results[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _resultTile(BleDevice device) {
    final name = (device.name?.isNotEmpty ?? false)
        ? device.name!
        : '(unnamed)';
    return ListTile(
      leading: const Icon(Icons.bluetooth),
      title: Text(name),
      subtitle: Text(
        '${device.deviceId}\n${device.rssi ?? '?'} dBm'
        '${device.isSystemDevice == true ? ' · Windows system device' : ''}',
      ),
      isThreeLine: true,
      onTap: () => unawaited(_connect(device)),
    );
  }
}
