String alphabetBucketFor(String? raw) {
  if (raw == null) return '#';
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return '#';
  final first = trimmed[0].toUpperCase();
  final code = first.codeUnitAt(0);
  if (code >= 65 && code <= 90) {
    return first;
  }
  return '#';
}

List<String> sortAlphabetBuckets(Iterable<String> buckets) {
  final list = buckets.toSet().toList();
  list.sort((a, b) {
    if (a == b) return 0;
    if (a == '#') return 1;
    if (b == '#') return -1;
    return a.compareTo(b);
  });
  return list;
}

