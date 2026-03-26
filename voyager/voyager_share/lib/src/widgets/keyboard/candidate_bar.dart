import 'package:flutter/material.dart';

import '../design_tokens.dart';

class CandidateBar extends StatelessWidget {
  const CandidateBar({
    super.key,
    required this.pinyin,
    required this.candidates,
    required this.onSelect,
  });

  final String pinyin;
  final List<String> candidates;
  final void Function(int index) onSelect;

  static const _bgColor = AppColors.surfaceDim;
  static const _pinyinColor = AppColors.textTertiary;
  static const _candidateColor = AppColors.textPrimary;
  static const _indexColor = AppColors.textMuted;
  static const _dividerColor = AppColors.divider;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: _bgColor,
      child: Row(
        children: [
          // Pinyin display
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            child: Text(
              pinyin,
              style: const TextStyle(
                color: _pinyinColor,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          Container(width: 1, height: 24, color: _dividerColor),
          // Scrollable candidate list
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: candidates.length,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              itemBuilder: (context, index) {
                return GestureDetector(
                  onTap: () => onSelect(index),
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    alignment: Alignment.center,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (index < 9)
                          Text(
                            '${index + 1}',
                            style: const TextStyle(
                              color: _indexColor,
                              fontSize: 10,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (index < 9) const SizedBox(width: 2),
                        Text(
                          candidates[index],
                          style: const TextStyle(
                            color: _candidateColor,
                            fontSize: 18,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
