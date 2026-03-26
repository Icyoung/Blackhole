import 'package:flutter/material.dart';
import 'package:voyager_share/voyager_share.dart';

import '../services/vpn_service.dart';

/// VPN status and control panel.
///
/// Shows a toggle to connect/disconnect VPN, connection status,
/// assigned VPN IP, connection mode (direct/relay), and server IP.
class VpnPanel extends StatelessWidget {
  const VpnPanel({
    super.key,
    required this.vpnService,
    this.onConnect,
    this.onDisconnect,
  });

  final VpnService vpnService;
  final VoidCallback? onConnect;
  final VoidCallback? onDisconnect;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vpnService,
      builder: (context, _) {
        return _buildContent(context);
      },
    );
  }

  Widget _buildContent(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 300),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.border),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 12),
            _buildStatusRow(),
            if (vpnService.isConnected) ...[
              const SizedBox(height: 12),
              _buildConnectionDetails(),
            ],
            if (vpnService.status == VpnStatus.error &&
                vpnService.error != null) ...[
              const SizedBox(height: 12),
              _buildErrorMessage(),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final isActive = vpnService.isActive;
    final isTransitioning = vpnService.status == VpnStatus.connecting ||
        vpnService.status == VpnStatus.disconnecting;

    return Row(
      children: [
        const Icon(Icons.shield_outlined, color: AppColors.accent, size: 18),
        const SizedBox(width: 8),
        const Text(
          'VPN',
          style: TextStyle(
            color: AppColors.accent,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
        const Spacer(),
        if (isTransitioning)
          const Padding(
            padding: EdgeInsets.only(right: 8),
            child: SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 1.5,
                color: AppColors.textMuted,
              ),
            ),
          ),
        SizedBox(
          height: 28,
          child: Opacity(
            opacity: isTransitioning ? 0.5 : 1.0,
            child: Switch(
              value: isActive,
              onChanged: isTransitioning
                  ? null
                  : (value) {
                      if (value) {
                        onConnect?.call();
                      } else {
                        onDisconnect?.call();
                      }
                    },
              activeThumbColor: AppColors.statusGreen,
              activeTrackColor: AppColors.statusGreen.withValues(alpha: 0.3),
              inactiveThumbColor: AppColors.textMuted,
              inactiveTrackColor: AppColors.surfaceVariant,
              trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildStatusRow() {
    final (statusLabel, statusColor) = switch (vpnService.status) {
      VpnStatus.disconnected => ('Disconnected', AppColors.textMuted),
      VpnStatus.connecting => ('Connecting', AppColors.statusYellow),
      VpnStatus.connected => ('Connected', AppColors.statusGreen),
      VpnStatus.disconnecting => ('Disconnecting', AppColors.statusYellow),
      VpnStatus.error => ('Error', AppColors.statusRed),
    };

    return Row(
      children: [
        _StatusDot(
          color: statusColor,
          pulsing: vpnService.status == VpnStatus.connecting ||
              vpnService.status == VpnStatus.disconnecting,
        ),
        const SizedBox(width: 8),
        Text(
          statusLabel,
          style: TextStyle(
            color: statusColor,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (vpnService.isConnected) ...[
          const SizedBox(width: 8),
          _buildModeBadge(),
        ],
      ],
    );
  }

  Widget _buildModeBadge() {
    final (label, color) = switch (vpnService.connectionMode) {
      VpnConnectionMode.direct => ('Direct', AppColors.statusGreen),
      VpnConnectionMode.unknown => ('Unknown', AppColors.textMuted),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
      ),
    );
  }

  Widget _buildConnectionDetails() {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (vpnService.clientIp != null)
            _buildDetailRow('Client IP', vpnService.clientIp!),
          if (vpnService.clientIp != null && vpnService.serverIp != null)
            const SizedBox(height: 6),
          if (vpnService.serverIp != null)
            _buildDetailRow('Server IP', vpnService.serverIp!),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: AppColors.textMuted,
            fontSize: 11,
          ),
        ),
        const Spacer(),
        Text(
          value,
          style: const TextStyle(
            color: AppColors.textPrimary,
            fontSize: 11,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _buildErrorMessage() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.statusRed.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.statusRed.withValues(alpha: 0.2)),
      ),
      child: Text(
        vpnService.error!,
        style: TextStyle(
          color: AppColors.statusRed.withValues(alpha: 0.9),
          fontSize: 11,
        ),
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

/// Animated status dot that optionally pulses for transitional states.
class _StatusDot extends StatefulWidget {
  const _StatusDot({
    required this.color,
    this.pulsing = false,
  });

  final Color color;
  final bool pulsing;

  @override
  State<_StatusDot> createState() => _StatusDotState();
}

class _StatusDotState extends State<_StatusDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _animation = Tween<double>(begin: 0.3, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
    if (widget.pulsing) {
      _controller.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(_StatusDot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulsing && !_controller.isAnimating) {
      _controller.repeat(reverse: true);
    } else if (!widget.pulsing && _controller.isAnimating) {
      _controller.stop();
      _controller.value = 1.0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        final opacity = widget.pulsing ? _animation.value : 1.0;
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: opacity),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.4 * opacity),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}
