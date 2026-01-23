import 'package:flutter/material.dart';

import 'chrome_tab_button.dart';
import 'chrome_tab_pill.dart';

class HeaderChrome extends StatelessWidget {
  const HeaderChrome({
    super.key,
    required this.hidden,
    required this.color,
    required this.activeColor,
    required this.overlayColor,
    required this.onToggle,
    required this.onAddSession,
    required this.sessions,
    required this.activeSessionId,
    this.sessionLabelBuilder,
    required this.onSelectSession,
    required this.onCloseSession,
    required this.onReorderSessions,
    required this.connectionContent,
    required this.error,
    required this.pairingPending,
    this.pairingTitle = 'Waiting for host approval...',
    this.pairingSubtitle = 'Please check the Horizon app on your computer',
  });

  final bool hidden;
  final Color color;
  final Color activeColor;
  final Color overlayColor;
  final VoidCallback onToggle;
  final VoidCallback onAddSession;
  final List<String> sessions;
  final String? activeSessionId;
  final String Function(String sessionId, int index)? sessionLabelBuilder;
  final void Function(String id) onSelectSession;
  final void Function(String id) onCloseSession;
  final void Function(int oldIndex, int newIndex) onReorderSessions;
  final Widget connectionContent;
  final String? error;
  final bool pairingPending;
  final String pairingTitle;
  final String pairingSubtitle;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final hasMultipleSessions = sessions.length > 1;
    final showTabs = !hidden || hasMultipleSessions;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!hidden)
          Container(
            color: color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: topInset),
                connectionContent,
                if (pairingPending)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF4B7AA6)
                            .withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: const Color(0xFF4B7AA6)
                                .withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Color(0xFF4B7AA6),
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  pairingTitle,
                                  style: const TextStyle(
                                    color: Color(0xFF4B7AA6),
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  pairingSubtitle,
                                  style: const TextStyle(
                                    color: Color(0xFF9AA6B2),
                                    fontSize: 11,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (error != null && !pairingPending)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5C5C)
                            .withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                            color: const Color(0xFFFF5C5C)
                                .withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              size: 14, color: Color(0xFFFF5C5C)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              error!,
                              style: const TextStyle(
                                  color: Color(0xFFFF5C5C), fontSize: 12),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Container(
          color: showTabs ? color : Colors.transparent,
          padding: EdgeInsets.only(top: hidden ? topInset : 0, bottom: 2),
          child: Row(
            children: [
              if (showTabs)
                Expanded(
                  child: SizedBox(
                    height: 36,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        Expanded(
                          child: ReorderableListView.builder(
                            scrollDirection: Axis.horizontal,
                            buildDefaultDragHandles: false,
                            proxyDecorator: (child, index, animation) {
                              return Material(
                                color: Colors.transparent,
                                elevation: 4,
                                shadowColor: Colors.black54,
                                child: child,
                              );
                            },
                            onReorder: onReorderSessions,
                            itemCount: sessions.length,
                            itemBuilder: (context, index) {
                              final sessionId = sessions[index];
                              return ReorderableDragStartListener(
                                key: ValueKey(sessionId),
                                index: index,
                                child: ChromeTabPill(
                                  label: _labelForSession(sessionId, index),
                                  active: sessionId == activeSessionId,
                                  onTap: () => onSelectSession(sessionId),
                                  onClose: () => onCloseSession(sessionId),
                                  color: activeColor,
                                  overlayColor: overlayColor,
                                  width: _tabWidthForCount(
                                    MediaQuery.of(context).size.width,
                                    sessions.length,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                        ChromeTabButton(
                          icon: Icons.add,
                          onTap: onAddSession,
                          color: activeColor,
                          overlayColor: overlayColor,
                          inverted: true,
                        ),
                      ],
                    ),
                  ),
                )
              else
                const Spacer(),
              ChromeTabButton(
                icon:
                    hidden ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_up,
                onTap: onToggle,
                color: activeColor,
                overlayColor: overlayColor,
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _labelForSession(String sessionId, int index) {
    final label = sessionLabelBuilder?.call(sessionId, index);
    if (label == null || label.trim().isEmpty) {
      return 'TERM ${index + 1}';
    }
    return label;
  }
}

double _tabWidthForCount(double screenWidth, int count) {
  if (count <= 0) {
    return 120;
  }
  final maxTabsWidth = screenWidth - 140;
  final width = maxTabsWidth / count;
  return width.clamp(80, 150).toDouble();
}
