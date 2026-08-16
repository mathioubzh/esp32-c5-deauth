import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:universal_ble/universal_ble.dart';

import 'screens/scan_screen.dart';
import 'services/api_server.dart';
import 'services/app_logger.dart';
import 'services/settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final logger = AppLogger.instance;
  await logger.initialize();

  FlutterError.onError = (details) {
    logger.error('Uncaught Flutter error', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stackTrace) {
    logger.error('Uncaught platform error', error, stackTrace);
    return false;
  };

  try {
    await UniversalBle.setLogLevel(BleLogLevel.verbose);
    logger.info('Universal BLE verbose logging enabled');
  } catch (error, stackTrace) {
    logger.warning('Unable to enable Universal BLE verbose logging: $error');
    logger.error('BLE logging setup stack trace', error, stackTrace);
  }

  final settings = Settings();
  final api = ApiServer(settings);
  logger.info('Application UI starting');
  runApp(DeautherApp(settings: settings, api: api));
}

class DeautherApp extends StatelessWidget {
  const DeautherApp({
    super.key,
    required this.settings,
    required this.api,
    this.home = const ScanScreen(),
  });

  final Settings settings;
  final ApiServer api;
  final Widget home;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        Provider.value(value: api),
      ],
      child: MaterialApp(
        title: 'ESP32-C5 Deauther',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(
          colorScheme: ColorScheme.fromSeed(
            seedColor: Colors.tealAccent,
            brightness: Brightness.dark,
          ),
          useMaterial3: true,
        ),
        home: home,
      ),
    );
  }
}
