import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:quran_tasmee3_core/recitation/recitation_config.dart';
import 'package:quran_tasmee3_core/review/models.dart';
import 'package:quran_tasmee3_core/review/repositories.dart';
import 'package:quran_tasmee3_core/review/settings.dart';

/// Firestore-backed repositories (spec Phase 2/5). All data lives under
/// `users/<uid>/...`; offline persistence (enabled in main.dart) handles sync
/// automatically — no manual queue/retry. Mappers live here so the pure-Dart
/// core stays Firebase-free.

CollectionReference<Map<String, dynamic>> _userCol(String uid, String name) =>
    FirebaseFirestore.instance.collection('users').doc(uid).collection(name);

// --- weak items: users/<uid>/weakItems/<wordId> ------------------------------
class FirestoreWeakItemRepository implements WeakItemRepository {
  final String uid;
  FirestoreWeakItemRepository(this.uid);

  CollectionReference<Map<String, dynamic>> get _col =>
      _userCol(uid, 'weakItems');

  WeakItem _fromDoc(String wordId, Map<String, dynamic> m) => WeakItem(
        wordId: wordId,
        surah: (m['surah'] ?? 0) as int,
        ayah: (m['ayah'] ?? 0) as int,
        wordIndex: (m['wordIndex'] ?? 0) as int,
        errorCount: (m['errorCount'] ?? 0) as int,
        lastErrorAt: (m['lastErrorAt'] ?? 0) as int,
        masteryScore: ((m['masteryScore'] ?? 1.0) as num).toDouble(),
        forgetCount: (m['forgetCount'] ?? 0) as int,
      );

  Map<String, dynamic> _toMap(WeakItem w) => {
        'surah': w.surah,
        'ayah': w.ayah,
        'wordIndex': w.wordIndex,
        'errorCount': w.errorCount,
        'lastErrorAt': w.lastErrorAt,
        'masteryScore': w.masteryScore,
        'forgetCount': w.forgetCount,
      };

  @override
  Future<List<WeakItem>> getAll() async {
    final snap = await _col.get();
    return snap.docs.map((d) => _fromDoc(d.id, d.data())).toList();
  }

  @override
  Future<WeakItem?> get(String wordId) async {
    final d = await _col.doc(wordId).get();
    final data = d.data();
    return data == null ? null : _fromDoc(d.id, data);
  }

  @override
  Future<Map<String, WeakItem>> getMany(Iterable<String> wordIds) async {
    final ids = wordIds.toSet().toList();
    final out = <String, WeakItem>{};
    // Firestore allows up to 30 values in a `whereIn` filter; chunk the ids.
    const chunk = 30;
    for (var i = 0; i < ids.length; i += chunk) {
      final slice = ids.sublist(i, (i + chunk).clamp(0, ids.length));
      if (slice.isEmpty) continue;
      final snap =
          await _col.where(FieldPath.documentId, whereIn: slice).get();
      for (final d in snap.docs) {
        out[d.id] = _fromDoc(d.id, d.data());
      }
    }
    return out;
  }

  @override
  Future<void> upsert(WeakItem item) =>
      _col.doc(item.wordId).set(_toMap(item));

  @override
  Future<void> upsertAll(Iterable<WeakItem> items) async {
    final batch = FirebaseFirestore.instance.batch();
    for (final it in items) {
      batch.set(_col.doc(it.wordId), _toMap(it));
    }
    await batch.commit();
  }

  @override
  Future<void> delete(String wordId) => _col.doc(wordId).delete();

  @override
  Future<void> clear() async {
    final snap = await _col.get();
    final batch = FirebaseFirestore.instance.batch();
    for (final d in snap.docs) {
      batch.delete(d.reference);
    }
    await batch.commit();
  }
}

// --- plan (de)serialization --------------------------------------------------
Map<String, dynamic> _planItemToMap(PlanItem i) => {
      'id': i.id,
      'surah': i.surah,
      'ayah': i.ayah,
      'ayahEnd': i.ayahEnd,
      'ease': i.ease,
      'intervalDays': i.intervalDays,
      'repetitions': i.repetitions,
      'dueAt': i.dueAt,
      'lastScore': i.lastScore,
      'status': i.status.wire,
    };

PlanItem _planItemFromMap(Map<String, dynamic> m) => PlanItem(
      id: m['id'] as String,
      surah: (m['surah'] ?? 0) as int,
      ayah: (m['ayah'] ?? 0) as int,
      ayahEnd: m['ayahEnd'] as int?,
      ease: ((m['ease'] ?? 2.5) as num).toDouble(),
      intervalDays: (m['intervalDays'] ?? 0) as int,
      repetitions: (m['repetitions'] ?? 0) as int,
      dueAt: (m['dueAt'] ?? 0) as int,
      lastScore: (m['lastScore'] as num?)?.toDouble(),
      status: PlanItemStatusWire.fromWire((m['status'] ?? 'new') as String),
    );

// --- plans: users/<uid>/reviewPlans/<planId> ---------------------------------
class FirestorePlanRepository implements PlanRepository {
  final String uid;
  FirestorePlanRepository(this.uid);

  CollectionReference<Map<String, dynamic>> get _col =>
      _userCol(uid, 'reviewPlans');

  ReviewPlan _fromDoc(String id, Map<String, dynamic> m) => ReviewPlan(
        id: id,
        name: (m['name'] ?? '') as String,
        items: ((m['items'] ?? const []) as List)
            .map((e) => _planItemFromMap((e as Map).cast<String, dynamic>()))
            .toList(),
        dailyTarget: (m['dailyTarget'] ?? 10) as int,
        createdAt: (m['createdAt'] ?? 0) as int,
        updatedAt: (m['updatedAt'] ?? 0) as int,
      );

  Map<String, dynamic> _toMap(ReviewPlan p) => {
        'name': p.name,
        'items': p.items.map(_planItemToMap).toList(),
        'dailyTarget': p.dailyTarget,
        'createdAt': p.createdAt,
        'updatedAt': p.updatedAt,
      };

  @override
  Future<List<ReviewPlan>> getAll() async {
    final snap = await _col.get();
    return snap.docs.map((d) => _fromDoc(d.id, d.data())).toList();
  }

  @override
  Future<ReviewPlan?> get(String planId) async {
    final d = await _col.doc(planId).get();
    final data = d.data();
    return data == null ? null : _fromDoc(d.id, data);
  }

  @override
  Future<void> save(ReviewPlan plan) => _col.doc(plan.id).set(_toMap(plan));

  @override
  Future<void> delete(String planId) => _col.doc(planId).delete();
}

// --- review history: users/<uid>/reviewHistory/<auto> ------------------------
class FirestoreReviewHistoryRepository implements ReviewHistoryRepository {
  final String uid;
  FirestoreReviewHistoryRepository(this.uid);

  CollectionReference<Map<String, dynamic>> get _col =>
      _userCol(uid, 'reviewHistory');

  Map<String, dynamic> _toMap(ReviewResult r) => {
        'planItemId': r.planItemId,
        'score': r.score,
        'confirmedErrors': r.confirmedErrors,
        'totalWords': r.totalWords,
        'reviewedAt': r.reviewedAt,
      };

  ReviewResult _fromMap(Map<String, dynamic> m) => ReviewResult(
        planItemId: (m['planItemId'] ?? '') as String,
        score: ((m['score'] ?? 0.0) as num).toDouble(),
        confirmedErrors: (m['confirmedErrors'] ?? 0) as int,
        totalWords: (m['totalWords'] ?? 0) as int,
        reviewedAt: (m['reviewedAt'] ?? 0) as int,
      );

  @override
  Future<void> add(ReviewResult result) => _col.add(_toMap(result));

  @override
  Future<List<ReviewResult>> getAll() async {
    final snap = await _col.get();
    return snap.docs.map((d) => _fromMap(d.data())).toList();
  }

  @override
  Future<List<ReviewResult>> forItem(String planItemId) async {
    final snap =
        await _col.where('planItemId', isEqualTo: planItemId).get();
    return snap.docs.map((d) => _fromMap(d.data())).toList();
  }
}

// --- settings: users/<uid>/settings/prefs ------------------------------------
class FirestoreSettingsRepository implements SettingsRepository {
  final String uid;
  FirestoreSettingsRepository(this.uid);

  DocumentReference<Map<String, dynamic>> get _doc =>
      _userCol(uid, 'settings').doc('prefs');

  @override
  Future<UserSettings> get() async {
    final d = await _doc.get();
    final m = d.data();
    if (m == null) return UserSettings.defaults;
    return UserSettings(
      dailyTarget: (m['dailyTarget'] ?? 10) as int,
      defaultMode: RecitationMode.values.byName(
          (m['defaultMode'] ?? 'normal') as String),
      weaknessThreshold: ((m['weaknessThreshold'] ?? 2.0) as num).toDouble(),
      masteryHorizonDays: (m['masteryHorizonDays'] ?? 30) as int,
      mergeContiguous: (m['mergeContiguous'] ?? true) as bool,
    );
  }

  @override
  Future<void> save(UserSettings s) => _doc.set({
        'dailyTarget': s.dailyTarget,
        'defaultMode': s.defaultMode.name,
        'weaknessThreshold': s.weaknessThreshold,
        'masteryHorizonDays': s.masteryHorizonDays,
        'mergeContiguous': s.mergeContiguous,
      });
}
