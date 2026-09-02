import 'package:flutter/material.dart';

class GroupList extends StatelessWidget {
  final List<String> groups;
  final String? selectedGroup;
  final ValueChanged<String> onSelect;

  const GroupList({
    Key? key,
    required this.groups,
    this.selectedGroup,
    required this.onSelect,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: groups.length,
      itemBuilder: (context, index) {
        final group = groups[index];
        final isSelected = group == selectedGroup;
        return ListTile(
          title: Text(
            group,
            style: TextStyle(
              color: isSelected ? Colors.yellow : Colors.white70,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              fontSize: 14,
            ),
          ),
          onTap: () => onSelect(group),
        );
      },
    );
  }
}
