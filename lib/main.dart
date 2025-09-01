import 'package:flutter/material.dart';
import 'core/auth_repository.dart';
import 'core/playback_repository.dart';
import 'core/downloads_repository.dart';
import 'ui/login/login_screen.dart';
import 'ui/main/main_scaffold.dart';
import 'package:permission_handler/permission_handler.dart';

/// Simple app-wide service container
class AppServices {
  final AuthRepository auth;
  final PlaybackRepository playback;
  final DownloadsRepository downloads;
  AppServices({
    required this.auth,
    required this.playback,
    required this.downloads,
  });
}

/// Inherited scope to access services anywhere with:
/// `ServicesScope.of(context).services`
class ServicesScope extends InheritedWidget {
  final AppServices services;
  const ServicesScope({
    super.key,
    required this.services,
    required Widget child,
  }) : super(child: child);

  static ServicesScope of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<ServicesScope>();
    assert(scope != null, 'ServicesScope not found in widget tree');
    return scope!;
  }

  @override
  bool updateShouldNotify(covariant ServicesScope oldWidget) =>
      oldWidget.services != services;
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (await Permission.notification.isDenied) {
    await Permission.notification.request();
  }

  // Construct singletons (Auth -> Playback -> Downloads)
  final auth = await AuthRepository.ensure();
  final playback = PlaybackRepository(auth);
  final downloads = DownloadsRepository(auth, playback);
  await downloads.init();

  final services = AppServices(
    auth: auth,
    playback: playback,
    downloads: downloads,
  );

  runApp(ServicesScope(
    services: services,
    child: const AbsApp(),
  ));
}

class AbsApp extends StatefulWidget {
  const AbsApp({super.key});
  @override
  State<AbsApp> createState() => _AbsAppState();
}

class _AbsAppState extends State<AbsApp> {
  late final Future<bool> _sessionFuture;

  @override
  void initState() {
    super.initState();
    _sessionFuture =
        AuthRepository.ensure().then((auth) => auth.hasValidSession());
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ABS Client',
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.indigo,
        brightness: Brightness.light,
      ),
      home: FutureBuilder<bool>(
        future: _sessionFuture,
        builder: (context, snap) {
          if (!snap.hasData) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          final services = ServicesScope.of(context).services;
          return snap.data!
              ? MainScaffold(downloadsRepo: services.downloads)
              : LoginScreen(auth: services.auth);
        },
      ),
    );
  }
}
