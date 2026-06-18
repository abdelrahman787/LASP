import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/widgets/glass.dart';

/// A saved reading position. (The persistence layer isn't built yet — this is
/// the visual screen wired to a placeholder source; swap [bookmarksProvider]
/// for a real repo later.)
class Bookmark {
  final int surah;
  final int ayah;
  final int page;
  final String label;
  const Bookmark(
      {required this.surah,
      required this.ayah,
      required this.page,
      this.label = ''});
}

/// Placeholder until a BookmarkRepository (Firestore) is added — returns empty,
/// so the empty state shows. Swap this binding when the repo lands.
final bookmarksProvider = Provider<List<Bookmark>>((ref) => const <Bookmark>[]);

class BookmarksScreen extends ConsumerWidget {
  const BookmarksScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bookmarks = ref.watch(bookmarksProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('المرجعيات')),
      // Mutually exclusive states (correction #3): empty illustration ONLY when
      // truly empty; the list ONLY when it has items.
      body: bookmarks.isEmpty
          ? _emptyState(context)
          : _list(context, bookmarks),
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.bookmark_border,
                size: 96, color: theme.colorScheme.outline),
            const SizedBox(height: 16),
            Text('لا توجد مرجعيات بعد',
                style: theme.textTheme.titleMedium, textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'أضف إشارة مرجعية من صفحة المصحف للعودة إليها بسرعة.',
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _list(BuildContext context, List<Bookmark> bookmarks) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final b in bookmarks)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: GlassCard(
              padding: EdgeInsets.zero,
              child: ListTile(
                leading: Icon(Icons.bookmark, color: theme.colorScheme.primary),
                title: Text(b.label.isNotEmpty ? b.label : '${b.surah}:${b.ayah}'),
                subtitle: Text('صفحة ${b.page}'),
              ),
            ),
          ),
      ],
    );
  }
}
