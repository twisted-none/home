import 'dart:async';

import 'package:app_links/app_links.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'home.dart';
import 'onboarding.dart';
import 'ui.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final links = AppLinks();
  var pushEnabled = false;
  if (const bool.fromEnvironment('ENABLE_PUSH')) {
    try {
      await Firebase.initializeApp();
      pushEnabled = true;
    } on FirebaseException {
      debugPrint(
        'Firebase is unavailable. In-app notifications remain available.',
      );
    }
  }
  runApp(FamilyApp(links: links, pushEnabled: pushEnabled));
}

class FamilyApp extends StatefulWidget {
  const FamilyApp({super.key, required this.links, required this.pushEnabled});

  final AppLinks links;
  final bool pushEnabled;

  @override
  State<FamilyApp> createState() => _FamilyAppState();
}

class _FamilyAppState extends State<FamilyApp> {
  static const storage = FlutterSecureStorage();
  static const sessionKey =
      'session:${String.fromEnvironment('API_BASE_URL', defaultValue: 'debug')}';
  final api = FamilyApi();
  final navigator = GlobalKey<NavigatorState>();
  final messenger = GlobalKey<ScaffoldMessengerState>();
  StreamSubscription<Uri>? links;
  String? pendingCode;
  Json? profile;
  Object? error;
  bool loading = true;

  @override
  void initState() {
    super.initState();
    links = widget.links.uriLinkStream.listen((uri) {
      final code = inviteCode(uri.toString());
      if (code != null && mounted && profile?['family'] == null) {
        setState(() => pendingCode = code);
      }
    }, onError: (Object _) {});
    restore();
  }

  @override
  void dispose() {
    links?.cancel();
    api.close();
    super.dispose();
  }

  Future<void> restore() async {
    setState(() {
      loading = true;
      error = null;
    });
    try {
      api.token = await storage.read(key: sessionKey);
      final restored = api.token == null
          ? null
          : await api.get('/family') as Json;
      if (mounted) setState(() => profile = restored);
    } catch (failure) {
      if (failure is ApiFailure && failure.status == 401) {
        await clearSession();
      } else if (mounted) {
        setState(() => error = failure);
      }
    } finally {
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> authenticate(bool register, Json data) async {
    final result =
        await api.send(
              'POST',
              register ? '/auth/register' : '/auth/login',
              body: data,
            )
            as Json;
    api.token = result['token'] as String;
    try {
      await storage.write(key: sessionKey, value: api.token);
    } catch (_) {
      api.token = null;
      rethrow;
    }
    await restore();
  }

  Future<void> clearSession() async {
    api.token = null;
    if (mounted) {
      navigator.currentState?.popUntil((route) => route.isFirst);
      setState(() => profile = null);
    }
    await storage.delete(key: sessionKey);
  }

  Future<void> signOut() async {
    try {
      await api.send('POST', '/auth/logout', retry: true);
      await clearSession();
    } catch (failure) {
      if (failure is ApiFailure && failure.status == 401) {
        await clearSession();
      } else {
        messenger.currentState?.showSnackBar(
          SnackBar(content: Text('$failure')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = profile;
    return MaterialApp(
      title: 'Домашние дела и покупки',
      navigatorKey: navigator,
      scaffoldMessengerKey: messenger,
      theme: familyTheme(),
      locale: const Locale('ru'),
      supportedLocales: const [Locale('ru')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: loading
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : error != null
          ? Scaffold(
              body: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: ErrorNotice(error: error!, retry: restore),
                ),
              ),
            )
          : current == null
          ? AuthScreen(submit: authenticate, hasInvite: pendingCode != null)
          : current['family'] == null
          ? FamilySetup(
              api: api,
              code: pendingCode,
              signOut: signOut,
              onReady: (value) => setState(() {
                profile = value;
                pendingCode = null;
              }),
            )
          : HomeScreen(
              api: api,
              profile: current,
              pushEnabled: widget.pushEnabled,
              onExpired: clearSession,
              signOut: signOut,
            ),
    );
  }
}
