import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_web_auth_2/flutter_web_auth_2.dart';
import '../../core/auth_repository.dart';
import '../../main.dart';
import '../main/main_scaffold.dart';
import '../../core/download_storage.dart';
import '../../core/books_repository.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.auth});
  final AuthRepository auth;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _form = GlobalKey<FormState>();
  final _serverCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _loading = false;
  bool _oidcLoading = false;
  String? _error;

  // OIDC / SSO discovery (from the server's /status).
  static const String _oidcRedirectUri = 'audiobookshelf://oauth';
  static const String _oidcScheme = 'audiobookshelf';
  bool _oidcAvailable = false;
  String _oidcButtonText = 'Sign in with SSO';
  Timer? _detectDebounce;
  String? _detectedFor; // baseUrl we last probed

  @override
  void dispose() {
    _detectDebounce?.cancel();
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  static String _normalizeBaseUrl(String input) {
    var url = input.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'https://$url';
    }
    url = url.replaceAll(RegExp(r'/+$'), '');
    try {
      final u = Uri.parse(url);
      final segs = List<String>.from(u.pathSegments);
      while (segs.isNotEmpty &&
          (segs.last.toLowerCase() == 'login' ||
              segs.last.toLowerCase() == 'signin')) {
        segs.removeLast();
      }
      final trimmedPath = segs.join('/');
      final rebuilt = Uri(
        scheme: u.scheme,
        host: u.host,
        port: u.hasPort ? u.port : null,
        path: trimmedPath.isEmpty ? null : '/$trimmedPath',
      ).toString();
      return rebuilt.replaceAll(RegExp(r'/+$'), '');
    } catch (_) {
      return url;
    }
  }

  /// Probe the server (debounced) to see if OIDC/SSO is offered.
  void _onServerChanged(String value) {
    _detectDebounce?.cancel();
    if (value.trim().isEmpty) {
      if (_oidcAvailable) setState(() => _oidcAvailable = false);
      return;
    }
    _detectDebounce = Timer(const Duration(milliseconds: 700), _detectAuth);
  }

  Future<void> _detectAuth() async {
    final base = _normalizeBaseUrl(_serverCtrl.text);
    if (base.isEmpty || base == _detectedFor) return;
    _detectedFor = base;
    try {
      final status = await widget.auth.serverStatus(base);
      final methods = (status['authMethods'] is List)
          ? (status['authMethods'] as List).map((e) => e.toString()).toList()
          : const <String>[];
      final form = status['authFormData'];
      final btn = (form is Map ? form['authOpenIDButtonText'] : null)
          ?.toString();
      if (!mounted) return;
      setState(() {
        _oidcAvailable = methods.contains('openid');
        _oidcButtonText =
            (btn != null && btn.trim().isNotEmpty) ? btn : 'Sign in with SSO';
      });
    } catch (_) {
      // Leave SSO hidden on failure.
    }
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    bool ok = false;
    try {
      ok = await widget.auth
          .login(
            baseUrl: _normalizeBaseUrl(_serverCtrl.text),
            username: _userCtrl.text.trim(),
            password: _passCtrl.text,
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      ok = false;
    }

    if (!mounted) return;
    setState(() => _loading = false);

    if (ok) {
      await _onAuthSuccess();
    } else {
      setState(() => _error = 'Login failed. Check server URL and credentials.');
      // Only clear password on failure (keep server & username)
      _passCtrl.clear();
    }
  }

  /// SSO / OpenID Connect login via the system browser.
  Future<void> _oidcLogin() async {
    final base = _normalizeBaseUrl(_serverCtrl.text);
    if (base.isEmpty) {
      setState(() => _error = 'Enter your server URL first.');
      return;
    }
    setState(() {
      _oidcLoading = true;
      _error = null;
    });
    try {
      final authUrl = await widget.auth
          .openIdBegin(baseUrl: base, redirectUri: _oidcRedirectUri);
      if (authUrl == null) {
        if (!mounted) return;
        setState(() {
          _oidcLoading = false;
          _error =
              'Could not start SSO. Check the server URL and that OIDC is enabled.';
        });
        return;
      }
      final result = await FlutterWebAuth2.authenticate(
        url: authUrl,
        callbackUrlScheme: _oidcScheme,
      );
      final ok =
          await widget.auth.openIdFinish(baseUrl: base, callbackUrl: result);
      if (!mounted) return;
      setState(() => _oidcLoading = false);
      if (ok) {
        await _onAuthSuccess();
      } else {
        setState(() => _error = 'SSO sign-in failed. Please try again.');
      }
    } on PlatformException {
      // User cancelled / dismissed the browser sheet.
      if (mounted) setState(() => _oidcLoading = false);
    } catch (_) {
      if (mounted) {
        setState(() {
          _oidcLoading = false;
          _error = 'SSO sign-in error. Please try again.';
        });
      }
    }
  }

  /// Shared post-login flow (permissions + initial sync + navigate).
  Future<void> _onAuthSuccess() async {
    try {
      await DownloadStorage.requestStoragePermissions();
    } catch (_) {}

    try {
      final syncCompleter = Completer<void>();
      final dialogContext = context;
      await showDialog<void>(
        context: dialogContext,
        barrierDismissible: false,
        builder: (context) {
          Future.microtask(() async {
            final repo = await BooksRepository.create();
            try {
              await repo
                  .syncAllBooksToDb(pageSize: 100)
                  .timeout(const Duration(seconds: 25));
            } catch (_) {}
            if (!syncCompleter.isCompleted) {
              syncCompleter.complete();
            }
            if (context.mounted && Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          });
          return const _InitialLibraryDialog();
        },
      );
      try {
        await syncCompleter.future.timeout(const Duration(seconds: 30));
      } catch (_) {}
      await Future.delayed(const Duration(milliseconds: 300));
    } catch (_) {}

    if (!mounted) return;
    final services = ServicesScope.of(context).services;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (_) => MainScaffold(downloadsRepo: services.downloads),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(title: const Text('Login')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Card(
            elevation: 0,
            color: cs.surfaceContainerHighest,
            margin: const EdgeInsets.all(16),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Form(
                key: _form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                      controller: _serverCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Server URL',
                        hintText: 'https://abs.example.com:443',
                      ),
                      keyboardType: TextInputType.url,
                      onChanged: _onServerChanged,
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(labelText: 'Username'),
                      autofillHints: const [AutofillHints.username],
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passCtrl,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
                      autofillHints: const [AutofillHints.password],
                      onEditingComplete: () {
                        TextInput.finishAutofillContext();
                        _submit();
                      },
                      validator: (v) =>
                          (v == null || v.isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 16),
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(_error!, style: TextStyle(color: cs.error)),
                      ),
                    FilledButton(
                      onPressed: (_loading || _oidcLoading) ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),
                    if (_oidcAvailable) ...[
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          const Expanded(child: Divider()),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 10),
                            child: Text('or',
                                style: TextStyle(color: cs.onSurfaceVariant)),
                          ),
                          const Expanded(child: Divider()),
                        ],
                      ),
                      const SizedBox(height: 14),
                      OutlinedButton.icon(
                        onPressed:
                            (_loading || _oidcLoading) ? null : _oidcLogin,
                        icon: _oidcLoading
                            ? const SizedBox(
                                height: 18,
                                width: 18,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.shield_outlined),
                        label: Text(_oidcButtonText),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _InitialLibraryDialog extends StatelessWidget {
  const _InitialLibraryDialog();

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return AlertDialog(
      contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 16),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(color: cs.primary, strokeWidth: 3),
              ),
              const SizedBox(width: 12),
              Text(
                'Please wait for initial library load',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            'We\'re syncing your books for fast browsing and correct sorting.',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
          ),
        ],
      ),
    );
  }
}
