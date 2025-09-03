import 'package:flutter/material.dart';
import '../../core/auth_repository.dart';
import '../../main.dart';
import '../main/main_scaffold.dart';
import '../../core/download_storage.dart';
import 'package:permission_handler/permission_handler.dart';

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
  String? _error;

  @override
  void dispose() {
    _serverCtrl.dispose();
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    String normalizeBaseUrl(String input) {
      var url = input.trim();
      // Accept full URLs including scheme and port; if no scheme, default to https
      if (!url.startsWith('http://') && !url.startsWith('https://')) {
        url = 'https://$url';
      }
      return url.replaceAll(RegExp(r'/+$'), '');
    }

    bool ok = false;
    try {
      ok = await widget.auth
          .login(
            baseUrl: normalizeBaseUrl(_serverCtrl.text),
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
      // Prompt a folder name once after successful login (simple dialog),
      // and request storage/media permissions on Android for public Music dir.
      try {
        await DownloadStorage.requestStoragePermissions();
        final services = ServicesScope.of(context).services;
        final current = await DownloadStorage.getBaseSubfolder();
        final controller = TextEditingController(text: current);
        final chosen = await showDialog<String>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('Choose download folder name'),
              content: TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Folder (under app documents)'
                ),
              ),
              actions: [
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Skip')),
                FilledButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Save')),
              ],
            );
          },
        );
        if (chosen != null && chosen.trim().isNotEmpty && chosen.trim() != current) {
          await DownloadStorage.setBaseSubfolder(chosen.trim());
        }
      } catch (_) {}

      final services = ServicesScope.of(context).services;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => MainScaffold(downloadsRepo: services.downloads),
        ),
      );
    } else {
      setState(() => _error = 'Login failed. Check server URL and credentials.');
      // Only clear password on failure (keep server & username)
      _passCtrl.clear();
    }
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
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _userCtrl,
                      decoration: const InputDecoration(labelText: 'Username'),
                      validator: (v) =>
                          (v == null || v.trim().isEmpty) ? 'Required' : null,
                    ),
                    const SizedBox(height: 12),
                    TextFormField(
                      controller: _passCtrl,
                      decoration: const InputDecoration(labelText: 'Password'),
                      obscureText: true,
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
                      onPressed: _loading ? null : _submit,
                      child: _loading
                          ? const SizedBox(
                              height: 18,
                              width: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Sign in'),
                    ),
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
