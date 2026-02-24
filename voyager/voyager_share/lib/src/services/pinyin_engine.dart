import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../widgets/keyboard/pinyin_valid_syllables.dart';

class PinyinEngine extends ChangeNotifier {
  /// Raw pinyin buffer (e.g., "zhongguo").
  String _buffer = '';

  /// Parsed syllables from the buffer (e.g., ["zhong", "guo"]).
  List<String> _syllables = [];

  /// Remaining unparsed characters after greedy matching.
  String _remainder = '';

  /// Current candidate list.
  List<String> _candidates = [];

  /// Single-character dict: pinyin -> [char1, char2, ...]
  Map<String, List<String>> _charDict = {};

  /// Phrase dict: concatenated pinyin -> [phrase1, phrase2, ...]
  Map<String, List<String>> _phraseDict = {};

  /// Prefix index for predictive suggestions (e.g., "wo" -> "我们").
  final Map<String, List<String>> _prefixIndex = {};
  // Next-char association index by committed Chinese prefix (e.g., "丽" -> ["江", ...]).
  final Map<String, List<String>> _hanPrefixNextIndex = {};
  String _predictionPrefix = '';

  static const int _prefixMaxSyllables = 2;
  static const int _prefixMaxCandidates = 36;
  static const int _hanPrefixMaxChars = 3;
  static const int _hanPrefixMaxCandidates = 12;

  bool _loaded = false;

  String get buffer => _buffer;
  List<String> get syllables => _syllables;
  String get remainder => _remainder;
  List<String> get candidates => _candidates;
  bool get loaded => _loaded;
  bool get hasInput => _buffer.isNotEmpty;
  bool get hasCandidates => _candidates.isNotEmpty;

  /// Display text for the candidate bar: syllable-separated pinyin.
  String get displayPinyin {
    if (_buffer.isEmpty &&
        _predictionPrefix.isNotEmpty &&
        _candidates.isNotEmpty) {
      return _predictionPrefix;
    }
    if (_syllables.isEmpty && _remainder.isEmpty) return _buffer;
    final parts = [..._syllables];
    if (_remainder.isNotEmpty) parts.add(_remainder);
    return parts.join("'");
  }

  /// Load the pinyin dictionary from assets.
  Future<void> loadDict() async {
    if (_loaded) return;
    try {
      final jsonStr = await rootBundle.loadString(
        'packages/voyager_share/assets/pinyin_dict.json',
      );
      final data = json.decode(jsonStr) as Map<String, dynamic>;

      _charDict = {};
      _phraseDict = {};

      for (final entry in data.entries) {
        if (entry.key == '_phrases') {
          final phrases = entry.value as Map<String, dynamic>;
          for (final p in phrases.entries) {
            _phraseDict[p.key] = (p.value as List).cast<String>();
          }
        } else {
          _charDict[entry.key] = (entry.value as List).cast<String>();
        }
      }

      _buildPrefixIndex();
      _buildHanPrefixNextIndex();
      _loaded = true;
      // Refresh candidates in case the user started typing before dict load finished.
      _reparse();
      notifyListeners();
      debugPrint(
        '[PinyinEngine] Dict loaded: ${_charDict.length} syllables, ${_phraseDict.length} phrases',
      );
    } catch (e) {
      debugPrint('[PinyinEngine] Failed to load dict: $e');
    }
  }

  /// Append a character to the buffer.
  void addChar(String c) {
    _predictionPrefix = '';
    _buffer += c.toLowerCase();
    _reparse();
    notifyListeners();
  }

  /// Delete the last character from the buffer.
  void backspace() {
    if (_buffer.isEmpty) return;
    _buffer = _buffer.substring(0, _buffer.length - 1);
    _reparse();
    notifyListeners();
  }

  /// Select a candidate at the given index. Returns the selected text.
  /// If there are remaining syllables, continues composing.
  String? select(int index) {
    if (index < 0 || index >= _candidates.length) return null;

    final selected = _candidates[index];
    final selectedCharCount = selected.runes.length;

    // Selecting contextual next-char suggestions (no active pinyin composition).
    if (_syllables.isEmpty && _remainder.isEmpty && _buffer.isEmpty) {
      _appendPredictionPrefix(selected);
      _updateContextCandidates();
      notifyListeners();
      return selected;
    }

    // Determine how many syllables this selection consumed
    if (selectedCharCount >= _syllables.length) {
      // Selected a phrase that covers all syllables
      _buffer = _remainder;
    } else {
      // Partial selection: keep remaining syllables + remainder
      final remainingSyllables = _syllables.sublist(selectedCharCount);
      _buffer = remainingSyllables.join() + _remainder;
    }

    _reparse();
    if (_buffer.isEmpty && _syllables.isEmpty && _remainder.isEmpty) {
      _appendPredictionPrefix(selected);
      _updateContextCandidates();
    } else {
      _predictionPrefix = '';
    }
    notifyListeners();
    return selected;
  }

  /// Commit the raw buffer text as-is (for non-pinyin passthrough).
  String commitRaw() {
    final text = _buffer;
    _predictionPrefix = '';
    clear();
    return text;
  }

  /// Clear the buffer and candidates.
  void clear() {
    _buffer = '';
    _syllables = [];
    _remainder = '';
    _predictionPrefix = '';
    _candidates = [];
    notifyListeners();
  }

  void clearPredictions() {
    if (_predictionPrefix.isEmpty && _candidates.isEmpty) return;
    _predictionPrefix = '';
    if (_buffer.isEmpty && _syllables.isEmpty && _remainder.isEmpty) {
      _candidates = [];
    }
    notifyListeners();
  }

  /// Greedy longest-match syllable parsing.
  void _reparse() {
    if (_buffer.isEmpty) {
      _syllables = [];
      _remainder = '';
      _candidates = [];
      return;
    }

    _syllables = [];
    var pos = 0;
    final input = _buffer;

    while (pos < input.length) {
      var matched = false;
      // Try longest match first (max syllable length is 6)
      final maxLen = (input.length - pos).clamp(0, 6);
      for (var len = maxLen; len >= 1; len--) {
        final candidate = input.substring(pos, pos + len);
        if (pinyinSyllableSet.contains(candidate)) {
          _syllables.add(candidate);
          pos += len;
          matched = true;
          break;
        }
      }
      if (!matched) {
        // Remaining characters that don't form valid syllables
        _remainder = input.substring(pos);
        _updateCandidates();
        return;
      }
    }

    _remainder = '';
    _updateCandidates();
  }

  void _buildPrefixIndex() {
    _prefixIndex.clear();
    if (_phraseDict.isEmpty) return;
    for (final entry in _phraseDict.entries) {
      final prefixes = _leadingPrefixes(entry.key, _prefixMaxSyllables);
      if (prefixes.isEmpty) {
        continue;
      }
      for (final prefix in prefixes) {
        final bucket = _prefixIndex.putIfAbsent(prefix, () => <String>[]);
        if (bucket.length >= _prefixMaxCandidates) {
          continue;
        }
        for (final phrase in entry.value) {
          if (bucket.length >= _prefixMaxCandidates) {
            break;
          }
          if (!bucket.contains(phrase)) {
            bucket.add(phrase);
          }
        }
      }
    }
  }

  void _buildHanPrefixNextIndex() {
    _hanPrefixNextIndex.clear();
    final counts = <String, Map<String, int>>{};
    for (final phrases in _phraseDict.values) {
      for (final phrase in phrases) {
        final chars = phrase.runes.map((r) => String.fromCharCode(r)).toList();
        if (chars.length < 2) {
          continue;
        }
        final maxPrefix = (chars.length - 1).clamp(1, _hanPrefixMaxChars);
        for (var prefixLen = 1; prefixLen <= maxPrefix; prefixLen++) {
          final prefix = chars.sublist(0, prefixLen).join();
          final nextChar = chars[prefixLen];
          final bucket = counts.putIfAbsent(prefix, () => <String, int>{});
          bucket[nextChar] = (bucket[nextChar] ?? 0) + 1;
        }
      }
    }
    for (final entry in counts.entries) {
      final sorted =
          entry.value.entries.toList()..sort((a, b) {
            final byCount = b.value.compareTo(a.value);
            if (byCount != 0) return byCount;
            return a.key.compareTo(b.key);
          });
      _hanPrefixNextIndex[entry.key] =
          sorted.take(_hanPrefixMaxCandidates).map((e) => e.key).toList();
    }
  }

  void _appendPredictionPrefix(String selected) {
    final merged =
        (_predictionPrefix + selected).runes
            .map((r) => String.fromCharCode(r))
            .toList();
    final start =
        merged.length > _hanPrefixMaxChars
            ? merged.length - _hanPrefixMaxChars
            : 0;
    _predictionPrefix = merged.sublist(start).join();
  }

  void _updateContextCandidates() {
    if (_predictionPrefix.isEmpty) {
      _candidates = [];
      return;
    }
    final runes = _predictionPrefix.runes.toList();
    for (var len = runes.length; len >= 1; len--) {
      final key = String.fromCharCodes(runes.sublist(runes.length - len));
      final matches = _hanPrefixNextIndex[key];
      if (matches != null && matches.isNotEmpty) {
        _candidates = List<String>.from(matches);
        return;
      }
    }
    _candidates = [];
  }

  List<String> _leadingPrefixes(String input, int maxSyllables) {
    final prefixes = <String>[];
    final buffer = StringBuffer();
    var pos = 0;
    var count = 0;
    while (pos < input.length && count < maxSyllables) {
      final len = _matchSyllableLength(input, pos);
      if (len <= 0) {
        break;
      }
      buffer.write(input.substring(pos, pos + len));
      prefixes.add(buffer.toString());
      pos += len;
      count += 1;
    }
    return prefixes;
  }

  int _matchSyllableLength(String input, int start) {
    final remaining = input.length - start;
    final maxLen = remaining.clamp(0, 6);
    for (var len = maxLen; len >= 1; len--) {
      final candidate = input.substring(start, start + len);
      if (pinyinSyllableSet.contains(candidate)) {
        return len;
      }
    }
    return 0;
  }

  /// Update candidate list based on current syllables.
  void _updateCandidates() {
    _candidates = [];
    if (_syllables.isEmpty) return;

    void addUniqueAll(Iterable<String> values) {
      for (final value in values) {
        if (!_candidates.contains(value)) {
          _candidates.add(value);
        }
      }
    }

    // 1. Try full phrase match first
    final fullPinyin = _syllables.join();
    final phraseMatches = _phraseDict[fullPinyin];
    if (phraseMatches != null) {
      addUniqueAll(phraseMatches);
    }

    final firstSyllable = _syllables.first;
    final charMatches = _charDict[firstSyllable];

    // For single-syllable input (e.g. "li"), prioritize single-character candidates.
    if (_syllables.length == 1 && charMatches != null) {
      addUniqueAll(charMatches);
    }

    // 2. Predictive phrase suggestions based on prefix (联想输入)
    if (_remainder.isEmpty &&
        _syllables.length >= 2 &&
        _syllables.length <= _prefixMaxSyllables) {
      final prefixMatches = _prefixIndex[fullPinyin];
      if (prefixMatches != null) {
        addUniqueAll(prefixMatches);
      }
    }

    // 3. Try progressively shorter phrase matches
    if (_syllables.length > 1) {
      for (var len = _syllables.length - 1; len >= 2; len--) {
        final partialPinyin = _syllables.sublist(0, len).join();
        final partial = _phraseDict[partialPinyin];
        if (partial != null) {
          addUniqueAll(partial);
        }
      }
    }

    // 4. Add single-character candidates for the first syllable (fallback for multi-syllable input)
    if (charMatches != null) {
      addUniqueAll(charMatches);
    }

    // Limit to a reasonable number
    if (_candidates.length > 50) {
      _candidates = _candidates.sublist(0, 50);
    }
  }
}
