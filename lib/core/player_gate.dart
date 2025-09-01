// lib/core/player_gate.dart
import 'package:flutter/material.dart';

/// Ensures the full-screen player (or its bottom sheet) is opened at most once
/// at a time. Use this everywhere you navigate to the player UI to avoid
/// stacking two sheets/screens on top of each other.
class PlayerGate {
  static final PlayerGate I = PlayerGate._();
  PlayerGate._();

  bool _open = false;

  /// Open a full-screen route once (e.g., a dedicated NowPlayingPage).
  Future<void> openOnce(BuildContext context, Widget page) async {
    if (_open) return;
    _open = true;
    try {
      await Navigator.of(context).push(
        PageRouteBuilder(
          opaque: true,
          pageBuilder: (_, __, ___) => page,
        ),
      );
    } finally {
      _open = false;
    }
  }

  /// Open a modal bottom sheet once (e.g., your FullPlayerSheet).
  Future<void> openSheetOnce(
      BuildContext context,
      Widget Function() builder,
      ) async {
    if (_open) return;
    _open = true;
    try {
      await showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => builder(),
      );
    } finally {
      _open = false;
    }
  }
}
