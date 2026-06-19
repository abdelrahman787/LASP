import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/providers.dart';
import '../bookmarks/bookmarks_screen.dart';
import '../mushaf/mushaf_index_screen.dart';
import '../mushaf/mushaf_reader_screen.dart';
import '../settings/settings_screen.dart';

/// Side menu (C2): الفهرس / المصحف / العلامات المرجعية / الإعدادات / حول.
class AppDrawer extends ConsumerWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    Future<void> openReaderAt(int page) async {
      Navigator.of(context).pop(); // close drawer
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MushafReaderScreen(initialPage: page)));
    }

    return Drawer(
      child: SafeArea(
        child: ListView(
          children: [
            DrawerHeader(
              decoration: BoxDecoration(color: theme.colorScheme.primary),
              child: Align(
                alignment: AlignmentDirectional.bottomStart,
                child: Text('القرآن الكريم',
                    style: theme.textTheme.headlineSmall
                        ?.copyWith(color: theme.colorScheme.onPrimary)),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.format_list_bulleted),
              title: const Text('الفهرس'),
              onTap: () async {
                Navigator.of(context).pop();
                final page = await Navigator.of(context).push<int>(
                    MaterialPageRoute(builder: (_) => const MushafIndexScreen()));
                if (page != null && context.mounted) {
                  await Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => MushafReaderScreen(initialPage: page)));
                }
              },
            ),
            ListTile(
              leading: const Icon(Icons.menu_book),
              title: const Text('المصحف'),
              onTap: () => openReaderAt(1),
            ),
            ListTile(
              leading: const Icon(Icons.bookmarks_outlined),
              title: const Text('العلامات المرجعية'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const BookmarksScreen()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.settings_outlined),
              title: const Text('الإعدادات'),
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SettingsScreen()));
              },
            ),
            const Divider(),
            ListTile(
              leading: const Icon(Icons.info_outline),
              title: const Text('حول التطبيق'),
              onTap: () {
                Navigator.of(context).pop();
                showAboutDialog(
                  context: context,
                  applicationName: 'قرآن تسميع',
                  children: const [
                    Text('بيانات القرآن من Quran Foundation (Mushaf QCF V2). '
                        'خطوط QCF V2 من مجمع الملك فهد لطباعة المصحف الشريف.'),
                  ],
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.logout),
              title: const Text('تسجيل الخروج'),
              onTap: () => ref.read(authServiceProvider).signOut(),
            ),
          ],
        ),
      ),
    );
  }
}
