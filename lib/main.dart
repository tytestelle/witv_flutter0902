import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:coocaa_flutter_focus/coocaa_flutter_focus.dart'; // ← 新增
import 'screens/home_screen.dart';
import 'services/settings_service.dart';
import 'services/log_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 初始化焦点控制器
  FocusController.instance
    ..init()
    ..updateConfig(
      scrollEdgeOffset: 80,
      focusableGroupEdgeMode: FocusableGroupEdgeMode.stop, // 边缘停止，不循环
    );

  await LogService.init();
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);

  FlutterError.onError = (FlutterErrorDetails details) {
    FlutterError.dumpErrorToConsole(details);
    LogService.writeCrashLog(details.exception, details.stack);
  };
  WidgetsBinding.instance.platformDispatcher.onError = (error, stack) {
    LogService.writeCrashLog(error, stack);
    return true;
  };

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => SettingsService(),
      child: MaterialApp(
        title: 'Witv',
        theme: ThemeData.dark(),
        home: const HomeScreen(),
        debugShowCheckedModeBanner: false,
      ),
    );
  }
}
