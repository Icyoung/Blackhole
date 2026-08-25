import 'dart:async';

import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../common/focusable_tap_region.dart';
import '../common/tv_focus_scope.dart';
import '../design_tokens.dart';

class TvSessionItem {
  const TvSessionItem({
    required this.id,
    required this.label,
    this.active = false,
  });

  final String id;
  final String label;
  final bool active;
}

class TvVoyagerShell extends StatelessWidget {
  const TvVoyagerShell({
    super.key,
    required this.title,
    required this.subtitle,
    required this.connected,
    required this.sessions,
    required this.terminal,
    required this.ctrl,
    required this.alt,
    required this.meta,
    required this.onToggleConnection,
    required this.onOpenGroups,
    required this.onOpenSettings,
    required this.onAddSession,
    required this.onSelectSession,
    required this.onCloseSession,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    required this.onToggleMeta,
    required this.onKey,
    required this.onPaste,
    required this.onCopy,
    required this.onSend,
    required this.onScrollToBottom,
    this.pairingPending = false,
    this.error,
    this.commandInput,
    this.keyboard,
    this.showKeyboardTools = true,
  });

  final String title;
  final String subtitle;
  final bool connected;
  final bool pairingPending;
  final String? error;
  final List<TvSessionItem> sessions;
  final Widget terminal;
  final Widget? commandInput;
  final Widget? keyboard;
  final bool showKeyboardTools;
  final bool ctrl;
  final bool alt;
  final bool meta;
  final VoidCallback onToggleConnection;
  final VoidCallback onOpenGroups;
  final VoidCallback onOpenSettings;
  final VoidCallback onAddSession;
  final void Function(String id) onSelectSession;
  final void Function(String id) onCloseSession;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback onToggleMeta;
  final void Function(TerminalKey key) onKey;
  final Future<void> Function() onPaste;
  final Future<void> Function() onCopy;
  final void Function(String data) onSend;
  final VoidCallback onScrollToBottom;

  @override
  Widget build(BuildContext context) {
    return TvFocusScope(
      child: ColoredBox(
        color: _TvColors.background,
        child: SafeArea(
          minimum: const EdgeInsets.fromLTRB(48, 32, 48, 40),
          child: Column(
            children: [
              _TvTopBar(
                title: title,
                subtitle: subtitle,
                connected: connected,
                pairingPending: pairingPending,
                error: error,
                onToggleConnection: onToggleConnection,
                onOpenGroups: onOpenGroups,
                onOpenSettings: onOpenSettings,
              ),
              const SizedBox(height: 28),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _TvSessionRail(
                      sessions: sessions,
                      onSelectSession: onSelectSession,
                      onCloseSession: onCloseSession,
                      onAddSession: onAddSession,
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(
                            child: ExcludeFocus(
                              child: _TvTerminalStage(child: terminal),
                            ),
                          ),
                          if (commandInput != null) ...[
                            const SizedBox(height: 12),
                            commandInput!,
                          ],
                          if (showKeyboardTools) ...[
                            const SizedBox(height: 22),
                            _TvActionDock(
                              connected: connected,
                              ctrl: ctrl,
                              alt: alt,
                              meta: meta,
                              onToggleCtrl: onToggleCtrl,
                              onToggleAlt: onToggleAlt,
                              onToggleMeta: onToggleMeta,
                              onKey: onKey,
                              onPaste: onPaste,
                              onCopy: onCopy,
                              onSend: onSend,
                              onScrollToBottom: onScrollToBottom,
                            ),
                          ],
                          if (keyboard != null) ...[
                            const SizedBox(height: 12),
                            keyboard!,
                          ],
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TvTopBar extends StatelessWidget {
  const _TvTopBar({
    required this.title,
    required this.subtitle,
    required this.connected,
    required this.pairingPending,
    required this.onToggleConnection,
    required this.onOpenGroups,
    required this.onOpenSettings,
    this.error,
  });

  final String title;
  final String subtitle;
  final bool connected;
  final bool pairingPending;
  final String? error;
  final VoidCallback onToggleConnection;
  final VoidCallback onOpenGroups;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final statusText =
        pairingPending
            ? 'Waiting for authorization'
            : error != null
            ? error!
            : subtitle;
    final statusColor =
        error != null
            ? AppColors.error
            : connected
            ? AppColors.success
            : AppColors.textMuted;

    return Row(
      children: [
        _TvIconButton(
          icon: Icons.folder_open_rounded,
          label: 'Groups',
          onTap: onOpenGroups,
        ),
        const SizedBox(width: 20),
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: statusColor,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: statusColor.withValues(alpha: 0.28),
                blurRadius: 14,
              ),
            ],
          ),
        ),
        const SizedBox(width: 18),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: _TvColors.textPrimary,
                  fontSize: 30,
                  height: 1.05,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                statusText,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: statusColor,
                  fontSize: 15,
                  height: 1.1,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 28),
        _TvTextButton(
          label: connected ? 'Disconnect' : 'Connect',
          icon:
              connected
                  ? Icons.power_settings_new_rounded
                  : Icons.play_arrow_rounded,
          onTap: onToggleConnection,
          emphasized: !connected,
        ),
        const SizedBox(width: 14),
        _TvIconButton(
          icon: Icons.settings_outlined,
          label: 'Settings',
          onTap: onOpenSettings,
        ),
      ],
    );
  }
}

class _TvSessionRail extends StatelessWidget {
  const _TvSessionRail({
    required this.sessions,
    required this.onSelectSession,
    required this.onCloseSession,
    required this.onAddSession,
  });

  final List<TvSessionItem> sessions;
  final void Function(String id) onSelectSession;
  final void Function(String id) onCloseSession;
  final VoidCallback onAddSession;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 232,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Padding(
            padding: EdgeInsets.only(left: 4, bottom: 12),
            child: Text(
              'SESSIONS',
              style: TextStyle(
                color: _TvColors.textMuted,
                fontSize: 13,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              physics: const BouncingScrollPhysics(),
              itemCount: sessions.length,
              separatorBuilder: (_, _) => const SizedBox(height: 10),
              itemBuilder: (context, index) {
                final session = sessions[index];
                return _TvSessionTile(
                  index: index,
                  session: session,
                  onSelect: () => onSelectSession(session.id),
                  onClose: () => onCloseSession(session.id),
                );
              },
            ),
          ),
          const SizedBox(height: 14),
          _TvTextButton(
            label: 'New Session',
            icon: Icons.add_rounded,
            onTap: onAddSession,
            fullWidth: true,
          ),
        ],
      ),
    );
  }
}

class _TvSessionTile extends StatelessWidget {
  const _TvSessionTile({
    required this.index,
    required this.session,
    required this.onSelect,
    required this.onClose,
  });

  final int index;
  final TvSessionItem session;
  final VoidCallback onSelect;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return FocusableTapRegion(
      onTap: onSelect,
      semanticLabel: session.label,
      builder: (context, focused, hovered, pressed) {
        final selected = session.active;
        final active = focused || hovered || pressed;
        final bg =
            selected
                ? _TvColors.panelBright
                : active
                ? _TvColors.panel
                : Colors.transparent;

        return AnimatedScale(
          duration: AppDurations.fast,
          scale: focused ? 1.035 : 1,
          alignment: Alignment.centerLeft,
          child: AnimatedContainer(
            duration: AppDurations.normal,
            height: 72,
            padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color:
                    focused
                        ? _TvColors.focus
                        : selected
                        ? _TvColors.stroke
                        : Colors.transparent,
                width: focused ? 2 : 1,
              ),
            ),
            child: Row(
              children: [
                Text(
                  '${index + 1}'.padLeft(2, '0'),
                  style: TextStyle(
                    color: selected ? _TvColors.textPrimary : _TvColors.textDim,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    session.label,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color:
                          selected
                              ? _TvColors.textPrimary
                              : _TvColors.textSecondary,
                      fontSize: 18,
                      height: 1.05,
                      fontWeight: selected ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                ),
                if (selected)
                  _TvMiniIconButton(
                    icon: Icons.close_rounded,
                    label: 'Close ${session.label}',
                    onTap: onClose,
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _TvTerminalStage extends StatelessWidget {
  const _TvTerminalStage({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _TvColors.terminal,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _TvColors.stroke),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.24),
            blurRadius: 28,
            offset: const Offset(0, 16),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: child,
    );
  }
}

class _TvActionDock extends StatelessWidget {
  const _TvActionDock({
    required this.connected,
    required this.ctrl,
    required this.alt,
    required this.meta,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    required this.onToggleMeta,
    required this.onKey,
    required this.onPaste,
    required this.onCopy,
    required this.onSend,
    required this.onScrollToBottom,
  });

  final bool connected;
  final bool ctrl;
  final bool alt;
  final bool meta;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback onToggleMeta;
  final void Function(TerminalKey key) onKey;
  final Future<void> Function() onPaste;
  final Future<void> Function() onCopy;
  final void Function(String data) onSend;
  final VoidCallback onScrollToBottom;

  @override
  Widget build(BuildContext context) {
    final actions = [
      _TvDockAction(label: 'CTRL', active: ctrl, onTap: onToggleCtrl),
      _TvDockAction(label: 'ALT', active: alt, onTap: onToggleAlt),
      _TvDockAction(label: 'META', active: meta, onTap: onToggleMeta),
      _TvDockAction(
        label: 'TAB',
        onTap: connected ? () => onKey(TerminalKey.tab) : null,
      ),
      _TvDockAction(
        label: 'ESC',
        onTap: connected ? () => onKey(TerminalKey.escape) : null,
      ),
      _TvDockAction(
        icon: Icons.keyboard_arrow_up_rounded,
        label: 'UP',
        onTap: connected ? () => onKey(TerminalKey.arrowUp) : null,
      ),
      _TvDockAction(
        icon: Icons.keyboard_arrow_down_rounded,
        label: 'DOWN',
        onTap: connected ? () => onKey(TerminalKey.arrowDown) : null,
      ),
      _TvDockAction(
        icon: Icons.keyboard_arrow_left_rounded,
        label: 'LEFT',
        onTap: connected ? () => onKey(TerminalKey.arrowLeft) : null,
      ),
      _TvDockAction(
        icon: Icons.keyboard_arrow_right_rounded,
        label: 'RIGHT',
        onTap: connected ? () => onKey(TerminalKey.arrowRight) : null,
      ),
      _TvDockAction(
        icon: Icons.keyboard_return_rounded,
        label: 'ENTER',
        onTap: connected ? () => onSend('\r') : null,
      ),
      _TvDockAction(
        icon: Icons.vertical_align_bottom_rounded,
        label: 'BOTTOM',
        onTap: onScrollToBottom,
      ),
      _TvDockAction(
        label: 'PASTE',
        onTap: connected ? () => unawaited(onPaste()) : null,
      ),
      _TvDockAction(label: 'COPY', onTap: () => unawaited(onCopy())),
    ];

    return Container(
      height: 92,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: _TvColors.panel,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _TvColors.stroke),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        physics: const BouncingScrollPhysics(),
        itemCount: actions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, index) => actions[index],
      ),
    );
  }
}

class _TvDockAction extends StatelessWidget {
  const _TvDockAction({
    required this.label,
    this.icon,
    this.active = false,
    this.onTap,
  });

  final String label;
  final IconData? icon;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return _TvButtonFrame(
      onTap: onTap,
      semanticLabel: label,
      active: active,
      minWidth: 76,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null)
            Icon(icon, color: _TvColors.textPrimary, size: 22)
          else
            Text(
              label,
              style: const TextStyle(
                color: _TvColors.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w900,
              ),
            ),
          if (icon != null) ...[
            const SizedBox(height: 3),
            Text(
              label,
              style: const TextStyle(
                color: _TvColors.textDim,
                fontSize: 10,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _TvTextButton extends StatelessWidget {
  const _TvTextButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.emphasized = false,
    this.fullWidth = false,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final bool emphasized;
  final bool fullWidth;

  @override
  Widget build(BuildContext context) {
    final button = _TvButtonFrame(
      onTap: onTap,
      semanticLabel: label,
      active: emphasized,
      minWidth: fullWidth ? 0 : 148,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: fullWidth ? MainAxisSize.max : MainAxisSize.min,
        children: [
          Icon(icon, color: _TvColors.textPrimary, size: 22),
          const SizedBox(width: 10),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _TvColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );

    if (fullWidth) {
      return SizedBox(width: double.infinity, child: button);
    }

    return button;
  }
}

class _TvIconButton extends StatelessWidget {
  const _TvIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return _TvButtonFrame(
      onTap: onTap,
      semanticLabel: label,
      minWidth: 58,
      child: Icon(icon, color: _TvColors.textPrimary, size: 25),
    );
  }
}

class _TvMiniIconButton extends StatelessWidget {
  const _TvMiniIconButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FocusableTapRegion(
      onTap: onTap,
      semanticLabel: label,
      builder: (context, focused, hovered, pressed) {
        final active = focused || hovered || pressed;
        return AnimatedScale(
          duration: AppDurations.fast,
          scale: focused ? 1.16 : 1,
          child: Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: active ? _TvColors.focus : _TvColors.panel,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: _TvColors.textPrimary, size: 18),
          ),
        );
      },
    );
  }
}

class _TvButtonFrame extends StatelessWidget {
  const _TvButtonFrame({
    required this.child,
    required this.semanticLabel,
    this.onTap,
    this.active = false,
    this.minWidth = 72,
  });

  final Widget child;
  final String semanticLabel;
  final VoidCallback? onTap;
  final bool active;
  final double minWidth;

  @override
  Widget build(BuildContext context) {
    return FocusableTapRegion(
      onTap: onTap,
      semanticLabel: semanticLabel,
      builder: (context, focused, hovered, pressed) {
        final enabled = onTap != null;
        final highlighted = active || focused || hovered || pressed;
        final bg =
            highlighted
                ? focused
                    ? _TvColors.focus
                    : _TvColors.panelBright
                : _TvColors.button;

        return AnimatedScale(
          duration: AppDurations.fast,
          scale: focused ? 1.08 : 1,
          child: AnimatedOpacity(
            duration: AppDurations.fast,
            opacity: enabled ? 1 : 0.42,
            child: AnimatedContainer(
              duration: AppDurations.normal,
              constraints: BoxConstraints(minWidth: minWidth),
              height: 58,
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: BoxDecoration(
                color: bg,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: focused ? _TvColors.textPrimary : _TvColors.stroke,
                  width: focused ? 2 : 1,
                ),
              ),
              child: Center(child: child),
            ),
          ),
        );
      },
    );
  }
}

class _TvColors {
  const _TvColors._();

  static const background = Color(0xFF0C0F14);
  static const panel = Color(0xFF161B22);
  static const panelBright = Color(0xFF222936);
  static const button = Color(0xFF11161D);
  static const terminal = Colors.black;
  static const stroke = Color(0xFF2B3441);
  static const focus = Color(0xFF4D82FF);
  static const textPrimary = Color(0xFFF8FAFC);
  static const textSecondary = Color(0xFFC9D2DF);
  static const textMuted = Color(0xFF718096);
  static const textDim = Color(0xFF94A3B8);
}
