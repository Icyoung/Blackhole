import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../models/terminal_group.dart';
import '../services/group_store.dart';
import 'common/status_dot.dart';
import 'design_tokens.dart';

class GroupDrawer extends StatefulWidget {
  const GroupDrawer({
    super.key,
    required this.manager,
    required this.activeSessionId,
    required this.onSelectSession,
    required this.onCloseSession,
    this.onAddSession,
    this.title = 'Groups',
    this.showGroupCount = true,
    this.groupLabelBuilder,
    this.sessionLabelBuilder,
    this.embedded = false,
  });

  final GroupStore manager;
  final String? activeSessionId;
  final void Function(String sessionId) onSelectSession;
  final void Function(String sessionId) onCloseSession;
  final void Function(String groupId)? onAddSession;
  final String title;
  final bool showGroupCount;
  final String Function(TerminalGroup group, int count)? groupLabelBuilder;
  final String Function(String sessionId, int index)? sessionLabelBuilder;
  final bool embedded;

  @override
  State<GroupDrawer> createState() => _GroupDrawerState();
}

class _GroupDrawerState extends State<GroupDrawer> {
  final Set<String> _collapsedGroupIds = {};
  String? _editingGroupId;
  String? _editingSessionId;
  String? _hoveredGroupId;
  String? _hoveredSessionId;
  String _searchQuery = '';
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();

  static bool get _isMobile =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  @override
  void dispose() {
    _editController.dispose();
    _editFocusNode.dispose();
    super.dispose();
  }

  void _startEditingGroup(String groupId, String currentName) {
    setState(() {
      _editingGroupId = groupId;
      _editingSessionId = null;
      _editController.text = currentName;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editFocusNode.requestFocus();
      _editController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _editController.text.length,
      );
    });
  }

  void _startEditingSession(String sessionId, String currentName) {
    setState(() {
      _editingSessionId = sessionId;
      _editingGroupId = null;
      _editController.text = currentName;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _editFocusNode.requestFocus();
      _editController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _editController.text.length,
      );
    });
  }

  void _submitGroupEdit(String groupId) {
    final trimmed = _editController.text.trim();
    if (trimmed.isNotEmpty) {
      widget.manager.renameGroup(groupId, trimmed);
    }
    setState(() => _editingGroupId = null);
  }

  void _submitSessionEdit(String sessionId) {
    final trimmed = _editController.text.trim();
    widget.manager.renameSession(sessionId, trimmed);
    setState(() => _editingSessionId = null);
  }

  void _cancelEdit() {
    setState(() {
      _editingGroupId = null;
      _editingSessionId = null;
    });
  }

  void _selectSession(String groupId, String sessionId) {
    widget.manager.setActiveGroup(groupId);
    widget.onSelectSession(sessionId);
    if (!widget.embedded) {
      Navigator.of(context).maybePop();
    }
  }

  void _toggleCollapse(String groupId) {
    setState(() {
      if (_collapsedGroupIds.contains(groupId)) {
        _collapsedGroupIds.remove(groupId);
      } else {
        _collapsedGroupIds.add(groupId);
      }
    });
  }

  List<TerminalGroup> _filteredGroups() {
    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) return widget.manager.groups;
    return widget.manager.groups.where((g) {
      if (g.name.toLowerCase().contains(query)) return true;
      for (final sid in g.sessionIds) {
        final name = widget.manager.getSessionName(sid, 0).toLowerCase();
        if (name.contains(query)) return true;
      }
      return false;
    }).toList();
  }

  // Horizon-style hover reveal animation
  Widget _hoverReveal({required bool show, required Widget child}) {
    return AnimatedSwitcher(
      duration: AppDurations.normal,
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axis: Axis.horizontal,
            axisAlignment: -1,
            child: child,
          ),
        );
      },
      child: show
          ? KeyedSubtree(key: const ValueKey('show'), child: child)
          : const SizedBox.shrink(),
    );
  }

  @override
  Widget build(BuildContext context) {
    final groups = _filteredGroups();

    final content = SafeArea(
      child: Column(
        children: [
          // Header with search + new group button
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: TextField(
                      style: const TextStyle(
                        color: AppColors.textPrimary,
                        fontSize: 12,
                        height: 1.0,
                      ),
                      decoration: InputDecoration(
                        hintText: 'Search',
                        hintStyle: const TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 12,
                        ),
                        prefixIcon: const Icon(
                          Icons.search_rounded,
                          size: 16,
                          color: AppColors.textMuted,
                        ),
                        prefixIconConstraints: const BoxConstraints(
                          minWidth: 32,
                          minHeight: 32,
                        ),
                        filled: true,
                        fillColor: AppColors.background,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 8),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide.none,
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10),
                          borderSide: BorderSide(
                              color: AppColors.border),
                        ),
                      ),
                      onChanged: (v) => setState(() => _searchQuery = v),
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                Tooltip(
                  message: 'New group',
                  child: InkWell(
                    onTap: () => widget.manager.createGroup(),
                    borderRadius: BorderRadius.circular(10),
                    child: Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: AppColors.background,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: AppColors.border, width: 0),
                      ),
                      child: const Icon(
                        Icons.add_rounded,
                        size: 16,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Group list
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              buildDefaultDragHandles: false,
              onReorder: (oldIndex, newIndex) {
                if (groups.isEmpty) return;
                if (newIndex > oldIndex) newIndex -= 1;
                final allGroups = widget.manager.groups;
                final movedGroupId = groups[oldIndex].id;
                // When search is active, map filtered newIndex to
                // unfiltered position so the manager sees the right slot.
                final int targetIndex;
                if (newIndex < groups.length) {
                  targetIndex = allGroups.indexWhere(
                    (g) => g.id == groups[newIndex].id,
                  );
                } else {
                  // Moved to the end of the filtered list → place after the
                  // last visible group in the full list.
                  final lastVisibleId = groups.last.id;
                  targetIndex = allGroups.indexWhere(
                    (g) => g.id == lastVisibleId,
                  ) + 1;
                }
                if (targetIndex >= 0) {
                  widget.manager.reorderGroup(movedGroupId, targetIndex);
                }
              },
              itemCount: groups.length,
              itemBuilder: (context, index) {
                final group = groups[index];
                return Padding(
                  key: ValueKey('group-${group.id}'),
                  padding: const EdgeInsets.only(bottom: 8),
                  child: _buildGroupTile(group, index),
                );
              },
            ),
          ),
        ],
      ),
    );

    if (widget.embedded) {
      return Material(color: AppColors.surface, child: content);
    }
    return Drawer(backgroundColor: AppColors.surface, child: content);
  }

  Widget _buildGroupTile(TerminalGroup group, int index) {
    final isActive = group.id == widget.manager.activeGroupId;
    final isCollapsed = _collapsedGroupIds.contains(group.id);
    final isEditing = _editingGroupId == group.id;

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredGroupId = group.id),
      onExit: (_) => setState(() {
        if (_hoveredGroupId == group.id) _hoveredGroupId = null;
      }),
      child: AnimatedContainer(
        duration: AppDurations.normal,
        decoration: BoxDecoration(
          color: isActive ? AppColors.background : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isActive
                ? AppColors.border
                : Colors.transparent,
          ),
        ),
        child: Column(
          children: [
            _buildGroupHeader(group, index, isCollapsed, isEditing),
            if (!isCollapsed) _buildSessionList(group, isActive),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupHeader(
    TerminalGroup group,
    int index,
    bool isCollapsed,
    bool isEditing,
  ) {
    final header = InkWell(
      onTap: () => widget.manager.setActiveGroup(group.id),
      borderRadius: BorderRadius.circular(14),
      child: SizedBox(
        height: 32,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              GestureDetector(
                onTap: () => _toggleCollapse(group.id),
                child: Icon(
                  isCollapsed
                      ? Icons.chevron_right_rounded
                      : Icons.expand_more_rounded,
                  color: AppColors.textMuted,
                  size: 16,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: isEditing
                    ? TextField(
                        controller: _editController,
                        focusNode: _editFocusNode,
                        style: const TextStyle(
                          color: AppColors.textPrimary,
                          fontSize: 12,
                        ),
                        decoration: const InputDecoration(
                          isDense: true,
                          contentPadding: EdgeInsets.symmetric(
                              horizontal: 6, vertical: 4),
                          border: InputBorder.none,
                        ),
                        onSubmitted: (_) => _submitGroupEdit(group.id),
                        onTapOutside: (_) => _cancelEdit(),
                      )
                    : GestureDetector(
                        onDoubleTap: () =>
                            _startEditingGroup(group.id, group.name),
                        child: Text(
                          group.name,
                          style: const TextStyle(
                            color: AppColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
              ),
              // Hover-revealed group actions
              if (!isEditing)
                _buildGroupActions(group, index),
            ],
          ),
        ),
      ),
    );

    return header;
  }

  Widget _buildGroupActions(TerminalGroup group, int index) {
    final show = _hoveredGroupId == group.id || _isMobile;
    return _hoverReveal(
      show: show,
      child: SizedBox(
        height: 32,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.onAddSession != null)
              Tooltip(
                message: 'New session',
                child: InkWell(
                  onTap: () => widget.onAddSession!(group.id),
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox(
                    width: 28,
                    height: 32,
                    child: Center(
                      child: Icon(
                        Icons.add_rounded,
                        size: 14,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            _buildGroupMenu(group),
            if (_searchQuery.trim().isEmpty)
              ReorderableDragStartListener(
                index: index,
                child: const SizedBox(
                  width: 24,
                  height: 32,
                  child: Center(
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupMenu(TerminalGroup group) {
    return PopupMenuButton<String>(
      tooltip: 'Group actions',
      color: AppColors.background,
      onSelected: (value) {
        switch (value) {
          case 'rename':
            _startEditingGroup(group.id, group.name);
            break;
          case 'delete':
            widget.manager.deleteGroup(group.id);
            break;
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(
          value: 'rename',
          child: Text('Rename group',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13)),
        ),
        const PopupMenuItem(
          value: 'delete',
          child: Text('Delete group',
              style: TextStyle(color: AppColors.textPrimary, fontSize: 13)),
        ),
      ],
      child: const SizedBox(
        width: 28,
        height: 32,
        child: Center(
          child: Icon(
            Icons.more_vert_rounded,
            size: 16,
            color: AppColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildSessionList(TerminalGroup group, bool isActiveGroup) {
    if (group.sessionIds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'No sessions',
            style: TextStyle(
              color: AppColors.textMuted.withValues(alpha: 0.8),
              fontSize: 11,
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          for (var i = 0; i < group.sessionIds.length; i++)
            _buildSessionRow(
              groupId: group.id,
              sessionId: group.sessionIds[i],
              label: widget.sessionLabelBuilder
                      ?.call(group.sessionIds[i], i) ??
                  widget.manager.getSessionName(group.sessionIds[i], i),
              isActive:
                  group.sessionIds[i] == widget.activeSessionId &&
                  isActiveGroup,
            ),
        ],
      ),
    );
  }

  Widget _buildSessionRow({
    required String groupId,
    required String sessionId,
    required String label,
    required bool isActive,
  }) {
    final isEditing = _editingSessionId == sessionId;

    if (isEditing) {
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 2),
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: TextField(
          controller: _editController,
          focusNode: _editFocusNode,
          style: const TextStyle(color: AppColors.textPrimary, fontSize: 12),
          decoration: const InputDecoration(
            isDense: true,
            contentPadding:
                EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            border: InputBorder.none,
          ),
          onSubmitted: (_) => _submitSessionEdit(sessionId),
          onTapOutside: (_) => _cancelEdit(),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredSessionId = sessionId),
      onExit: (_) => setState(() {
        if (_hoveredSessionId == sessionId) _hoveredSessionId = null;
      }),
      child: InkWell(
        onTap: () => _selectSession(groupId, sessionId),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 2),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isActive ? AppColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActive
                  ? AppColors.border
                  : Colors.transparent,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              StatusDot(
                connected: isActive,
                size: 6,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: GestureDetector(
                  onDoubleTap: () =>
                      _startEditingSession(sessionId, label),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: isActive
                          ? AppColors.textPrimary
                          : AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _hoverReveal(
                show: _hoveredSessionId == sessionId || _isMobile,
                child: InkWell(
                  onTap: () => widget.onCloseSession(sessionId),
                  borderRadius: BorderRadius.circular(8),
                  child: const SizedBox(
                    width: 24,
                    height: 32,
                    child: Center(
                      child: Icon(
                        Icons.close_rounded,
                        size: 14,
                        color: AppColors.textMuted,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
