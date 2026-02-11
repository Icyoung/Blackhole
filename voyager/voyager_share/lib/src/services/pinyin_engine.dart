import 'dart:convert';

import 'package:characters/characters.dart';
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

  static const int _prefixMaxSyllables = 2;
  static const int _prefixMaxCandidates = 36;

  bool _loaded = false;

  String get buffer => _buffer;
  List<String> get syllables => _syllables;
  String get remainder => _remainder;
  List<String> get candidates => _candidates;
  bool get loaded => _loaded;
  bool get hasInput => _buffer.isNotEmpty;

  /// Display text for the candidate bar: syllable-separated pinyin.
  String get displayPinyin {
    if (_syllables.isEmpty && _remainder.isEmpty) return _buffer;
    final parts = [..._syllables];
    if (_remainder.isNotEmpty) parts.add(_remainder);
    return parts.join("'");
  }

  /// Load the pinyin dictionary from assets.
  Future<void> loadDict() async {
    if (_loaded) return;
    try {
      final jsonStr = await rootBundle.loadString('packages/voyager_share/assets/pinyin_dict.json');
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
      _loaded = true;
      // Refresh candidates in case the user started typing before dict load finished.
      _reparse();
      notifyListeners();
      debugPrint('[PinyinEngine] Dict loaded: ${_charDict.length} syllables, ${_phraseDict.length} phrases');
    } catch (e) {
      debugPrint('[PinyinEngine] Failed to load dict: $e');
    }
  }

  /// Append a character to the buffer.
  void addChar(String c) {
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
    final selectedCharCount = selected.characters.length;

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
    notifyListeners();
    return selected;
  }

  /// Commit the raw buffer text as-is (for non-pinyin passthrough).
  String commitRaw() {
    final text = _buffer;
    clear();
    return text;
  }

  /// Clear the buffer and candidates.
  void clear() {
    _buffer = '';
    _syllables = [];
    _remainder = '';
    _candidates = [];
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

    // 1. Try full phrase match first
    final fullPinyin = _syllables.join();
    final phraseMatches = _phraseDict[fullPinyin];
    if (phraseMatches != null) {
      _candidates.addAll(phraseMatches);
    }

    // 2. Predictive phrase suggestions based on prefix (联想输入)
    if (_remainder.isEmpty && _syllables.length <= _prefixMaxSyllables) {
      final prefixMatches = _prefixIndex[fullPinyin];
      if (prefixMatches != null) {
        for (final p in prefixMatches) {
          if (!_candidates.contains(p)) {
            _candidates.add(p);
          }
        }
      }
    }

    // 3. Try progressively shorter phrase matches
    if (_syllables.length > 1) {
      for (var len = _syllables.length - 1; len >= 2; len--) {
        final partialPinyin = _syllables.sublist(0, len).join();
        final partial = _phraseDict[partialPinyin];
        if (partial != null) {
          for (final p in partial) {
            if (!_candidates.contains(p)) {
              _candidates.add(p);
            }
          }
        }
      }
    }

    // 4. Add single-character candidates for the first syllable
    final firstSyllable = _syllables.first;
    final charMatches = _charDict[firstSyllable];
    if (charMatches != null) {
      for (final c in charMatches) {
        if (!_candidates.contains(c)) {
          _candidates.add(c);
        }
      }
    }

    // Limit to a reasonable number
    if (_candidates.length > 50) {
      _candidates = _candidates.sublist(0, 50);
    }
  }
}
