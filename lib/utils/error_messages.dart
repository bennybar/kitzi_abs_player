// lib/utils/error_messages.dart
import 'dart:async';
import 'dart:io';

/// Turns an exception into something a person can act on.
///
/// UI used to render `e.toString()` straight into the page, so users read
/// things like `Exception: Failed to load book x: 500`. Keep the raw error for
/// the logs; show this to the human.
String humanErrorMessage(Object error) {
  final text = error.toString();

  if (error is SocketException ||
      text.contains('SocketException') ||
      text.contains('Failed host lookup') ||
      text.contains('Connection refused')) {
    return "Can't reach your server. Check your connection, then try again.";
  }
  if (error is TimeoutException || text.contains('TimeoutException')) {
    return 'Your server took too long to respond. Try again.';
  }
  if (error is HandshakeException || text.contains('CERTIFICATE')) {
    return "Couldn't establish a secure connection to your server.";
  }
  if (text.contains('401') ||
      text.contains('403') ||
      text.contains('Unauthorized')) {
    return 'Your session has expired. Sign in again.';
  }
  if (text.contains('404')) {
    return "That item is no longer on the server.";
  }
  if (RegExp(r'\b5\d\d\b').hasMatch(text)) {
    return 'Your server ran into a problem. Try again in a moment.';
  }
  return 'Something went wrong. Pull down to try again.';
}
