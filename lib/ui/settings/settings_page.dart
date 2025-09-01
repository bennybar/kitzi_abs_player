import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _wifiOnlyKey = 'downloads_wifi_only';
  bool _wifiOnly = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() => _wifiOnly = prefs.getBool(_wifiOnlyKey) ?? true);
  }

  Future<void> _save(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_wifiOnlyKey, v);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          SwitchListTile(
            title: const Text('Wi-Fi only downloads'),
            subtitle: const Text('If off, uses Wi-Fi + Cellular'),
            value: _wifiOnly,
            onChanged: (v) async {
              setState(() => _wifiOnly = v);
              await _save(v);
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Downloads will use ${v ? 'Wi-Fi only' : 'Wi-Fi + Cellular'}')),
                );
              }
            },
          ),
          const Divider(),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Log out'),
            onTap: () => Navigator.of(context).pushNamed('/logout'), // wire to your logout flow
          ),
        ],
      ),
    );
  }
}
