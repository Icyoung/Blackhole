import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/terminal_group.dart';
import '../services/group_store.dart';

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

  @override
  State<GroupDrawer> createState() => _GroupDrawerState();
}

class _DraggedSession {
  const _DraggedSession({required this.sessionId, required this.fromGroupId});
  final String sessionId;
  final String fromGroupId;
}

class _GroupDrawerState extends State<GroupDrawer> {
  String? _editingGroupId;
  String? _editingSessionId;
  bool _isDraggingSession = false;
  String? _dragOverGroupId; // For session drops - turns group green
  bool _dragOverTrash = false;
  final _editController = TextEditingController();
  final _editFocusNode = FocusNode();

  bool get _isDragging => _isDraggingSession;

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
    setState(() {
      _editingGroupId = null;
    });
  }

  void _submitSessionEdit(String sessionId) {
    final trimmed = _editController.text.trim();
    widget.manager.renameSession(sessionId, trimmed);
    setState(() {
      _editingSessionId = null;
    });
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
    Navigator.of(context).maybePop();
  }

  void _onSessionDropped(String sessionId, String fromGroupId, String toGroupId) {
    if (fromGroupId != toGroupId) {
      widget.manager.moveSession(sessionId, toGroupId);
    }
  }

  void _deleteSession(String sessionId) {
    widget.onCloseSession(sessionId);
  }

  void _addGroup() {
    widget.manager.createGroup();
  }

  @override
  Widget build(BuildContext context) {
    final activeGroupId = widget.manager.activeGroupId;

    return Drawer(
      backgroundColor: const Color(0xFF0F141B),
      child: SafeArea(
        child: Column(
          children: [
                // Header
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 8, 8),
                  child: Row(
                    children: [
                      const Icon(Icons.folder_outlined, color: Color(0xFF4B7AA6), size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      // Trash drop target in header (accepts sessions only)
                      if (_isDragging)
                        DragTarget<Object>(
                          onWillAcceptWithDetails: (details) {
                            final data = details.data;
                            if (data is _DraggedSession) {
                              setState(() {
                                _dragOverTrash = true;
                              });
                              return true;
                            }
                            return false;
                          },
                          onLeave: (_) {
                            setState(() {
                              _dragOverTrash = false;
                            });
                          },
                          onAcceptWithDetails: (details) {
                            final data = details.data;
                            if (data is _DraggedSession) {
                              _deleteSession(data.sessionId);
                            }
                            setState(() {
                              _dragOverTrash = false;
                              _isDraggingSession = false;
                            });
                          },
                          builder: (context, candidateData, rejectedData) {
                            return AnimatedContainer(
                              duration: const Duration(milliseconds: 150),
                              width: 36,
                              height: 36,
                              decoration: BoxDecoration(
                                color: _dragOverTrash
                                    ? const Color(0xFFFF6B6B)
                                    : const Color(0xFF2A1A1A),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFFFF6B6B),
                                  width: _dragOverTrash ? 2 : 1,
                                ),
                              ),
                              child: Icon(
                                Icons.delete_outline,
                                color: _dragOverTrash ? Colors.white : const Color(0xFFFF6B6B),
                                size: 20,
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
                const Divider(height: 1, color: Color(0xFF1F2A38)),
                // Groups list
                Expanded(
                  child: CustomScrollView(
                    slivers: [
                      SliverPadding(
                        padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
                        sliver: SliverReorderableList(
                          itemCount: widget.manager.groups.length,
                          onReorder: (oldIndex, newIndex) {
                            final groups = widget.manager.groups;
                            if (groups.isEmpty) {
                              return;
                            }
                            if (newIndex > oldIndex) {
                              newIndex -= 1;
                            }
                            final groupId = groups[oldIndex].id;
                            widget.manager.reorderGroup(groupId, newIndex);
                          },
                          itemBuilder: (context, index) {
                            final group = widget.manager.groups[index];
                            final canReorder = _editingGroupId == null && _editingSessionId == null;
                            return _GroupSection(
                              key: ValueKey('group-${group.id}'),
                              group: group,
                              groupIndex: index,
                              canReorder: canReorder,
                              isActive: group.id == activeGroupId,
                              isDragOver: _isDraggingSession && _dragOverGroupId == group.id,
                              editingGroupId: _editingGroupId,
                              editingSessionId: _editingSessionId,
                              editController: _editController,
                              editFocusNode: _editFocusNode,
                              activeSessionId: widget.activeSessionId,
                              manager: widget.manager,
                              onTap: () {
                                widget.manager.setActiveGroup(group.id);
                              },
                              onAddSession: widget.onAddSession == null
                                  ? null
                                  : () => widget.onAddSession!(group.id),
                              showGroupCount: widget.showGroupCount,
                              groupLabelBuilder: widget.groupLabelBuilder,
                              sessionLabelBuilder: widget.sessionLabelBuilder,
                              onDoubleClickGroupName: () {
                                _startEditingGroup(group.id, group.name);
                              },
                              onDoubleClickSessionName: (sessionId, name) {
                                _startEditingSession(sessionId, name);
                              },
                              onSubmitGroupEdit: () => _submitGroupEdit(group.id),
                              onSubmitSessionEdit: (sessionId) => _submitSessionEdit(sessionId),
                              onCancelEdit: _cancelEdit,
                              onSelectSession: (sessionId) => _selectSession(group.id, sessionId),
                              onSessionDragOver: (isOver) {
                                setState(() {
                                  _dragOverGroupId = isOver ? group.id : null;
                                });
                              },
                              onSessionDragStarted: () {
                                setState(() {
                                  _isDraggingSession = true;
                                });
                              },
                              onSessionDragEnded: () {
                                setState(() {
                                  _isDraggingSession = false;
                                  _dragOverTrash = false;
                                  _dragOverGroupId = null;
                                });
                              },
                              onSessionDropped: (sessionId, fromGroupId) {
                                _onSessionDropped(sessionId, fromGroupId, group.id);
                              },
                            );
                          },
                        ),
                      ),
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(8, 0, 8, 24),
                          child: Material(
                            color: const Color(0xFF121824),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: InkWell(
                              onTap: _addGroup,
                              borderRadius: BorderRadius.circular(12),
                              child: const Padding(
                                padding: EdgeInsets.symmetric(vertical: 14),
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    Icon(Icons.add, color: Color(0xFF4B7AA6), size: 20),
                                    SizedBox(width: 8),
                                    Text(
                                      'Add Group',
                                      style: TextStyle(
                                        color: Color(0xFF4B7AA6),
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    super.key,
    required this.group,
    required this.groupIndex,
    required this.canReorder,
    required this.isActive,
    required this.isDragOver,
    required this.editingGroupId,
    required this.editingSessionId,
    required this.editController,
    required this.editFocusNode,
    required this.activeSessionId,
    required this.manager,
    required this.onTap,
    required this.onAddSession,
    required this.showGroupCount,
    required this.groupLabelBuilder,
    required this.sessionLabelBuilder,
    required this.onDoubleClickGroupName,
    required this.onDoubleClickSessionName,
    required this.onSubmitGroupEdit,
    required this.onSubmitSessionEdit,
    required this.onCancelEdit,
    required this.onSelectSession,
    required this.onSessionDragOver,
    required this.onSessionDragStarted,
    required this.onSessionDragEnded,
    required this.onSessionDropped,
  });

  final TerminalGroup group;
  final int groupIndex;
  final bool canReorder;
  final bool isActive;
  final bool isDragOver;
  final String? editingGroupId;
  final String? editingSessionId;
  final TextEditingController editController;
  final FocusNode editFocusNode;
  final String? activeSessionId;
  final GroupStore manager;
  final VoidCallback onTap;
  final VoidCallback? onAddSession;
  final bool showGroupCount;
  final String Function(TerminalGroup group, int count)? groupLabelBuilder;
  final String Function(String sessionId, int index)? sessionLabelBuilder;
  final VoidCallback onDoubleClickGroupName;
  final void Function(String sessionId, String name) onDoubleClickSessionName;
  final VoidCallback onSubmitGroupEdit;
  final void Function(String sessionId) onSubmitSessionEdit;
  final VoidCallback onCancelEdit;
  final ValueChanged<String> onSelectSession;
  final ValueChanged<bool> onSessionDragOver;
  final VoidCallback onSessionDragStarted;
  final VoidCallback onSessionDragEnded;
  final void Function(String sessionId, String fromGroupId) onSessionDropped;

  @override
  Widget build(BuildContext context) {
    final count = group.sessionIds.length;
    final isEditingThisGroup = editingGroupId == group.id;
    final headerColor = isDragOver
        ? const Color(0xFF1A3A2A)
        : isActive
            ? const Color(0xFF1A2A3A)
            : const Color(0xFF121824);
    final borderColor = isDragOver
        ? const Color(0xFF4BA66B)
        : isActive
            ? const Color(0xFF4B7AA6)
            : Colors.white.withValues(alpha: 0.08);

    // The group content widget
    final label =
        groupLabelBuilder?.call(group, count) ??
        (showGroupCount ? '${group.name} ($count)' : group.name);

    Widget groupContent = Container(
      decoration: BoxDecoration(
        color: headerColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: borderColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header - make it draggable for non-default groups
          _buildHeader(isEditingThisGroup, label),
          // Sessions
          if (group.sessionIds.isEmpty)
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Text('No sessions', style: TextStyle(color: Colors.white54, fontSize: 12)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Column(
                children: [
                  for (var index = 0; index < group.sessionIds.length; index += 1)
                    _SessionTile(
                      sessionId: group.sessionIds[index],
                      groupId: group.id,
                      label: sessionLabelBuilder?.call(group.sessionIds[index], index) ??
                          manager.getSessionName(group.sessionIds[index], index),
                      active: group.sessionIds[index] == activeSessionId,
                      isEditing: editingSessionId == group.sessionIds[index],
                      editController: editController,
                      editFocusNode: editFocusNode,
                      onTap: () => onSelectSession(group.sessionIds[index]),
                      onDoubleTap: () => onDoubleClickSessionName(
                        group.sessionIds[index],
                        manager.getSessionName(group.sessionIds[index], index),
                      ),
                      onSubmitEdit: () => onSubmitSessionEdit(group.sessionIds[index]),
                      onCancelEdit: onCancelEdit,
                      onDragStarted: onSessionDragStarted,
                      onDragEnded: onSessionDragEnded,
                    ),
                ],
              ),
            ),
        ],
      ),
    );

    // Wrap with DragTarget for sessions and groups
    return DragTarget<Object>(
      onWillAcceptWithDetails: (details) {
        final data = details.data;
        if (data is _DraggedSession) {
          // Session drag - turn group green
          onSessionDragOver(true);
          return true;
        }
        return false;
      },
      onLeave: (data) {
        if (data is _DraggedSession) {
          onSessionDragOver(false);
        }
      },
      onAcceptWithDetails: (details) {
        final data = details.data;
        if (data is _DraggedSession) {
          onSessionDragOver(false);
          onSessionDropped(data.sessionId, data.fromGroupId);
        }
      },
      builder: (context, candidateData, rejectedData) {
        return Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: groupContent,
        );
      },
    );
  }

  Widget _buildHeader(bool isEditingThisGroup, String label) {
    final addColor =
        isEditingThisGroup ? Colors.white24 : const Color(0xFF4B7AA6);
    final headerWidget = Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: onTap,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: isEditingThisGroup
                    ? TextField(
                        controller: editController,
                        focusNode: editFocusNode,
                        style: const TextStyle(color: Colors.white, fontSize: 14),
                        decoration: InputDecoration(
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                          filled: true,
                          fillColor: const Color(0xFF0F141B),
                          border: OutlineInputBorder(
                            borderSide: const BorderSide(color: Colors.white24),
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        onSubmitted: (_) => onSubmitGroupEdit(),
                        onTapOutside: (_) => onCancelEdit(),
                      )
                    : GestureDetector(
                        onDoubleTap: onDoubleClickGroupName,
                        child: Text(
                          label,
                          style: const TextStyle(color: Colors.white, fontSize: 14),
                        ),
                      ),
              ),
              if (onAddSession != null) ...[
                const SizedBox(width: 8),
                IconButton(
                  onPressed: isEditingThisGroup ? null : onAddSession,
                  tooltip: 'New terminal',
                  padding: const EdgeInsets.all(4),
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  icon: Icon(Icons.add, size: 16, color: addColor),
                ),
              ],
            ],
          ),
        ),
      ),
    );

    if (!canReorder) {
      return headerWidget;
    }

    return ReorderableDelayedDragStartListener(
      index: groupIndex,
      child: headerWidget,
    );
  }
}

class _SessionTile extends StatelessWidget {
  const _SessionTile({
    required this.sessionId,
    required this.groupId,
    required this.label,
    required this.active,
    required this.isEditing,
    required this.editController,
    required this.editFocusNode,
    required this.onTap,
    required this.onDoubleTap,
    required this.onSubmitEdit,
    required this.onCancelEdit,
    required this.onDragStarted,
    required this.onDragEnded,
  });

  final String sessionId;
  final String groupId;
  final String label;
  final bool active;
  final bool isEditing;
  final TextEditingController editController;
  final FocusNode editFocusNode;
  final VoidCallback onTap;
  final VoidCallback onDoubleTap;
  final VoidCallback onSubmitEdit;
  final VoidCallback onCancelEdit;
  final VoidCallback onDragStarted;
  final VoidCallback onDragEnded;

  @override
  Widget build(BuildContext context) {
    if (isEditing) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: TextField(
          controller: editController,
          focusNode: editFocusNode,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            isDense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            filled: true,
            fillColor: const Color(0xFF0F141B),
            border: OutlineInputBorder(
              borderSide: const BorderSide(color: Colors.white24),
              borderRadius: BorderRadius.circular(8),
            ),
          ),
          onSubmitted: (_) => onSubmitEdit(),
          onTapOutside: (_) => onCancelEdit(),
        ),
      );
    }

    final tile = Material(
      type: MaterialType.transparency,
      child: ListTile(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(
          Icons.circle,
          size: 8,
          color: active ? const Color(0xFF4B7AA6) : Colors.white24,
        ),
        title: GestureDetector(
          onDoubleTap: onDoubleTap,
          child: Text(
            label,
            style: TextStyle(
              color: active ? Colors.white : Colors.white70,
              fontSize: 13,
              fontWeight: active ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
        onTap: onTap,
      ),
    );

    return LongPressDraggable<_DraggedSession>(
      data: _DraggedSession(sessionId: sessionId, fromGroupId: groupId),
      delay: const Duration(milliseconds: 200),
      hapticFeedbackOnStart: true,
      onDragStarted: () {
        HapticFeedback.mediumImpact();
        onDragStarted();
      },
      onDragEnd: (_) => onDragEnded(),
      onDraggableCanceled: (_, __) => onDragEnded(),
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          width: 200,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFF1A2A3A),
            borderRadius: BorderRadius.circular(8),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.terminal, size: 16, color: Color(0xFF4B7AA6)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      childWhenDragging: Opacity(
        opacity: 0.4,
        child: tile,
      ),
      child: tile,
    );
  }
}
