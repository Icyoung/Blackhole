import 'package:flutter/material.dart';

import '../design_tokens.dart';
import 'chrome_tab_pill.dart';

class HeaderChrome extends StatelessWidget {
  const HeaderChrome({
    super.key,
    required this.color,
    required this.activeColor,
    required this.overlayColor,
    required this.onAddSession,
    required this.sessions,
    required this.activeSessionId,
    this.sessionLabelBuilder,
    required this.onSelectSession,
    required this.onCloseSession,
    required this.onReorderSessions,
    this.connectionContent,
    required this.error,
    required this.pairingPending,
    this.pairingTitle = 'Authorizing connection...',
    this.pairingSubtitle =
        'Horizon may resume this device automatically or ask for approval if it is new',
    this.leadingWidget,
    this.trailingWidget,
  });

  final Color color;
  final Color activeColor;
  final Color overlayColor;
  final VoidCallback onAddSession;
  final List<String> sessions;
  final String? activeSessionId;
  final String Function(String sessionId, int index)? sessionLabelBuilder;
  final void Function(String id) onSelectSession;
  final void Function(String id) onCloseSession;
  final void Function(int oldIndex, int newIndex) onReorderSessions;
  final Widget? connectionContent;
  final String? error;
  final bool pairingPending;
  final String pairingTitle;
  final String pairingSubtitle;
  final Widget? leadingWidget;
  final Widget? trailingWidget;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.of(context).padding.top;
    final hasTopContent =
        connectionContent != null || pairingPending || error != null;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasTopContent)
          Container(
            color: color,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(height: topInset),
                if (connectionContent != null) connectionContent!,
                if (pairingPending)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: AppColors.textMuted
                            .withValues(alpha: AppOpacity.light),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                            color: AppColors.textMuted
                                .withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.textMuted,
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
                                    color: AppColors.textMuted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  pairingSubtitle,
                                  style: const TextStyle(
                                    color: AppColors.textTertiary,
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
                        color: AppColors.warning
                            .withValues(alpha: AppOpacity.light),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                            color: AppColors.warning
                                .withValues(alpha: 0.2)),
                      ),
                      child: Row(
                        children: [
                          const Icon(Icons.error_outline,
                              size: 14, color: AppColors.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              error!,
                              style: const TextStyle(
                                  color: AppColors.warning, fontSize: 12),
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
          color: color,
          padding: EdgeInsets.only(top: (hasTopContent ? 0 : topInset) + 6),
          child: Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      if (leadingWidget != null) leadingWidget!,
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
                      _CircleIconButton(
                        icon: Icons.add,
                        onTap: onAddSession,
                      ),
                    ],
                  ),
                ),
              ),
              if (trailingWidget != null) ...[
                trailingWidget!,
                const SizedBox(width: 4),
              ],
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

class _CircleIconButton extends StatefulWidget {
  const _CircleIconButton({required this.icon, required this.onTap});

  final IconData icon;
  final VoidCallback onTap;

  @override
  State<_CircleIconButton> createState() => _CircleIconButtonState();
}

class _CircleIconButtonState extends State<_CircleIconButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    if (_pressed) {
      bg = AppColors.surfaceBright;
    } else if (_hovered) {
      bg = AppColors.surfaceVariant;
    } else {
      bg = Colors.transparent;
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AppDurations.fast,
          width: 24,
          height: 24,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: bg,
            shape: BoxShape.circle,
          ),
          child: Center(child: Icon(widget.icon, color: AppColors.textTertiary, size: 14)),
        ),
      ),
    );
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
