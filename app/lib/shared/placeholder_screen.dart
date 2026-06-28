import 'package:flutter/material.dart';
import 'package:quran_tasmee3/l10n/app_localizations.dart';

/// Temporary screen for not-yet-migrated tabs. Replaced as each feature lands.
class PlaceholderScreen extends StatelessWidget {
  final String title;
  const PlaceholderScreen({super.key, required this.title});

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(title)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.construction_outlined, size: 48),
            const SizedBox(height: 12),
            Text(l.comingSoon, style: Theme.of(context).textTheme.titleMedium),
          ],
        ),
      ),
    );
  }
}
