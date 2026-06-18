import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/data/quran_repository.dart';
import '../../app/providers.dart';
import '../../app/widgets/glass.dart';

/// Mushaf index (Viewer Phase 4 / design 02_mushaf_index): surah list, juz
/// list, go-to-page, go-to-verse, surah search. Returns the chosen page via
/// `Navigator.pop(context, page)` so the reader can jump to it.
class MushafIndexScreen extends ConsumerStatefulWidget {
  const MushafIndexScreen({super.key});

  @override
  ConsumerState<MushafIndexScreen> createState() => _MushafIndexScreenState();
}

class _MushafIndexScreenState extends ConsumerState<MushafIndexScreen> {
  String _query = '';

  void _go(int page) => Navigator.of(context).pop(page);

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(quranDataProvider).valueOrNull;
    final surahs = data?.surahs ?? const <SurahInfo>[];
    final juzPages = data?.juzStartPages ?? const <int, int>{};

    final filtered = _query.isEmpty
        ? surahs
        : surahs
            .where((s) =>
                s.nameAr.contains(_query) ||
                s.nameEn.toLowerCase().contains(_query.toLowerCase()) ||
                '${s.id}' == _query)
            .toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('الفهرس'),
          bottom: const TabBar(
            tabs: [Tab(text: 'السور'), Tab(text: 'الأجزاء')],
          ),
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: _GoToRow(
                onGoToPage: (p) {
                  if (p >= 1 && p <= 604) _go(p);
                },
                onGoToVerse: (s, a) {
                  final page = data?.pageForVerse(s, a);
                  if (page != null) _go(page);
                },
              ),
            ),
            Expanded(
              child: TabBarView(
                children: [
                  // Surah list (with search).
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 4),
                        child: TextField(
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search),
                            hintText: 'ابحث عن سورة',
                            border: OutlineInputBorder(),
                          ),
                          onChanged: (v) => setState(() => _query = v.trim()),
                        ),
                      ),
                      Expanded(
                        child: surahs.isEmpty
                            ? const Center(
                                child: Text('بيانات السور غير متوفرة.'))
                            : ListView.builder(
                                padding: const EdgeInsets.all(12),
                                itemCount: filtered.length,
                                itemBuilder: (context, i) {
                                  final s = filtered[i];
                                  return Padding(
                                    padding: const EdgeInsets.only(bottom: 8),
                                    child: GlassCard(
                                      padding: EdgeInsets.zero,
                                      onTap: () => _go(s.startPage),
                                      child: ListTile(
                                        leading: CircleAvatar(
                                          child: Text('${s.id}'),
                                        ),
                                        title: Text(s.nameAr.isNotEmpty
                                            ? s.nameAr
                                            : s.nameEn),
                                        subtitle: Text(
                                            '${s.versesCount} آية · '
                                            '${_place(s.revelationPlace)} · صفحة ${s.startPage}'),
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                  // Juz list.
                  ListView.builder(
                    padding: const EdgeInsets.all(12),
                    itemCount: 30,
                    itemBuilder: (context, i) {
                      final juz = i + 1;
                      final page = juzPages[juz];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: GlassCard(
                          padding: EdgeInsets.zero,
                          onTap: page == null ? null : () => _go(page),
                          child: ListTile(
                            leading: CircleAvatar(child: Text('$juz')),
                            title: Text('الجزء $juz'),
                            subtitle:
                                Text(page == null ? '—' : 'صفحة $page'),
                          ),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _place(String p) =>
      p.toLowerCase().startsWith('mad') ? 'مدنية' : 'مكية';
}

/// Compact "go to page" + "go to verse" inputs.
class _GoToRow extends StatelessWidget {
  final ValueChanged<int> onGoToPage;
  final void Function(int surah, int ayah) onGoToVerse;
  const _GoToRow({required this.onGoToPage, required this.onGoToVerse});

  @override
  Widget build(BuildContext context) {
    final pageCtrl = TextEditingController();
    final surahCtrl = TextEditingController();
    final ayahCtrl = TextEditingController();
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: pageCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                      labelText: 'انتقل إلى صفحة (1–604)'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final p = int.tryParse(pageCtrl.text.trim());
                  if (p != null) onGoToPage(p);
                },
                child: const Text('اذهب'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: surahCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'سورة'),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: ayahCtrl,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'آية'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final s = int.tryParse(surahCtrl.text.trim());
                  final a = int.tryParse(ayahCtrl.text.trim());
                  if (s != null && a != null) onGoToVerse(s, a);
                },
                child: const Text('اذهب'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
