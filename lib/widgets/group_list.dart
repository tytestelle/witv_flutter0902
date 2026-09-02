import 'package:flutter/material.dart';
import 'package:coocaa_flutter_focus/coocaa_flutter_focus.dart';

class GroupList extends StatelessWidget {
  final List<String> groups;
  final String? selectedGroup;
  final ValueChanged<String> onSelect;

  const GroupList({
    super.key,
    required this.groups,
    this.selectedGroup,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withOpacity(0.2),
      child: ListView.builder(
        itemCount: groups.length,
        itemBuilder: (context, index) {
          final group = groups[index];
          final isSelected = group == selectedGroup;
          return FocusableWidget(
            focusId: 'group_$index',
            onTap: () => onSelect(group),
            focusDecoration: FocusDecoration(
              boxDecoration: BoxDecoration(
                color: Colors.blue.withOpacity(0.25),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.blue, width: 2),
              ),
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: isSelected ? Colors.blue.withOpacity(0.15) : Colors.transparent,
              ),
              child: Text(
                group,
                style: TextStyle(
                  color: isSelected ? Colors.yellow : Colors.white70,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 14,
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
