import 'dart:async';
import 'dart:convert';
import 'dart:io' show File, Directory, FileSystemEntity, FileSystemException;
import 'dart:isolate' show Isolate;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:url_launcher/url_launcher.dart';
import 'package:file_picker/file_picker.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:path_provider/path_provider.dart';
import 'package:pdfrx/pdfrx.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:share_plus/share_plus.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

// ───────────────────────── helpers ─────────────────────────
const kExam = Color(0xFFFF6B8A);
const kAssign = Color(0xFF5CB8FF);
const kHabit = Color(0xFF4ADE80);
const kAccent = Color(0xFF8B5CF6);

String dayKey(DateTime d) => DateFormat('yyyy-MM-dd').format(d);
DateTime dateOnly(DateTime d) => DateTime(d.year, d.month, d.day);
bool sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;
String newId() => DateTime.now().microsecondsSinceEpoch.toString();
Color typeColor(String t) => t == 'Exam' ? kExam : kAssign;
bool isDark(BuildContext c) => Theme.of(c).brightness == Brightness.dark;
Color onSurf(BuildContext c) => Theme.of(c).colorScheme.onSurface;

/// Positions creation sheets within the usable viewport while the Android keyboard
/// is visible. The supplied content stays mounted and can scroll within this bound.
Widget keyboardAwareSheet(BuildContext context, Widget child) {
  final media = MediaQuery.of(context);
  final maxHeight = (media.size.height -
          media.viewInsets.bottom -
          media.padding.top -
          24)
      .clamp(180.0, media.size.height)
      .toDouble();
  return AnimatedPadding(
    duration: const Duration(milliseconds: 220),
    curve: Curves.easeOutCubic,
    padding: EdgeInsets.only(bottom: media.viewInsets.bottom),
    child: SafeArea(
      top: true,
      bottom: false,
      child: Align(
        alignment: Alignment.bottomCenter,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: child,
          ),
        ),
      ),
    ),
  );
}

String rel(DateTime d) {
  final diff = dateOnly(d).difference(dateOnly(DateTime.now())).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  if (diff == -1) return 'Yesterday';
  if (diff > 0) return 'in $diff days';
  return '${-diff} days ago';
}

int streak(Habit h) {
  // All habits in the current data model are daily habits; `target` is the
  // number of completions required within a day, not a weekly frequency.
  final completed = h.days.toSet();
  var day = dateOnly(DateTime.now());
  if (!completed.contains(dayKey(day))) day = addDays(day, -1);
  var count = 0;
  while (completed.contains(dayKey(day))) {
    count++;
    day = addDays(day, -1);
  }
  return count;
}

// ───────────────────────── shared interface icon system ─────────────────────────
/// Stable icon keys are stored in the existing Habit JSON `emoji` field so
/// previously saved habits remain readable without a data migration.
const Map<String, Map<String, IconData>> habitIconGroups = {
  'Health & Fitness': {
    'Water': Icons.water_drop_rounded,
    'Exercise': Icons.fitness_center_rounded,
    'Running': Icons.directions_run_rounded,
    'Gym': Icons.sports_gymnastics_rounded,
    'Yoga': Icons.self_improvement_rounded,
    'Meditation': Icons.spa_rounded,
    'Sleep': Icons.bedtime_rounded,
    'Walking': Icons.directions_walk_rounded,
    'Nutrition': Icons.restaurant_rounded,
    'Cycling': Icons.directions_bike_rounded,
  },
  'Learning & Productivity': {
    'Reading': Icons.menu_book_rounded,
    'Studying': Icons.school_rounded,
    'Coding': Icons.code_rounded,
    'Writing': Icons.edit_note_rounded,
    'Journaling': Icons.bookmark_added_rounded,
    'Research': Icons.travel_explore_rounded,
    'Language learning': Icons.translate_rounded,
    'Goal setting': Icons.flag_rounded,
    'Time management': Icons.schedule_rounded,
  },
  'Lifestyle & Personal Growth': {
    'Morning routine': Icons.wb_sunny_rounded,
    'Evening routine': Icons.nights_stay_rounded,
    'Skincare': Icons.face_retouching_natural_rounded,
    'Cleaning': Icons.cleaning_services_rounded,
    'Music': Icons.music_note_rounded,
    'Gardening': Icons.yard_rounded,
    'Saving money': Icons.savings_rounded,
    'Digital detox': Icons.phonelink_off_rounded,
    'Mindfulness': Icons.spa_outlined,
  },
};

String habitIconKey(String label) => label.toLowerCase().replaceAll(' ', '_');

IconData habitIconData(String key) {
  for (final group in habitIconGroups.values) {
    for (final entry in group.entries) {
      if (habitIconKey(entry.key) == key) return entry.value;
    }
  }
  // Legacy emoji values are normalized when Habit.fromJson reads old saves.
  return Icons.water_drop_rounded;
}

String legacyHabitIconKey(dynamic value) {
  const legacy = {
    '💧': 'water', '📚': 'reading', '🏃': 'running', '🧘': 'yoga',
    '💪': 'exercise', '🥗': 'nutrition', '😴': 'sleep', '✍️': 'writing',
    '🎧': 'music', '🧹': 'cleaning', '💻': 'coding', '🙏': 'meditation',
    '✨': 'mindfulness',
  };
  final raw = value?.toString() ?? 'water';
  if (legacy.containsKey(raw)) return legacy[raw]!;
  for (final group in habitIconGroups.values) {
    for (final label in group.keys) {
      if (habitIconKey(label) == raw) return raw;
    }
  }
  return raw;
}

// ───────────────────────── models ─────────────────────────
class Assignment {
  String id, title, subject, type;
  DateTime date;
  bool done;
  Assignment({
    required this.id,
    required this.title,
    required this.subject,
    required this.type,
    required this.date,
    this.done = false,
  });
  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'subject': subject,
        'type': type,
        'date': date.millisecondsSinceEpoch,
        'done': done,
      };
  factory Assignment.fromJson(Map<String, dynamic> j) => Assignment(
        id: j['id'],
        title: j['title'],
        subject: j['subject'] ?? '',
        type: j['type'] ?? 'Assignment',
        date: DateTime.fromMillisecondsSinceEpoch(j['date']),
        done: j['done'] ?? false,
      );
}

class Habit {
  String id, name, iconKey;
  String? created;
  int target;
  Map<String, int> progress;
  List<String> days;
  Habit({
    required this.id,
    required this.name,
    required this.iconKey,
    List<String>? days,
    this.created,
    this.target = 1,
    Map<String, int>? progress,
  })  : days = days ?? [],
        progress = progress ?? {};
  Map<String, dynamic> toJson() =>
      {'id': id, 'name': name, 'emoji': iconKey, 'days': days, 'created': created, 'target': target, 'progress': progress};
  factory Habit.fromJson(Map<String, dynamic> j) {
    final d = List<String>.from(j['days'] ?? []);
    final earliest = d.isEmpty ? null : (List<String>.from(d)..sort()).first;
    return Habit(
      id: j['id'],
      name: j['name'],
      iconKey: legacyHabitIconKey(j['emoji']),
      days: d,
      created: j['created'] ?? earliest,
      target: ((j['target'] is int ? j['target'] as int : 1) > 0)
          ? (j['target'] is int ? j['target'] as int : 1)
          : 1,
      progress: Map<String, int>.from(j['progress'] ?? {}),
    );
  }
}

// ───────────────────────── store ─────────────────────────
enum HabitToggleResult { completed, undone, partial, unchanged, failed }

class Store extends ChangeNotifier {
  List<Assignment> assignments = [];
  List<Habit> habits = [];
  ThemeMode mode = ThemeMode.dark;
  Map<String, String> attendance = {};
  int thGreen = 85, thYellow = 75;
  List<Notif> inbox = [];
  List<Notif> plan = [];
  Map<String, bool> nOn = {'habit': true, 'assignment': true, 'exam': true, 'attendance': true};
  Map<String, int> nTime = {'habit': 1200, 'assignment': 540, 'exam': 480, 'attendance': 510};
  bool permAsked = false;
  List<QuickLink> links = [];
  bool swipeActions = true;
  bool compactHabitView = false;
  List<LibDoc> pdfs = [];
  int pdfScanAt = 0;
  String pdfSort = 'modNew';
  String pdfBg = 'white'; // white | sepia | blue | black
  double pdfBright = 1.0;
  bool pdfKeepOn = false, pdfHoriz = false, pdfPaged = false;
  // 'focus' and 'short' are held in seconds
  Map<String, int> pomoCfg = {'focus': 1500, 'short': 300, 'cycles': 3};
  bool pomoSound = true;
  bool pomoNotify = true;
  String? pomoSoundPath, pomoSoundName;
  String pomoDate = '';
  int pomoCycles = 0, pomoBreaks = 0, pomoFocusSec = 0;
  SharedPreferences? _p;

  Future<void> load() async {
    _p = await SharedPreferences.getInstance();
    try {
      final a = _p!.getString('assignments');
      final h = _p!.getString('habits');
      if (a != null) {
        assignments = (jsonDecode(a) as List)
            .map((e) => Assignment.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      if (h != null) {
        habits = (jsonDecode(h) as List)
            .map((e) => Habit.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      mode = _p!.getString('mode') == 'light' ? ThemeMode.light : ThemeMode.dark;
      final att = _p!.getString('attendance');
      if (att != null) {
        attendance = Map<String, String>.from(jsonDecode(att) as Map);
      }
      thGreen = _p!.getInt('thGreen') ?? 85;
      thYellow = _p!.getInt('thYellow') ?? 75;
      final ib = _p!.getString('inbox');
      if (ib != null) {
        inbox = (jsonDecode(ib) as List)
            .map((e) => Notif.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final pl = _p!.getString('plan');
      if (pl != null) {
        plan = (jsonDecode(pl) as List)
            .map((e) => Notif.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final no = _p!.getString('nOn');
      if (no != null) nOn = {...nOn, ...Map<String, bool>.from(jsonDecode(no) as Map)};
      final nt = _p!.getString('nTime');
      if (nt != null) nTime = {...nTime, ...Map<String, int>.from(jsonDecode(nt) as Map)};
      permAsked = _p!.getBool('permAsked') ?? false;
      for (final h in habits) {
        h.created ??= dayKey(DateTime.now());
      }
      final ql = _p!.getString('links');
      if (ql != null) {
        links = (jsonDecode(ql) as List)
            .map((e) => QuickLink.fromJson(Map<String, dynamic>.from(e)))
            .toList();
      }
      final pc = _p!.getString('pomoCfg');
      if (pc != null) {
        final m = Map<String, int>.from(jsonDecode(pc) as Map);
        // older versions saved whole minutes under 'focus' / 'short'
        final focusSec = m['focusSec'] ?? (m['focus'] ?? 25) * 60;
        final shortSec = m['shortSec'] ?? (m['short'] ?? 5) * 60;
        pomoCfg = {
          'focus': focusSec.clamp(1, 59940).toInt(),
          'short': shortSec.clamp(1, 59940).toInt(),
          'cycles': (m['cycles'] ?? 3).clamp(3, 12).toInt(),
        };
      }
      pomoSound = _p!.getBool('pomoSound') ?? true;
      pomoNotify = _p!.getBool('pomoNotify') ?? true;
      swipeActions = _p!.getBool('swipeActions') ?? true;
      compactHabitView = _p!.getBool('compactHabitView') ?? false;
      final pi = _p!.getString('pdfIndex');
      if (pi != null) {
        pdfs = (jsonDecode(pi) as List)
            .map((e) => LibDoc.fromJson(Map<String, dynamic>.from(e)))
            .toList();
        final pm = _p!.getString('pdfMeta');
        if (pm != null) {
          final meta = Map<String, dynamic>.from(jsonDecode(pm) as Map);
          for (final d in pdfs) {
            final m = meta[d.path];
            if (m is Map) {
              d.fav = m['f'] == 1;
              d.lastPage = (m['l'] ?? 0) as int;
              d.pageCount = (m['c'] ?? 0) as int;
            }
          }
        }
      }
      pdfScanAt = _p!.getInt('pdfScanAt') ?? 0;
      pdfSort = _p!.getString('pdfSort') ?? 'modNew';
      pdfBg = _p!.getString('pdfBg') ?? 'white';
      pdfBright = _p!.getDouble('pdfBright') ?? 1.0;
      pdfKeepOn = _p!.getBool('pdfKeepOn') ?? false;
      pdfHoriz = _p!.getBool('pdfHoriz') ?? false;
      pdfPaged = _p!.getBool('pdfPaged') ?? false;
      pomoSoundPath = _p!.getString('pomoSoundPath');
      pomoSoundName = _p!.getString('pomoSoundName');
      final pd = _p!.getString('pomoDay');
      if (pd != null) {
        final m = Map<String, dynamic>.from(jsonDecode(pd) as Map);
        pomoDate = m['date'] ?? '';
        pomoCycles = m['cycles'] ?? 0;
        pomoBreaks = m['breaks'] ?? 0;
        pomoFocusSec = m['focusSec'] ?? 0;
      }
      rollPomoDay();
    } catch (_) {}
  }

  void _save() {
    _p?.setString('assignments', jsonEncode(assignments.map((e) => e.toJson()).toList()));
    _p?.setString('habits', jsonEncode(habits.map((e) => e.toJson()).toList()));
    _p?.setString('mode', mode == ThemeMode.light ? 'light' : 'dark');
    _p?.setString('attendance', jsonEncode(attendance));
    _p?.setInt('thGreen', thGreen);
    _p?.setInt('thYellow', thYellow);
    _p?.setString('nOn', jsonEncode(nOn));
    _p?.setString('nTime', jsonEncode(nTime));
    _p?.setBool('swipeActions', swipeActions);
    _p?.setBool('compactHabitView', compactHabitView);
    _p?.setString('links', jsonEncode(links.map((e) => e.toJson()).toList()));
    notifyListeners();
    notifier.requestSync();
  }

  List<Assignment> get sorted =>
      [...assignments]..sort((a, b) => a.date.compareTo(b.date));

  List<Assignment> get upcoming {
    final t = dateOnly(DateTime.now());
    return sorted.where((a) => !a.done && !dateOnly(a.date).isBefore(t)).toList();
  }

  void setAttendance(DateTime d, String? status) {
    final k = dayKey(d);
    if (status == null) {
      attendance.remove(k);
    } else {
      attendance[k] = status;
    }
    _save();
  }

  void setThresholds(int green, int yellow) {
    thGreen = green;
    thYellow = yellow;
    _save();
  }

  int get unread => inbox.where((n) => !n.read).length;

  /// Persists the notification inbox and plan without triggering a re-sync.
  void saveNotifs() {
    _p?.setString('inbox', jsonEncode(inbox.map((e) => e.toJson()).toList()));
    _p?.setString('plan', jsonEncode(plan.map((e) => e.toJson()).toList()));
    _p?.setBool('permAsked', permAsked);
    notifyListeners();
  }

  void markRead(String key) {
    for (final n in inbox) {
      if (n.key == key) n.read = true;
    }
    saveNotifs();
  }

  void markAllRead() {
    for (final n in inbox) {
      n.read = true;
    }
    saveNotifs();
  }

  void deleteNotif(String key) {
    inbox.removeWhere((n) => n.key == key);
    saveNotifs();
  }

  void setNotifOn(String cat, bool v) {
    nOn[cat] = v;
    _save();
  }

  void setNotifTime(String cat, int minutes) {
    nTime[cat] = minutes;
    _save();
  }

  void toggleMode() {
    mode = mode == ThemeMode.dark ? ThemeMode.light : ThemeMode.dark;
    _save();
  }

  void addAssignment(Assignment a) {
    assignments.add(a);
    _save();
  }

  void updateAssignment(Assignment a) => _save();

  void deleteAssignment(String id) {
    assignments.removeWhere((a) => a.id == id);
    _save();
  }

  void addHabit(Habit h) {
    habits.add(h);
    _save();
  }

  /// Today's Pomodoro counters reset when the local calendar date changes.
  void rollPomoDay() {
    final t = dayKey(DateTime.now());
    if (pomoDate != t) {
      pomoDate = t;
      pomoCycles = 0;
      pomoBreaks = 0;
      pomoFocusSec = 0;
    }
  }

  void savePomo() {
    _p?.setString(
        'pomoCfg',
        jsonEncode({
          'focusSec': pomoCfg['focus'],
          'shortSec': pomoCfg['short'],
          'cycles': pomoCfg['cycles'],
        }));
    _p?.setBool('pomoSound', pomoSound);
    _p?.setBool('pomoNotify', pomoNotify);
    if (pomoSoundPath == null) {
      _p?.remove('pomoSoundPath');
      _p?.remove('pomoSoundName');
    } else {
      _p?.setString('pomoSoundPath', pomoSoundPath!);
      _p?.setString('pomoSoundName', pomoSoundName ?? 'Custom sound');
    }
    _p?.setString(
        'pomoDay',
        jsonEncode({
          'date': pomoDate,
          'cycles': pomoCycles,
          'breaks': pomoBreaks,
          'focusSec': pomoFocusSec,
        }));
    notifyListeners();
  }

  void setPomo(String key, int v) {
    pomoCfg[key] = v;
    savePomo();
  }

  void resetPomoConfig() {
    pomoCfg = {'focus': 1500, 'short': 300, 'cycles': 3};
    savePomo();
  }

  void setPomoSound(String path, String name) {
    pomoSoundPath = path;
    pomoSoundName = name;
    savePomo();
  }

  void clearPomoSound() {
    pomoSoundPath = null;
    pomoSoundName = null;
    savePomo();
  }

  void togglePomoNotify() {
    pomoNotify = !pomoNotify;
    savePomo();
  }

  void togglePomoSound() {
    pomoSound = !pomoSound;
    savePomo();
  }

  void addPomoFocus(int seconds) {
    rollPomoDay();
    pomoCycles++;
    pomoFocusSec += seconds;
    savePomo();
  }

  void addPomoBreak() {
    rollPomoDay();
    pomoBreaks++;
    savePomo();
  }

  void addLink(QuickLink l) {
    links.add(l);
    _save();
  }

  void updateLink(QuickLink l) => _save();

  void deleteLink(String id) {
    links.removeWhere((l) => l.id == id);
    _save();
  }

  // ── PDF library ──
  void savePdfIndex() {
    _p?.setString('pdfIndex', jsonEncode(pdfs.map((e) => e.toJson()).toList()));
    _p?.setInt('pdfScanAt', pdfScanAt);
    notifyListeners();
  }

  void savePdfMeta({bool notify = true}) {
    final meta = <String, Map<String, int>>{};
    for (final d in pdfs) {
      if (d.fav || d.lastPage > 0 || d.pageCount > 0) {
        meta[d.path] = {'f': d.fav ? 1 : 0, 'l': d.lastPage, 'c': d.pageCount};
      }
    }
    _p?.setString('pdfMeta', jsonEncode(meta));
    if (notify) notifyListeners();
  }

  void setPdfIndex(List<LibDoc> next) {
    pdfs = next;
    pdfScanAt = DateTime.now().millisecondsSinceEpoch;
    savePdfMeta(notify: false);
    savePdfIndex();
  }

  /// Drops entries whose file no longer exists. Cheap: one stat per entry.
  void pruneMissingPdfs() {
    final before = pdfs.length;
    pdfs.removeWhere((d) => !File(d.path).existsSync());
    if (pdfs.length != before) {
      savePdfMeta(notify: false);
      savePdfIndex();
    }
  }

  void removePdf(String path) {
    pdfs.removeWhere((d) => d.path == path);
    savePdfMeta(notify: false);
    savePdfIndex();
  }

  void togglePdfFav(LibDoc d) {
    d.fav = !d.fav;
    savePdfMeta();
  }

  void renamePdf(LibDoc d, String newPath) {
    d.path = newPath;
    savePdfMeta(notify: false);
    savePdfIndex();
  }

  void setPdfPage(LibDoc d, int page, {int? count}) {
    d.lastPage = page;
    if (count != null) d.pageCount = count;
    savePdfMeta(notify: false);
  }

  void setPdfSort(String v) {
    pdfSort = v;
    _p?.setString('pdfSort', v);
    notifyListeners();
  }

  void savePdfPrefs() {
    _p?.setString('pdfBg', pdfBg);
    _p?.setDouble('pdfBright', pdfBright);
    _p?.setBool('pdfKeepOn', pdfKeepOn);
    _p?.setBool('pdfHoriz', pdfHoriz);
    _p?.setBool('pdfPaged', pdfPaged);
    notifyListeners();
  }

  void toggleSwipe() {
    swipeActions = !swipeActions;
    _save();
  }

  void updateHabit(Habit h) => _save();

  void setCompactHabitView(bool value) {
    if (compactHabitView == value) return;
    compactHabitView = value;
    _p?.setBool('compactHabitView', value);
    notifyListeners();
  }

  void reorderHabits(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final h = habits.removeAt(oldIndex);
    habits.insert(newIndex, h);
    _save();
  }

  void deleteHabit(String id) {
    habits.removeWhere((h) => h.id == id);
    _save();
  }

  final Map<String, int> _lastHabitToggleAt = {};

  /// Applies one daily progress step and reports the persisted state change.
  /// A short per-habit/day guard prevents accidental duplicate taps.
  Future<HabitToggleResult> toggleHabit(Habit h, DateTime day) async {
    final k = dayKey(day);
    final guardKey = '${h.id}|$k';
    final now = DateTime.now().microsecondsSinceEpoch;
    final previous = _lastHabitToggleAt[guardKey] ?? 0;
    if (now - previous < 250000) return HabitToggleResult.unchanged;
    _lastHabitToggleAt[guardKey] = now;
    final wasCompleted = h.days.contains(k);
    final oldDays = List<String>.from(h.days);
    final oldProgress = Map<String, int>.from(h.progress);
    var result = HabitToggleResult.partial;
    if (wasCompleted) {
      h.days.remove(k);
      h.progress.remove(k);
      result = HabitToggleResult.undone;
    } else {
      final target = h.target > 0 ? h.target : 1;
      final c = (h.progress[k] ?? 0) + 1;
      if (c >= target) {
        h.progress.remove(k);
        if (!h.days.contains(k)) h.days.add(k);
        result = HabitToggleResult.completed;
      } else {
        h.progress[k] = c;
      }
    }
    // Persist before sending haptic confirmation. Roll back in-memory state if
    // the preference write fails so the UI and stored record cannot diverge.
    try {
      final encoded = jsonEncode(habits.map((item) => item.toJson()).toList());
      final saved = _p == null ? true : await _p!.setString('habits', encoded);
      if (!saved) {
        h.days = oldDays;
        h.progress = oldProgress;
        return HabitToggleResult.failed;
      }
    } catch (_) {
      h.days = oldDays;
      h.progress = oldProgress;
      return HabitToggleResult.failed;
    }
    notifyListeners();
    notifier.requestSync();
    return result;
  }

  /// Sets a historical calendar date to an explicit completed/incomplete state.
  /// Unlike toggleHabit, this is idempotent and does not increment partial targets.
  void setHabitDay(Habit habit, DateTime day, bool completed) {
    Habit? current;
    for (final item in habits) {
      if (item.id == habit.id) { current = item; break; }
    }
    if (current == null) return;
    final key = dayKey(day);
    if (completed) {
      if (!current.days.contains(key)) current.days.add(key);
      current.progress.remove(key);
    } else {
      current.days.remove(key);
      current.progress.remove(key);
    }
    current.days.sort();
    _save();
  }
}

final store = Store();

// ───────────────────────── app ─────────────────────────
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  pdfrxFlutterInitialize();
  await store.load();
  runApp(const StudyFlowApp());
  WidgetsBinding.instance.addObserver(_LifecycleSync());
  notifier.init();
}

class _LifecycleSync with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      pomodoro.onResume();
      notifier.refreshPermission().then((_) => notifier.requestSync());
    } else if (state == AppLifecycleState.paused) {
      pomodoro.onBackground();
    }
  }
}

ThemeData buildTheme(Brightness b) => ThemeData(
      useMaterial3: true,
      brightness: b,
      pageTransitionsTheme: PageTransitionsTheme(builders: {
        for (final p in TargetPlatform.values) p: const _DriftTransitions(),
      }),
      colorScheme: ColorScheme.fromSeed(seedColor: kAccent, brightness: b),
      dialogBackgroundColor: b == Brightness.dark ? const Color(0xFF1B1636) : Colors.white,
    );

class StudyFlowApp extends StatelessWidget {
  const StudyFlowApp({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (_, __) => MaterialApp(
        navigatorKey: navKey,
        title: 'StudyFlow',
        debugShowCheckedModeBanner: false,
        themeMode: store.mode,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        home: const Shell(),
      ),
    );
  }
}

// ───────────────────────── glass widgets ─────────────────────────
class Glass extends StatefulWidget {
  final Widget child;
  final EdgeInsets padding;
  final double radius;
  final VoidCallback? onTap;
  final double? opacity;
  const Glass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.radius = 24,
    this.onTap,
    this.opacity,
  });

  @override
  State<Glass> createState() => _GlassState();
}

class _GlassState extends State<Glass> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    final o = widget.opacity ?? (d ? 0.10 : 0.65);
    final r = BorderRadius.circular(widget.radius);
    final box = RepaintBoundary(
      child: ClipRRect(
        borderRadius: r,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: widget.padding,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Colors.white.withOpacity(o), Colors.white.withOpacity(o * 0.45)],
              ),
              borderRadius: r,
              border: Border.all(color: Colors.white.withOpacity(d ? 0.16 : 0.85)),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
    if (widget.onTap == null) return box;
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: box,
      ),
    );
  }
}

class Orb extends StatelessWidget {
  final Color color;
  final double size;
  const Orb(this.color, this.size, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: [color, color.withOpacity(0)]),
        ),
      );
}

class Background extends StatelessWidget {
  const Background({super.key});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    return Stack(fit: StackFit.expand, children: [
      AnimatedContainer(
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: d
                ? const [Color(0xFF0A0A18), Color(0xFF15102E), Color(0xFF0B1426)]
                : const [Color(0xFFEDE9FE), Color(0xFFE0ECFF), Color(0xFFFCE7F3)],
          ),
        ),
      ),
      Positioned(top: -90, left: -80, child: Orb(kAccent.withOpacity(d ? 0.55 : 0.40), 320)),
      Positioned(top: 260, right: -140, child: Orb(const Color(0xFF22D3EE).withOpacity(d ? 0.35 : 0.30), 360)),
      Positioned(bottom: -120, left: -60, child: Orb(const Color(0xFFEC4899).withOpacity(d ? 0.35 : 0.28), 340)),
    ]);
  }
}

class GlassIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  const GlassIconBtn(this.icon, this.onTap, {super.key, this.color});
  @override
  Widget build(BuildContext context) => Glass(
        radius: 16,
        padding: const EdgeInsets.all(11),
        onTap: onTap,
        child: Icon(icon, size: 22, color: color ?? onSurf(context)),
      );
}

class PageHeader extends StatelessWidget {
  final String title, subtitle;
  final Widget? action;
  const PageHeader({super.key, required this.title, required this.subtitle, this.action});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(children: [
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 2),
              Text(subtitle, style: TextStyle(fontSize: 13.5, color: on.withOpacity(0.6))),
            ]),
          ),
        ),
        const SizedBox(width: 8),
        if (action != null) ...[action!, const SizedBox(width: 8)],
        const NotificationBell(),
        const SizedBox(width: 8),
        GlassIconBtn(
          isDark(context) ? Icons.light_mode_rounded : Icons.dark_mode_rounded,
          store.toggleMode,
        ),
      ]),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(22, 10, 20, 12),
        child: Row(children: [
          Expanded(
            child: Text(text,
                style: TextStyle(
                    fontSize: 18, fontWeight: FontWeight.w700, color: onSurf(context))),
          ),
          if (trailing != null) trailing!,
        ]),
      );
}

class EmptyCard extends StatelessWidget {
  final IconData icon;
  final String text;
  const EmptyCard(this.icon, this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        child: Glass(
          padding: const EdgeInsets.symmetric(vertical: 26, horizontal: 20),
          child: SizedBox(
            width: double.infinity,
            child: Column(children: [
              Icon(icon, size: 34, color: kAccent),
              const SizedBox(height: 8),
              Text(text,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: onSurf(context).withOpacity(0.65))),
            ]),
          ),
        ),
      );
}

class Pill extends StatelessWidget {
  final String text;
  final Color color;
  const Pill(this.text, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
        decoration: BoxDecoration(
          color: color.withOpacity(0.2),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: color)),
      );
}

Future<bool> confirmDelete(BuildContext c, String what) async {
  final r = await showDialog<bool>(
    context: c,
    builder: (x) => AlertDialog(
      title: const Text('Delete?'),
      content: Text('Delete "$what"? This cannot be undone.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Cancel')),
        TextButton(onPressed: () => Navigator.pop(x, true), child: const Text('Delete')),
      ],
    ),
  );
  return r ?? false;
}

InputDecoration deco(BuildContext c, String label) => InputDecoration(
      labelText: label,
      filled: true,
      fillColor: onSurf(c).withOpacity(0.07),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(16),
        borderSide: BorderSide.none,
      ),
    );

// ───────────────────────── shell ─────────────────────────
final navIndex = ValueNotifier<int>(0);

class Shell extends StatelessWidget {
  const Shell({super.key});
  @override
  Widget build(BuildContext context) {
    final d = isDark(context);
    const pages = [DashboardPage(), AssignmentsPage(), CalendarPage(), AttendancePage()];
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: (d ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(statusBarColor: Colors.transparent),
      child: Stack(children: [
        const Positioned.fill(child: Background()),
        Scaffold(
          extendBody: true,
          backgroundColor: Colors.transparent,
          body: SafeArea(
            bottom: false,
            child: ValueListenableBuilder<int>(
              valueListenable: navIndex,
              builder: (c, idx, _) => AnimatedPage(index: idx, pages: pages),
            ),
          ),
          bottomNavigationBar: SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: ValueListenableBuilder<int>(
                valueListenable: navIndex,
                builder: (c, idx, _) =>
                    NavBar(idx: idx, onTap: (i) => navIndex.value = i),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

class NavBar extends StatelessWidget {
  final int idx;
  final ValueChanged<int> onTap;
  const NavBar({super.key, required this.idx, required this.onTap});
  @override
  Widget build(BuildContext context) {
    const icons = [
      Icons.dashboard_rounded,
      Icons.assignment_rounded,
      Icons.calendar_month_rounded,
      Icons.how_to_reg_rounded,
    ];
    const labels = ['Dashboard', 'Assignments', 'Calendar', 'Attendance'];
    final on = onSurf(context);
    return Glass(
      radius: 28,
      padding: const EdgeInsets.all(6),
      opacity: isDark(context) ? 0.12 : 0.75,
      child: Row(
        children: List.generate(4, (i) {
          final sel = i == idx;
          return Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => onTap(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 280),
                curve: Curves.easeOutCubic,
                padding: const EdgeInsets.symmetric(vertical: 10),
                decoration: BoxDecoration(
                  color: sel ? kAccent.withOpacity(0.28) : Colors.transparent,
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedScale(
                    scale: sel ? 1.15 : 1,
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutBack,
                    child: Icon(icons[i], color: sel ? kAccent : on.withOpacity(0.55)),
                  ),
                  const SizedBox(height: 2),
                  Text(labels[i],
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                        color: sel ? kAccent : on.withOpacity(0.55),
                      )),
                ]),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ───────────────────────── dashboard ─────────────────────────
class StatCard extends StatelessWidget {
  final String value, label;
  final Color color;
  const StatCard(this.value, this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Glass(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 14),
        child: SizedBox(
          width: double.infinity,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(value, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: color)),
            const SizedBox(height: 2),
            Text(label,
                style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.65))),
          ]),
        ),
      );
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final today = DateTime.now();
        final up = store.upcoming;
        final exams = up.where((a) => a.type == 'Exam').length;
        return RevealList(
          page: 'dash',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Dashboard',
              subtitle: DateFormat('EEEE, d MMMM').format(today),
              action: GlassIconBtn(
                Icons.grid_view_rounded,
                () => openScreen(c, const ToolsHubPage()),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: HabitsTodayCard(),
            ),
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(children: [
                Expanded(child: StatCard('$exams', 'Upcoming exams', kExam)),
                const SizedBox(width: 10),
                Expanded(child: StatCard('${up.length - exams}', 'Assignments due', kAssign)),
              ]),
            ),
            const SizedBox(height: 14),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: AttendanceSummary(),
            ),
            const SizedBox(height: 6),
            const SectionTitle('Coming up'),
            if (up.isEmpty)
              const EmptyCard(Icons.coffee_rounded, 'Nothing due. Enjoy the free time!')
            else
              ...up.take(3).map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
          ],
        );
      },
    );
  }
}

class HabitCompletionButton extends StatelessWidget {
  final Habit habit;
  final double size;
  const HabitCompletionButton({super.key, required this.habit, this.size = 42});

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final today = dateOnly(DateTime.now());
          final done = habit.days.contains(dayKey(today));
          return Semantics(
            button: true,
            label: done ? 'Mark ${habit.name} incomplete' : 'Complete ${habit.name}',
            child: Material(
              color: Colors.transparent,
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () async {
                  final result = await store.toggleHabit(habit, today);
                  if (!context.mounted) return;
                  if (result == HabitToggleResult.completed) {
                    HapticFeedback.lightImpact();
                  } else if (result == HabitToggleResult.undone) {
                    HapticFeedback.selectionClick();
                  }
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: done ? kHabit : const Color(0xFF123B2A),
                    border: Border.all(color: done ? kHabit : const Color(0xFF3E9B68), width: 1.4),
                  ),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, animation) => ScaleTransition(
                      scale: animation,
                      child: FadeTransition(opacity: animation, child: child),
                    ),
                    child: done
                        ? Icon(Icons.check_rounded, key: const ValueKey('done'), size: size * 0.52, color: Colors.white)
                        : Icon(Icons.add_rounded, key: const ValueKey('add'), size: size * 0.58, color: const Color(0xFF8CF0B1)),
                  ),
                ),
              ),
            ),
          );
        },
      );
}

class _HabitStreakLine extends StatelessWidget {
  final int value;
  final Color color;
  final double fontSize;
  const _HabitStreakLine({required this.value, required this.color, required this.fontSize});

  @override
  Widget build(BuildContext context) => Row(children: [
    Icon(Icons.local_fire_department_rounded, size: 14, color: value > 0 ? kWarn : color.withOpacity(0.65)),
    const SizedBox(width: 3),
    Expanded(child: Text(
      value > 0 ? '$value day streak' : 'Start your streak today',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(fontSize: fontSize, color: color),
    )),
  ]);
}

class HabitTile extends StatelessWidget {
  final Habit h;
  const HabitTile({super.key, required this.h});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final s = streak(h);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: SizedBox(
        height: 148,
        child: Glass(
          padding: const EdgeInsets.all(14),
          onTap: () => openHabitDetailPage(context, h),
          child: Row(children: [
            Container(
              width: 50, height: 50, alignment: Alignment.center,
              decoration: BoxDecoration(
                color: kHabit.withOpacity(0.18),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Icon(habitIconData(h.iconKey), size: 24, color: kHabit),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(h.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on)),
                  const SizedBox(height: 5),
                  HabitProgressBar(habit: h),
                  const SizedBox(height: 5),
                  _HabitStreakLine(value: s, color: on.withOpacity(0.6), fontSize: 11.5),
                ],
              ),
            ),
            const SizedBox(width: 10),
            HabitCompletionButton(habit: h, size: 40),
          ]),
        ),
      ),
    );
  }
}

Future<void> showHabitSheet(BuildContext context, {Habit? habit}) {
  final name = TextEditingController(text: habit?.name ?? '');
  String iconKey = habit?.iconKey ?? 'water';
  String query = '';
  int target = habit?.target ?? 1;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);
      final filteredGroups = <String, Map<String, IconData>>{};
      for (final group in habitIconGroups.entries) {
        final matches = Map<String, IconData>.fromEntries(group.value.entries.where(
          (e) => e.key.toLowerCase().contains(query.trim().toLowerCase()),
        ));
        if (matches.isNotEmpty) filteredGroups[group.key] = matches;
      }
      return keyboardAwareSheet(
        ctx,
        Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(habit == null ? 'New habit' : 'Edit habit',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 16),
              TextField(controller: name, decoration: deco(ctx, 'Habit name (e.g. Drink water)')),
              const SizedBox(height: 14),
              TextField(
                onChanged: (v) => set(() => query = v),
                decoration: deco(ctx, 'Search habit icons').copyWith(
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
              const SizedBox(height: 14),
              for (final group in filteredGroups.entries) ...[
                Padding(
                  padding: const EdgeInsets.only(bottom: 9, top: 3),
                  child: Text(group.key,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800, color: on.withOpacity(0.72))),
                ),
                Wrap(
                  spacing: 9,
                  runSpacing: 9,
                  children: group.value.entries.map((entry) {
                    final key = habitIconKey(entry.key);
                    final selected = key == iconKey;
                    return Tooltip(
                      message: entry.key,
                      child: Semantics(
                        button: true,
                        selected: selected,
                        label: entry.key,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(14),
                          onTap: () => set(() => iconKey = key),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 160),
                            width: 48,
                            height: 48,
                            decoration: BoxDecoration(
                              color: selected ? kAccent.withOpacity(0.24) : on.withOpacity(0.07),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(color: selected ? kAccent : on.withOpacity(0.08), width: selected ? 2 : 1),
                            ),
                            child: Icon(entry.value, size: 23, color: selected ? kAccent : on.withOpacity(0.82)),
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 14),
              ],
              if (filteredGroups.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(child: Text('No matching icons', style: TextStyle(color: on.withOpacity(0.6)))),
                ),
              const Divider(height: 20),
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Daily target',
                        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700, color: on)),
                    Text(
                      target == 1 ? 'Complete once a day' : 'Complete $target times to finish the day',
                      style: TextStyle(fontSize: 12, color: on.withOpacity(0.6)),
                    ),
                  ]),
                ),
                IconButton.filledTonal(
                  onPressed: target > 1 ? () => set(() => target--) : null,
                  icon: const Icon(Icons.remove_rounded),
                ),
                SizedBox(
                  width: 38,
                  child: Center(child: Text('$target',
                      style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on))),
                ),
                IconButton.filledTonal(
                  onPressed: target < 20 ? () => set(() => target++) : null,
                  icon: const Icon(Icons.add_rounded),
                ),
              ]),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(backgroundColor: kAccent, padding: const EdgeInsets.symmetric(vertical: 15)),
                  onPressed: () {
                    if (name.text.trim().isEmpty) return;
                    if (habit == null) {
                      store.addHabit(Habit(
                        id: newId(), name: name.text.trim(), iconKey: iconKey,
                        target: target, created: dayKey(DateTime.now()),
                      ));
                    } else {
                      habit.name = name.text.trim();
                      habit.iconKey = iconKey;
                      habit.target = target;
                      final promote = habit.progress.entries
                          .where((e) => e.value >= target).map((e) => e.key).toList();
                      for (final k in promote) {
                        habit.progress.remove(k);
                        if (!habit.days.contains(k)) habit.days.add(k);
                      }
                      store.updateHabit(habit);
                    }
                    Navigator.pop(ctx);
                  },
                  child: Text(habit == null ? 'Add habit' : 'Save changes', style: const TextStyle(fontSize: 16)),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

// ───────────────────────── assignments ─────────────────────────
class AssignmentTile extends StatelessWidget {
  final Assignment a;
  final bool swipe;
  const AssignmentTile({super.key, required this.a, this.swipe = false});

  @override
  Widget build(BuildContext context) {
    final card = _card(context);
    if (!swipe) return card;
    return Dismissible(
      key: ValueKey('swipe_${a.id}'),
      direction: DismissDirection.horizontal,
      dismissThresholds: const {
        DismissDirection.startToEnd: 0.35,
        DismissDirection.endToStart: 0.35,
      },
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          // swipe right: toggle done, the card stays in place
          HapticFeedback.selectionClick();
          a.done = !a.done;
          store.updateAssignment(a);
          return false;
        }
        return true;
      },
      onDismissed: (_) => store.deleteAssignment(a.id),
      background: Container(
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 26),
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        decoration: BoxDecoration(
          color: kHabit.withOpacity(0.22),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Icon(a.done ? Icons.undo_rounded : Icons.check_rounded, color: kHabit),
      ),
      secondaryBackground: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 26),
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
        decoration: BoxDecoration(
          color: kBad.withOpacity(0.22),
          borderRadius: BorderRadius.circular(24),
        ),
        child: const Icon(Icons.delete_outline_rounded, color: kBad),
      ),
      child: card,
    );
  }

  Widget _card(BuildContext context) {
    final on = onSurf(context);
    final c = typeColor(a.type);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Glass(
        padding: const EdgeInsets.fromLTRB(14, 12, 6, 12),
        onTap: () => showAssignmentDetails(context, a),
        child: Row(children: [
          Container(
            width: 54,
            height: 58,
            decoration: BoxDecoration(
              color: c.withOpacity(0.18),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(DateFormat('d').format(a.date),
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: c)),
              Text(DateFormat('MMM').format(a.date).toUpperCase(),
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: c)),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                maxLines: null,
                overflow: TextOverflow.visible,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: on.withOpacity(a.done ? 0.5 : 1),
                  decoration: a.done ? TextDecoration.lineThrough : null,
                ),
                child: Text(a.title),
              ),
              if (a.subject.isNotEmpty)
                Text(a.subject,
                    softWrap: true,
                    style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
              const SizedBox(height: 6),
              Row(children: [
                Pill(a.type, c),
                const SizedBox(width: 8),
                Text(rel(a.date), style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
              ]),
            ]),
          ),
          Column(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              visualDensity: VisualDensity.compact,
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 240),
                switchInCurve: Curves.easeOutBack,
                transitionBuilder: (child, anim) => ScaleTransition(
                  scale: anim,
                  child: FadeTransition(opacity: anim, child: child),
                ),
                child: Icon(
                  a.done ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                  key: ValueKey(a.done),
                  color: a.done ? kHabit : on.withOpacity(0.5),
                ),
              ),
              onPressed: () {
                a.done = !a.done;
                store.updateAssignment(a);
              },
            ),
          ]),
        ]),
      ),
    );
  }
}

Future<void> showAssignmentSheet(BuildContext context, {Assignment? a, DateTime? date}) {
  final title = TextEditingController(text: a?.title ?? '');
  final subject = TextEditingController(text: a?.subject ?? '');
  String type = a?.type ?? 'Assignment';
  DateTime d = a?.date ?? date ?? DateTime.now();
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      return keyboardAwareSheet(
        ctx,
        Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(a == null ? 'New entry' : 'Edit entry',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: onSurf(ctx))),
              const SizedBox(height: 16),
              TextField(controller: title, decoration: deco(ctx, 'Title (e.g. Maths Final)')),
              const SizedBox(height: 12),
              TextField(controller: subject, decoration: deco(ctx, 'Subject (optional)')),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'Assignment', label: Text('Assignment'), icon: Icon(Icons.edit_note_rounded)),
                    ButtonSegment(value: 'Exam', label: Text('Exam'), icon: Icon(Icons.school_rounded)),
                  ],
                  selected: {type},
                  onSelectionChanged: (s) => set(() => type = s.first),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  icon: const Icon(Icons.event_rounded),
                  label: Text(DateFormat('EEE, d MMM yyyy').format(d)),
                  onPressed: () async {
                    final p = await showDatePicker(
                      context: ctx,
                      initialDate: d,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(2100),
                    );
                    if (p != null) set(() => d = p);
                  },
                ),
              ),
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: () {
                    if (title.text.trim().isEmpty) return;
                    if (a == null) {
                      store.addAssignment(Assignment(
                        id: newId(),
                        title: title.text.trim(),
                        subject: subject.text.trim(),
                        type: type,
                        date: d,
                      ));
                    } else {
                      a.title = title.text.trim();
                      a.subject = subject.text.trim();
                      a.type = type;
                      a.date = d;
                      store.updateAssignment(a);
                    }
                    Navigator.pop(ctx);
                  },
                  child: Text(a == null ? 'Add' : 'Save changes', style: const TextStyle(fontSize: 16)),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

class AssignmentsPage extends StatefulWidget {
  const AssignmentsPage({super.key});
  @override
  State<AssignmentsPage> createState() => _AssignmentsPageState();
}

class _AssignmentsPageState extends State<AssignmentsPage> {
  String filter = 'All';
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final today = dateOnly(DateTime.now());
        final all = store.sorted.where((a) => filter == 'All' || a.type == filter).toList();
        final overdue = all.where((a) => !a.done && dateOnly(a.date).isBefore(today)).toList();
        final upcoming = all.where((a) => !a.done && !dateOnly(a.date).isBefore(today)).toList();
        final done = all.where((a) => a.done).toList();
        return Stack(children: [
          Positioned.fill(
            child: RevealList(
          page: 'asg',
          padding: const EdgeInsets.only(bottom: 190),
          children: [
            PageHeader(
              title: 'Assignments',
              subtitle: 'Exams & deadlines by date',
              action: GlassIconBtn(Icons.tune_rounded, () => showAssignmentSettings(c)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Wrap(
                spacing: 8,
                children: ['All', 'Exam', 'Assignment'].map((f) {
                  return ChoiceChip(
                    label: Text(f == 'All' ? 'All' : '${f}s'),
                    selected: filter == f,
                    selectedColor: kAccent.withOpacity(0.35),
                    onSelected: (_) => setState(() => filter = f),
                  );
                }).toList(),
              ),
            ),
            if (all.isEmpty) const EmptyCard(Icons.event_note_rounded, 'Nothing here yet.\nTap + to add an exam or assignment.'),
            if (overdue.isNotEmpty) ...[
              const SectionTitle('Overdue'),
              ...overdue.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a, swipe: store.swipeActions)),
            ],
            if (upcoming.isNotEmpty) ...[
              const SectionTitle('Upcoming'),
              ...upcoming.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a, swipe: store.swipeActions)),
            ],
            if (done.isNotEmpty) ...[
              const SectionTitle('Completed'),
              ...done.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a, swipe: store.swipeActions)),
            ],
          ],
            ),
          ),
          Positioned(
            right: 20,
            bottom: MediaQuery.paddingOf(c).bottom + 16,
            child: FabButton(icon: Icons.add_rounded, onTap: () => showAssignmentSheet(c)),
          ),
        ]);
      },
    );
  }
}

// ───────────────────────── calendar ─────────────────────────
class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});
  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  DateTime focused = DateTime.now();
  DateTime selected = DateTime.now();

  Widget legend(String t, Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 14, height: 4, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(fontSize: 12.5, color: onSurf(context).withOpacity(0.7))),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final dayAssign = store.sorted.where((a) => sameDay(a.date, selected)).toList();
        return RevealList(
          page: 'cal',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            const PageHeader(title: 'Calendar', subtitle: 'Exams, assignments & habits'),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(6, 8, 6, 10),
                child: TableCalendar<Object>(
                  firstDay: DateTime.utc(2020, 1, 1),
                  lastDay: DateTime.utc(2100, 12, 31),
                  focusedDay: focused,
                  rowHeight: 48,
                  pageAnimationDuration: const Duration(milliseconds: 300),
                  pageAnimationCurve: Curves.easeInOutCubic,
                  startingDayOfWeek: StartingDayOfWeek.monday,
                  selectedDayPredicate: (d) => isSameDay(selected, d),
                  onDaySelected: (s, f) => setState(() {
                    selected = s;
                    focused = f;
                  }),
                  onPageChanged: (f) => focused = f,
                  eventLoader: (day) => <Object>[
                    ...store.assignments.where((a) => sameDay(a.date, day)),
                  ],
                  headerStyle: HeaderStyle(
                    formatButtonVisible: false,
                    titleCentered: true,
                    titleTextStyle: TextStyle(color: on, fontSize: 17, fontWeight: FontWeight.w700),
                    leftChevronIcon: Icon(Icons.chevron_left_rounded, color: on),
                    rightChevronIcon: Icon(Icons.chevron_right_rounded, color: on),
                  ),
                  daysOfWeekStyle: DaysOfWeekStyle(
                    weekdayStyle: TextStyle(color: on.withOpacity(0.6), fontSize: 12),
                    weekendStyle: TextStyle(color: on.withOpacity(0.6), fontSize: 12),
                  ),
                  calendarStyle: CalendarStyle(
                    outsideDaysVisible: false,
                    defaultTextStyle: TextStyle(color: on),
                    weekendTextStyle: TextStyle(color: on.withOpacity(0.85)),
                    todayTextStyle: TextStyle(color: on, fontWeight: FontWeight.w700),
                    todayDecoration: BoxDecoration(
                      color: kAccent.withOpacity(0.35),
                      shape: BoxShape.circle,
                    ),
                    selectedTextStyle:
                        const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
                    selectedDecoration:
                        const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                  ),
                  calendarBuilders: CalendarBuilders<Object>(
                    markerBuilder: (ctx, day, events) {
                      if (events.isEmpty) return null;
                      // exams first, then assignments; at most 6 bars in two rows of 3
                      final items = events.whereType<Assignment>().toList()
                        ..sort((x, y) =>
                            (x.type == 'Exam' ? 0 : 1).compareTo(y.type == 'Exam' ? 0 : 1));
                      final shown = items.length > 6 ? items.sublist(0, 6) : items;
                      Widget bar(Assignment e) => Container(
                            width: 9,
                            height: 3,
                            margin: const EdgeInsets.all(1),
                            decoration: BoxDecoration(
                              color: typeColor(e.type),
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          );
                      return Positioned(
                        bottom: 3,
                        child: PopIn(
                          child: Column(mainAxisSize: MainAxisSize.min, children: [
                            Row(mainAxisSize: MainAxisSize.min, children: shown.take(3).map(bar).toList()),
                            if (shown.length > 3)
                              Row(mainAxisSize: MainAxisSize.min, children: shown.skip(3).map(bar).toList()),
                          ]),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(22, 14, 20, 0),
              child: Wrap(spacing: 18, children: [
                legend('Exam', kExam),
                legend('Assignment', kAssign),
              ]),
            ),
            const SizedBox(height: 6),
            SectionTitle(
              DateFormat('EEEE, d MMM').format(selected),
              trailing: GlassIconBtn(Icons.add_rounded, () => showAssignmentSheet(c, date: selected)),
            ),
            if (dayAssign.isEmpty)
              const EmptyCard(Icons.event_note_rounded, 'Nothing scheduled for this day.'),
            ...dayAssign.map((a) => AssignmentTile(key: ValueKey('asg_${a.id}'), a: a)),
          ],
        );
      },
    );
  }
}


// ───────────────────────── attendance ─────────────────────────
const kPresent = Color(0xFF42D987);
const kSelfLeave = Color(0xFFF45B91);
const kHoliday = Color(0xFFF5B942);
const kWarn = Color(0xFFFACC15);
const kBad = Color(0xFFF87171);

bool isWeekend(DateTime d) => d.weekday >= 6;
DateTime prevDay(DateTime d) => DateTime(d.year, d.month, d.day - 1);
DateTime nextDay(DateTime d) => DateTime(d.year, d.month, d.day + 1);

/// 'holiday' is the status used for new entries. Records saved earlier as
/// 'public' or 'college' stay exactly as they are and count as holidays too.
bool isHoliday(String? v) => v == 'holiday' || v == 'public' || v == 'college';

Color attColor(String s) =>
    s == 'present' ? kPresent : (s == 'self' ? kSelfLeave : kHoliday);

String attLabel(String s) {
  if (s == 'present') return 'Present';
  if (s == 'self') return 'Self leave';
  return 'Holiday';
}

IconData attIcon(String? s) {
  if (s == 'present') return Icons.event_available_rounded;
  if (s == 'self') return Icons.event_busy_rounded;
  if (s == null) return Icons.edit_calendar_rounded;
  return Icons.celebration_rounded;
}

class AttStats {
  int present = 0, absent = 0, holidays = 0;
  int get working => present + absent;
  double? get pct => working == 0 ? null : present * 100 / working;
}

AttStats attStats({int? year, int? month}) {
  final st = AttStats();
  store.attendance.forEach((k, v) {
    final d = DateTime.parse(k);
    if (year != null && (d.year != year || d.month != month)) return;
    if (v == 'present') {
      st.present++;
    } else if (v == 'self') {
      st.absent++;
    } else {
      st.holidays++;
    }
  });
  return st;
}

Color pctColor(double? p) {
  if (p == null) return kHoliday;
  if (p >= store.thGreen) return kPresent;
  if (p >= store.thYellow) return kWarn;
  return kBad;
}

/// Gradient palette for attendance analytics, driven by the existing thresholds.
(Color, Color) attendanceGradient(double? p) {
  if (p != null && p >= store.thGreen) {
    return (const Color(0xFF10B981), const Color(0xFF2DD4BF)); // emerald → turquoise
  }
  if (p != null && p >= store.thYellow) {
    return (const Color(0xFFFBBF24), const Color(0xFFA3E635)); // golden yellow → light green
  }
  return (const Color(0xFFEF4444), const Color(0xFFF97316)); // red → dragon orange
}

String pctLabel(double? p) {
  if (p == null) return 'No data yet';
  if (p >= store.thGreen) return 'On track';
  if (p >= store.thYellow) return 'Needs attention';
  return 'Low attendance';
}

/// Returns [current, longest] streak of attended days.
/// Weekends and holidays are skipped. Self leave and unrecorded weekdays break a streak.
List<int> attStreaks() {
  final a = store.attendance;
  if (a.isEmpty) return [0, 0];
  final today = dateOnly(DateTime.now());
  final first = a.keys.map(DateTime.parse).reduce((x, y) => x.isBefore(y) ? x : y);

  var cur = 0;
  var d = today;
  while (!d.isBefore(first)) {
    final v = a[dayKey(d)];
    if (v == 'present') {
      cur++;
    } else if (isHoliday(v)) {
    } else if (v == null && (isWeekend(d) || sameDay(d, today))) {
    } else {
      break;
    }
    d = prevDay(d);
  }

  var run = 0, best = 0;
  for (var x = first; !x.isAfter(today); x = nextDay(x)) {
    final v = a[dayKey(x)];
    if (v == 'present') {
      run++;
      if (run > best) best = run;
    } else if (isHoliday(v)) {
    } else if (v == null && (isWeekend(x) || sameDay(x, today))) {
    } else {
      run = 0;
    }
  }
  return [cur, best];
}

/// Present days divided by elapsed weekdays (holidays excluded). Unrecorded weekdays count against it.
double? attConsistency(int year, int month) {
  final today = dateOnly(DateTime.now());
  final dim = DateUtils.getDaysInMonth(year, month);
  var den = 0, att = 0;
  for (var i = 1; i <= dim; i++) {
    final d = DateTime(year, month, i);
    if (d.isAfter(today)) break;
    final v = store.attendance[dayKey(d)];
    if (sameDay(d, today) && v == null) continue;
    if (v == 'present') att++;
    if (!isWeekend(d) && !isHoliday(v)) den++;
  }
  if (den == 0) return null;
  return (att * 100 / den).clamp(0, 100).toDouble();
}

Future<void> showAttendanceSheet(BuildContext context, DateTime day) {
  final today = dateOnly(DateTime.now());
  final isFuture = dateOnly(day).isAfter(today);
  final current = store.attendance[dayKey(day)];
  String? choice = current;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);

      Widget option(String code, String label, IconData icon) {
        final sel = code == 'holiday' ? isHoliday(choice) : choice == code;
        final col = attColor(code);
        return Expanded(
          child: GestureDetector(
            onTap: () => set(() {
              if (code == 'holiday') {
                if (!isHoliday(choice)) choice = 'holiday'; // an older holiday type stays as it is
              } else {
                choice = code;
              }
            }),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
              decoration: BoxDecoration(
                color: sel ? col.withOpacity(0.22) : on.withOpacity(0.07),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: sel ? col : Colors.transparent, width: 1.6),
              ),
              child: Row(children: [
                Icon(icon, size: 20, color: col),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(label,
                      style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                          color: on)),
                ),
              ]),
            ),
          ),
        );
      }

      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(DateFormat('EEEE, d MMMM yyyy').format(day),
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 8),
            Row(children: [
              Text('Current status', style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
              const SizedBox(width: 8),
              Pill(current == null ? 'Not recorded' : attLabel(current),
                  current == null ? kAccent : attColor(current)),
            ]),
            const SizedBox(height: 18),
            if (isFuture) ...[
              Text("Attendance can't be recorded for future dates.",
                  style: TextStyle(fontSize: 14, color: on.withOpacity(0.7))),
              const SizedBox(height: 18),
              FilledButton.tonal(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Got it'),
              ),
            ] else ...[
              Row(children: [
                option('present', 'Present', Icons.check_circle_rounded),
                const SizedBox(width: 10),
                option('self', 'Self leave', Icons.person_off_rounded),
              ]),
              const SizedBox(height: 10),
              Row(children: [
                option('holiday', 'Holiday', Icons.celebration_rounded),
              ]),
              const SizedBox(height: 18),
              Row(children: [
                if (current != null) ...[
                  TextButton(
                    onPressed: () {
                      store.setAttendance(day, null);
                      Navigator.pop(ctx);
                    },
                    child: const Text('Clear'),
                  ),
                  const SizedBox(width: 8),
                ],
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: kAccent,
                      padding: const EdgeInsets.symmetric(vertical: 15),
                    ),
                    onPressed: (choice == null || choice == current)
                        ? null
                        : () {
                            store.setAttendance(day, choice);
                            Navigator.pop(ctx);
                          },
                    child: const Text('Save', style: TextStyle(fontSize: 16)),
                  ),
                ),
              ]),
            ],
          ]),
        ),
      );
    }),
  );
}

Future<void> showNoReasonSheet(BuildContext context, DateTime day) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final on = onSurf(ctx);
      Widget reason(IconData icon, String t, String sub, String code, Color col) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Glass(
              radius: 18,
              padding: const EdgeInsets.all(14),
              onTap: () {
                store.setAttendance(day, code);
                Navigator.pop(ctx);
              },
              child: Row(children: [
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    color: col.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: col),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(t, style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
                    Text(sub, style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                  ]),
                ),
              ]),
            ),
          );
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('Why not?', style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 14),
            reason(Icons.celebration_rounded, 'Holiday', 'Excluded from working days', 'holiday', kHoliday),
            reason(Icons.person_off_rounded, 'Self leave', 'Counts as absent', 'self', kSelfLeave),
          ]),
        ),
      );
    },
  );
}

Future<void> showThresholdSheet(BuildContext context) {
  var g = store.thGreen;
  var y = store.thYellow;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Attendance thresholds',
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 4),
            Text('Choose where green and yellow start.',
                style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
            const SizedBox(height: 18),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kPresent),
              const SizedBox(width: 8),
              Expanded(child: Text('Green from $g%', style: TextStyle(fontWeight: FontWeight.w600, color: on))),
            ]),
            Slider(
              value: g.toDouble(),
              min: 51,
              max: 100,
              divisions: 49,
              label: '$g%',
              onChanged: (v) => set(() {
                g = v.round();
                if (y >= g) y = g - 1;
              }),
              onChangeEnd: (_) => store.setThresholds(g, y),
            ),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kWarn),
              const SizedBox(width: 8),
              Expanded(child: Text('Yellow from $y%', style: TextStyle(fontWeight: FontWeight.w600, color: on))),
            ]),
            Slider(
              value: y.toDouble(),
              min: 50,
              max: 99,
              divisions: 49,
              label: '$y%',
              onChanged: (v) => set(() {
                y = v.round();
                if (g <= y) g = y + 1;
              }),
              onChangeEnd: (_) => store.setThresholds(g, y),
            ),
            Row(children: [
              const Icon(Icons.circle, size: 12, color: kBad),
              const SizedBox(width: 8),
              Text('Red below $y%', style: TextStyle(fontWeight: FontWeight.w600, color: on)),
            ]),
          ]),
        ),
      );
    }),
  );
}

class AttendanceSummary extends StatelessWidget {
  const AttendanceSummary({super.key});
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: store, builder: (c, _) => _body(c));

  Widget _body(BuildContext context) {
    final on = onSurf(context);
    final v = store.attendance[dayKey(DateTime.now())];
    final p = attStats().pct;
    final st = attStreaks();
    final col = v == null ? kAccent : attColor(v);
    return Glass(
      padding: const EdgeInsets.all(14),
      onTap: () => navIndex.value = 3,
      child: Row(children: [
        Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: col.withOpacity(0.2),
            borderRadius: BorderRadius.circular(15),
          ),
          child: Icon(attIcon(v), color: col),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Attendance today',
                style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
            Text(v == null ? 'Not marked yet' : attLabel(v),
                style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
          ]),
        ),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(p == null ? '–' : '${p.round()}%',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: pctColor(p))),
          Text('overall', style: TextStyle(fontSize: 11, color: on.withOpacity(0.6))),
        ]),
        const SizedBox(width: 16),
        Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text('${st[0]}',
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: kWarn)),
          Text('streak', style: TextStyle(fontSize: 11, color: on.withOpacity(0.6))),
        ]),
      ]),
    );
  }
}

class MiniStat extends StatelessWidget {
  final String value, label;
  final Color color;
  const MiniStat(this.value, this.label, this.color, {super.key});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: onSurf(context).withOpacity(0.06),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.65))),
          ),
        ]),
      );
}

class Heatmap extends StatelessWidget {
  final DateTime month, selected;
  final ValueChanged<DateTime> onSelect;
  const Heatmap({super.key, required this.month, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final today = dateOnly(DateTime.now());
    final dim = DateUtils.getDaysInMonth(month.year, month.month);
    final offset = DateTime(month.year, month.month, 1).weekday - 1;
    final cols = ((offset + dim) / 7).ceil();
    const labels = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];
    return LayoutBuilder(builder: (c, box) {
      const gap = 6.0;
      const lw = 22.0;
      final cell = ((box.maxWidth - lw - cols * gap) / cols).clamp(20.0, 42.0).toDouble();
      return Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Column(
          children: List.generate(
            7,
            (r) => SizedBox(
              width: lw,
              height: cell + gap,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(labels[r],
                    style: TextStyle(fontSize: 11, color: on.withOpacity(0.5))),
              ),
            ),
          ),
        ),
        ...List.generate(
          cols,
          (col) => Column(
            children: List.generate(7, (r) {
              final day = col * 7 + r - offset + 1;
              if (day < 1 || day > dim) {
                return SizedBox(width: cell + gap, height: cell + gap);
              }
              final date = DateTime(month.year, month.month, day);
              final v = store.attendance[dayKey(date)];
              final sel = sameDay(date, selected);
              final isToday = sameDay(date, today);
              final presentGradient = const [
                Color(0xFF10B981), Color(0xFF2DD4BF)
              ];
              final selfGradient = const [
                Color(0xFFFB7185), Color(0xFFEC4899)
              ];
              final holidayGradient = const [
                Color(0xFFFBBF24), Color(0xFFA3E635)
              ];
              final List<Color>? cellGradient = v == null
                  ? null
                  : (v == 'present'
                      ? presentGradient
                      : (v == 'self' ? selfGradient : holidayGradient));
              final radius = BorderRadius.circular(cell * 0.28);
              final mutedFill = isDark(context)
                  ? on.withOpacity(0.085)
                  : on.withOpacity(0.065);
              final glowColor = cellGradient?.first;
              final txt = sel
                  ? Colors.white
                  : (v == null
                      ? on.withOpacity(isDark(context) ? 0.72 : 0.78)
                      : (v == 'present'
                          ? const Color(0xFF06281F)
                          : (v == 'self'
                              ? const Color(0xFF3B1020)
                              : const Color(0xFF3B2A08))));
              return SizedBox(
                width: cell + gap,
                height: cell + gap,
                child: Padding(
                  padding: const EdgeInsets.only(right: gap, bottom: gap),
                  child: GestureDetector(
                    onTap: () => onSelect(date),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 260),
                      curve: Curves.easeOutCubic,
                      transformAlignment: Alignment.center,
                      transform: Matrix4.diagonal3Values(sel ? 1.1 : 1.0, sel ? 1.1 : 1.0, 1.0),
                      decoration: BoxDecoration(
                        color: cellGradient == null && !sel ? mutedFill : null,
                        gradient: sel
                            ? const LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [Color(0xFF8B5CF6), Color(0xFF6D28D9)],
                              )
                            : (cellGradient == null
                                ? null
                                : LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: cellGradient,
                                  )),
                        borderRadius: radius,
                        border: isToday && !sel
                            ? Border.all(color: on.withOpacity(0.7), width: 1.5)
                            : null,
                        boxShadow: sel
                            ? [
                                BoxShadow(
                                  color: kAccent.withOpacity(0.28),
                                  blurRadius: 8,
                                  spreadRadius: 0.5,
                                )
                              ]
                            : (glowColor == null
                                ? null
                                : [
                                    BoxShadow(
                                      color: glowColor.withOpacity(isDark(context) ? 0.22 : 0.16),
                                      blurRadius: 7,
                                      spreadRadius: 0.2,
                                    )
                                  ]),
                      ),
                      child: Stack(alignment: Alignment.center, children: [
                        Text('$day',
                            style: TextStyle(
                                fontSize: 12, fontWeight: FontWeight.w700, color: txt)),
                        if (sel && v != null)
                          Positioned(
                            bottom: 3,
                            child: Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                color: attColor(v),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                      ]),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ]);
    });
  }
}

class AttendanceGradientButton extends StatefulWidget {
  final String label;
  final List<Color> colors;
  final Color glow;
  final VoidCallback onPressed;

  const AttendanceGradientButton({
    super.key,
    required this.label,
    required this.colors,
    required this.glow,
    required this.onPressed,
  });

  @override
  State<AttendanceGradientButton> createState() => _AttendanceGradientButtonState();
}

class _AttendanceGradientButtonState extends State<AttendanceGradientButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return AnimatedScale(
      scale: _pressed ? 0.97 : 1,
      duration: const Duration(milliseconds: 110),
      curve: Curves.easeOut,
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) => setState(() => _pressed = false),
        onTap: widget.onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOut,
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: widget.colors,
            ),
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: widget.glow.withOpacity(_pressed ? 0.16 : 0.25),
                blurRadius: _pressed ? 5 : 10,
                spreadRadius: _pressed ? 0 : 0.4,
              ),
            ],
          ),
          alignment: Alignment.center,
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: widget.label == 'Yes'
                  ? const Color(0xFF06281F)
                  : const Color(0xFF3B1020),
            ),
          ),
        ),
      ),
    );
  }
}

class AttendancePage extends StatefulWidget {
  const AttendancePage({super.key});
  @override
  State<AttendancePage> createState() => _AttendancePageState();
}

class _AttendancePageState extends State<AttendancePage> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  DateTime selected = dateOnly(DateTime.now());

  bool overall = false;

  void goMonth(int delta) {
    final m = DateTime(month.year, month.month + delta);
    final now = DateTime.now();
    setState(() {
      month = m;
      selected = (m.year == now.year && m.month == now.month) ? dateOnly(now) : m;
    });
  }

  Widget legendItem(String t, Color c) => Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 11,
          height: 11,
          decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(t, style: TextStyle(fontSize: 12, color: onSurf(context).withOpacity(0.7))),
      ]);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final today = dateOnly(DateTime.now());
        final todayV = store.attendance[dayKey(today)];
        final ms = attStats(year: month.year, month: month.month);
        final all = attStats();
        final shown = overall ? all : ms;
        final p = shown.pct;
        final pc = pctColor(p);
        final other = overall ? ms.pct : all.pct;
        final st = attStreaks();
        final cons = attConsistency(month.year, month.month);

        return RevealList(
          page: 'att',
          padding: const EdgeInsets.only(bottom: 130),
          children: [
            PageHeader(
              title: 'Attendance',
              subtitle: 'Track your college days',
              action: GlassIconBtn(Icons.tune_rounded, () => showThresholdSheet(c)),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: todayV == null
                      ? Column(
                          key: const ValueKey('ask'),
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Are you going to college today?',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
                            const SizedBox(height: 14),
                            Row(children: [
                              Expanded(
                                child: AttendanceGradientButton(
                                  label: 'Yes',
                                  colors: const [Color(0xFF10B981), Color(0xFF2DD4BF)],
                                  glow: const Color(0xFF10B981),
                                  onPressed: () => store.setAttendance(today, 'present'),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: AttendanceGradientButton(
                                  label: 'No',
                                  colors: const [Color(0xFFFB7185), Color(0xFFF97316)],
                                  glow: const Color(0xFFFB7185),
                                  onPressed: () => showNoReasonSheet(c, today),
                                ),
                              ),
                            ]),
                          ],
                        )
                      : Row(key: const ValueKey('done'), children: [
                          Container(
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: attColor(todayV).withOpacity(0.2),
                              borderRadius: BorderRadius.circular(15),
                            ),
                            child: Icon(attIcon(todayV), color: attColor(todayV)),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Text('Today · ${DateFormat('EEE, d MMM').format(today)}',
                                  style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                              Text(attLabel(todayV),
                                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: on)),
                            ]),
                          ),
                        ]),
                ),
              ),
            ),
            SectionTitle(
              'Analytics',
              trailing: Wrap(spacing: 8, children: [
                ChoiceChip(
                  label: Text(DateFormat('MMMM').format(month)),
                  selected: !overall,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => overall = false),
                ),
                ChoiceChip(
                  label: const Text('Overall'),
                  selected: overall,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => overall = true),
                ),
              ]),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: Column(children: [
                  Row(children: [
                    SizedBox(
                      width: 96,
                      height: 96,
                      child: Stack(alignment: Alignment.center, children: [
                        Builder(builder: (ctx) {
                          final gradient = attendanceGradient(p);
                          return TweenAnimationBuilder<Color?>(
                            tween: ColorTween(end: gradient.$1),
                            duration: const Duration(milliseconds: 420),
                            curve: Curves.easeInOut,
                            builder: (ctx, c1, _) => TweenAnimationBuilder<Color?>(
                              tween: ColorTween(end: gradient.$2),
                              duration: const Duration(milliseconds: 420),
                              curve: Curves.easeInOut,
                              builder: (ctx, c2, _) => TweenAnimationBuilder<double>(
                                tween: Tween<double>(begin: 0, end: (p ?? 0) / 100),
                                duration: const Duration(milliseconds: 800),
                                curve: Curves.easeOutCubic,
                                builder: (ctx, v, _) => CustomPaint(
                                  size: const Size.square(96),
                                  painter: RingPainter(
                                    v,
                                    c1 ?? gradient.$1,
                                    c2 ?? gradient.$2,
                                    on.withOpacity(0.1),
                                    stroke: 9,
                                    inset: 8,
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
                        Text(p == null ? '–' : '${p.round()}%',
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
                      ]),
                    ),
                    const SizedBox(width: 18),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text(overall ? 'All time' : DateFormat('MMMM yyyy').format(month),
                            style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
                        const SizedBox(height: 4),
                        Pill(pctLabel(p), pc),
                        const SizedBox(height: 8),
                        Text(
                          other == null
                              ? (overall ? 'This month: no data' : 'Overall: no data')
                              : (overall
                                  ? 'This month: ${other.round()}%'
                                  : 'Overall: ${other.round()}%'),
                          style: TextStyle(fontSize: 13, color: on.withOpacity(0.7)),
                        ),
                      ]),
                    ),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: MiniStat('${shown.working}', 'Working days', kAssign)),
                    const SizedBox(width: 10),
                    Expanded(child: MiniStat('${shown.present}', 'Present', kPresent)),
                  ]),
                  const SizedBox(height: 10),
                  Row(children: [
                    Expanded(child: MiniStat('${shown.absent}', 'Absent', kSelfLeave)),
                    const SizedBox(width: 10),
                    Expanded(child: MiniStat('${shown.holidays}', 'Holidays', kHoliday)),
                  ]),
                  const SizedBox(height: 12),
                  Text(
                    'Present days divided by working days. Holidays and unrecorded days are left out.',
                    style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.55)),
                  ),
                ]),
              ),
            ),
            SectionTitle('Attendance Calendar'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
                child: Column(children: [
                  Row(children: [
                    IconButton(
                      icon: Icon(Icons.chevron_left_rounded, color: on),
                      onPressed: () => goMonth(-1),
                    ),
                    Expanded(
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 250),
                        child: Text(
                          DateFormat('MMMM yyyy').format(month),
                          key: ValueKey(month),
                          textAlign: TextAlign.center,
                          style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: on),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.chevron_right_rounded, color: on),
                      onPressed: () => goMonth(1),
                    ),
                  ]),
                  const SizedBox(height: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    child: KeyedSubtree(
                      key: ValueKey(month),
                      child: Heatmap(
                        month: month,
                        selected: selected,
                        onSelect: (d) {
                          setState(() => selected = d);
                          showAttendanceSheet(c, d);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Wrap(spacing: 14, runSpacing: 6, children: [
                    legendItem('Present', kPresent),
                    legendItem('Self leave', kSelfLeave),
                    legendItem('Holiday', kHoliday),
                  ]),
                ]),
              ),
            ),
            SectionTitle('Streaks & Consistency'),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Glass(
                child: Row(children: [
                  Expanded(child: _streakCell(Icons.local_fire_department_rounded, '${st[0]}', 'Current', kWarn)),
                  Expanded(child: _streakCell(Icons.emoji_events_rounded, '${st[1]}', 'Longest', kAccent)),
                  Expanded(
                    child: _streakCell(Icons.insights_rounded,
                        cons == null ? '–' : '${cons.round()}%', 'Consistency', kPresent),
                  ),
                ]),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _streakCell(IconData icon, String value, String label, Color color) {
    final on = onSurf(context);
    return Column(children: [
      Icon(icon, color: color, size: 26),
      const SizedBox(height: 6),
      Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
      Text(label, style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
    ]);
  }
}


// ───────────────────────── smart notifications ─────────────────────────
const kNotifCats = ['habit', 'assignment', 'exam', 'attendance'];

final navKey = GlobalKey<NavigatorState>();
final notifier = Notifier();

String catLabel(String c) {
  if (c == 'habit') return 'Habits';
  if (c == 'assignment') return 'Assignments';
  if (c == 'exam') return 'Exams';
  return 'Attendance';
}

IconData catIcon(String c) {
  if (c == 'habit') return Icons.task_alt_rounded;
  if (c == 'assignment') return Icons.assignment_rounded;
  if (c == 'exam') return Icons.school_rounded;
  return Icons.how_to_reg_rounded;
}

Color catColor(String c) {
  if (c == 'habit') return kHabit;
  if (c == 'assignment') return kAssign;
  if (c == 'exam') return kExam;
  return kAccent;
}

int tabFor(String cat) => cat == 'habit' ? 0 : (cat == 'attendance' ? 3 : 1);

String notifTime(int ms) {
  final t = DateTime.fromMillisecondsSinceEpoch(ms);
  final now = DateTime.now();
  final diff = now.difference(t);
  if (diff.inMinutes < 1) return 'Just now';
  if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
  final time = DateFormat('h:mm a').format(t);
  if (sameDay(t, now)) return 'Today, $time';
  if (sameDay(t, DateTime(now.year, now.month, now.day - 1))) return 'Yesterday, $time';
  return '${DateFormat('d MMM').format(t)}, $time';
}

class Notif {
  String key, cat, title, body;
  int at;
  bool read;
  Notif({
    required this.key,
    required this.cat,
    required this.title,
    required this.body,
    required this.at,
    this.read = false,
  });
  Map<String, dynamic> toJson() =>
      {'key': key, 'cat': cat, 'title': title, 'body': body, 'at': at, 'read': read};
  factory Notif.fromJson(Map<String, dynamic> j) => Notif(
        key: j['key'],
        cat: j['cat'],
        title: j['title'],
        body: j['body'],
        at: j['at'],
        read: j['read'] ?? false,
      );
}

class Notifier {
  final FlutterLocalNotificationsPlugin _plugin = FlutterLocalNotificationsPlugin();
  final ValueNotifier<bool> allowed = ValueNotifier<bool>(true);
  bool ready = false;
  bool _syncing = false, _again = false;
  Timer? _debounce, _tick;

  AndroidFlutterLocalNotificationsPlugin? get _android =>
      _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();

  Future<void> init() async {
    try {
      await _plugin.initialize(
        const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
        onDidReceiveNotificationResponse: (r) => _open(r.payload),
      );
      final a = _android;
      for (final c in kNotifCats) {
        await a?.createNotificationChannel(AndroidNotificationChannel(
          'studyflow_$c',
          '${catLabel(c)} reminders',
          description: 'Reminders for ${catLabel(c).toLowerCase()}',
          importance: Importance.high,
        ));
      }
      ready = true;
      final d = await _plugin.getNotificationAppLaunchDetails();
      if (d != null && d.didNotificationLaunchApp) _open(d.notificationResponse?.payload);
    } catch (_) {
      return;
    }
    try {
      if (!store.permAsked) {
        await requestPermission();
        store.permAsked = true;
        store.saveNotifs();
      } else {
        await refreshPermission();
      }
    } catch (_) {}
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(seconds: 30), (_) => deliverDue());
    await sync();
  }

  void _open(String? payload) {
    if (payload == null || payload == 'pomodoro') return;
    navKey.currentState?.popUntil((r) => r.isFirst);
    navIndex.value = tabFor(payload);
  }

  Future<bool> requestPermission() async {
    var ok = true;
    try {
      ok = await _android?.requestNotificationsPermission() ?? true;
    } catch (_) {}
    allowed.value = ok;
    if (ok) requestSync();
    return ok;
  }

  Future<void> refreshPermission() async {
    try {
      allowed.value = await _android?.areNotificationsEnabled() ?? true;
    } catch (_) {}
  }

  void requestSync() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 700), sync);
  }

  int _id(String s) {
    var h = 0x811C9DC5;
    for (final c in s.codeUnits) {
      h ^= c;
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h & 0x7FFFFFFF;
  }

  NotificationDetails _details(String cat, String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          'studyflow_$cat',
          '${catLabel(cat)} reminders',
          channelDescription: 'Reminders for ${catLabel(cat).toLowerCase()}',
          importance: Importance.high,
          priority: Priority.high,
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

  NotificationDetails _pomoDetails(bool sound, String body) => NotificationDetails(
        android: AndroidNotificationDetails(
          sound ? 'studyflow_pomo' : 'studyflow_pomo_quiet',
          sound ? 'Pomodoro alerts' : 'Pomodoro alerts (silent)',
          channelDescription: 'Pomodoro session alerts',
          importance: Importance.high,
          priority: Priority.high,
          playSound: sound,
          category: AndroidNotificationCategory.reminder,
          styleInformation: BigTextStyleInformation(body),
        ),
      );

  Future<void> pomoNow(String title, String body, bool sound) async {
    if (!ready || !allowed.value) return;
    try {
      await _plugin.show(9001, title, body, _pomoDetails(sound, body), payload: 'pomodoro');
    } catch (_) {}
  }

  Future<void> pomoSchedule(DateTime at, String title, String body, bool sound) async {
    if (!ready || !allowed.value || !at.isAfter(DateTime.now())) return;
    try {
      var exact = false;
      try {
        exact = await _android?.canScheduleExactNotifications() ?? false;
      } catch (_) {}
      final u = at.toUtc();
      await _plugin.zonedSchedule(
        9001,
        title,
        body,
        tz.TZDateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second),
        _pomoDetails(sound, body),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
        payload: 'pomodoro',
      );
    } catch (_) {}
  }

  Future<void> pomoCancel() async {
    try {
      await _plugin.cancel(9001);
    } catch (_) {}
  }

  Future<void> sendTest() async {
    const body = 'Reminders are working. You will get them at the times you chose.';
    try {
      await _plugin.show(7, 'StudyFlow notifications are on', body, _details('habit', body));
    } catch (_) {}
  }

  /// Moves notifications whose time has passed from the plan into the inbox.
  void deliverDue() {
    final now = DateTime.now().millisecondsSinceEpoch;
    var changed = false;
    final keep = <Notif>[];
    for (final p in store.plan) {
      if (p.at <= now) {
        if (!store.inbox.any((n) => n.key == p.key)) {
          store.inbox.add(Notif(key: p.key, cat: p.cat, title: p.title, body: p.body, at: p.at));
        }
        changed = true;
      } else {
        keep.add(p);
      }
    }
    if (changed) {
      store.plan = keep;
      _prune();
      store.saveNotifs();
    }
  }

  /// Removes inbox items that are old or no longer relevant to the current data.
  void _prune() {
    final cutoff = DateTime.now().subtract(const Duration(days: 30)).millisecondsSinceEpoch;
    store.inbox.removeWhere((n) {
      if (n.at < cutoff) return true;
      final p = n.key.split(':');
      if (p.length < 2) return false;
      if (p[0] == 'asg' || p[0] == 'exam') {
        final a = store.assignments.where((x) => x.id == p[1]);
        return a.isEmpty || a.first.done;
      }
      if (p[0] == 'att') return store.attendance.containsKey(p[1]);
      return false;
    });
    store.inbox.sort((a, b) => b.at.compareTo(a.at));
    if (store.inbox.length > 150) store.inbox = store.inbox.sublist(0, 150);
  }

  List<Notif> _build(DateTime now) {
    final out = <Notif>[];
    final today = dateOnly(now);
    DateTime at(DateTime d, int m) => DateTime(d.year, d.month, d.day, m ~/ 60, m % 60);
    void add(String key, String cat, String title, String body, DateTime when) {
      if (!when.isAfter(now)) return;
      out.add(Notif(key: key, cat: cat, title: title, body: body, at: when.millisecondsSinceEpoch));
    }

    final on = store.nOn;
    final tm = store.nTime;

    if (on['habit'] == true && store.habits.isNotEmpty) {
      for (var i = 0; i < 14; i++) {
        final day = DateTime(today.year, today.month, today.day + i);
        String body;
        if (i == 0) {
          final left = store.habits.where((h) => !h.days.contains(dayKey(day))).toList();
          if (left.isEmpty) continue;
          body = left.length == 1
              ? 'Still to do today: ${left.first.name}'
              : '${left.length} habits left today: ${left.take(3).map((h) => h.name).join(", ")}${left.length > 3 ? "..." : ""}';
        } else {
          final n = store.habits.length;
          body = 'Check in on your $n habit${n == 1 ? "" : "s"} today';
        }
        add('habit:${dayKey(day)}', 'habit', 'Habit check-in', body, at(day, tm['habit']!));
      }
    }

    if (on['attendance'] == true) {
      for (var i = 0; i < 14; i++) {
        final day = DateTime(today.year, today.month, today.day + i);
        if (isWeekend(day) || store.attendance.containsKey(dayKey(day))) continue;
        add('att:${dayKey(day)}', 'attendance', 'Are you going to college today?',
            'Tap to mark your attendance.', at(day, tm['attendance']!));
      }
    }

    final horizon = DateTime(today.year, today.month, today.day + 30);
    for (final a in store.assignments) {
      if (a.done) continue;
      final d = dateOnly(a.date);
      if (d.isBefore(today)) continue;
      final isExam = a.type == 'Exam';
      final cat = isExam ? 'exam' : 'assignment';
      if (on[cat] != true) continue;
      final offsets = isExam ? [3, 1, 0] : [1, 0];
      for (final o in offsets) {
        final day = DateTime(d.year, d.month, d.day - o);
        if (day.isAfter(horizon)) continue;
        String title;
        if (isExam) {
          title = o == 0 ? 'Exam today' : (o == 1 ? 'Exam tomorrow' : 'Exam in $o days');
        } else {
          title = o == 0 ? 'Assignment due today' : 'Assignment due tomorrow';
        }
        final sub = a.subject.isEmpty ? '' : ' · ${a.subject}';
        add('${isExam ? "exam" : "asg"}:${a.id}:$o', cat, title,
            '${a.title}$sub · ${DateFormat("EEE, d MMM").format(a.date)}', at(day, tm[cat]!));
      }
    }
    return out;
  }

  Future<void> sync() async {
    if (!ready) return;
    if (_syncing) {
      _again = true;
      return;
    }
    _syncing = true;
    try {
      deliverDue();
      _prune();
      final now = DateTime.now();
      final desired = <String, Notif>{for (final n in _build(now)) n.key: n};
      final old = <String, Notif>{for (final p in store.plan) p.key: p};

      var exact = false;
      try {
        exact = await _android?.canScheduleExactNotifications() ?? false;
      } catch (_) {}

      var pendingIds = <int>{};
      try {
        final pending = await _plugin.pendingNotificationRequests();
        final desiredIds = desired.keys.map(_id).toSet();
        for (final p in pending) {
          if (p.id != 9001 && !desiredIds.contains(p.id)) await _plugin.cancel(p.id);
        }
        pendingIds = pending.map((p) => p.id).toSet();
      } catch (_) {}

      if (allowed.value) {
        for (final n in desired.values) {
          final o = old[n.key];
          final same = o != null && o.at == n.at && o.title == n.title && o.body == n.body;
          if (same && pendingIds.contains(_id(n.key))) continue;
          try {
            final u = DateTime.fromMillisecondsSinceEpoch(n.at).toUtc();
            await _plugin.zonedSchedule(
              _id(n.key),
              n.title,
              n.body,
              tz.TZDateTime.utc(u.year, u.month, u.day, u.hour, u.minute, u.second),
              _details(n.cat, n.body),
              androidScheduleMode: exact
                  ? AndroidScheduleMode.exactAllowWhileIdle
                  : AndroidScheduleMode.inexactAllowWhileIdle,
              payload: n.cat,
            );
          } catch (_) {}
        }
      }

      store.plan = desired.values.toList()..sort((a, b) => a.at.compareTo(b.at));
      store.saveNotifs();
    } finally {
      _syncing = false;
      if (_again) {
        _again = false;
        requestSync();
      }
    }
  }
}

// ───────────────────────── notification UI ─────────────────────────
DateTime? _lastPush;

/// Pushes a screen with a horizontal slide and fade: the new screen enters from
/// the right and the one below drifts left; going back plays the reverse.
/// A second tap within 600 ms is ignored, so a destination is never pushed twice.
Future<void> openScreen(BuildContext context, Widget page) {
  final now = DateTime.now();
  if (_lastPush != null && now.difference(_lastPush!) < const Duration(milliseconds: 600)) {
    return Future.value();
  }
  _lastPush = now;
  return Navigator.of(context).push(PageRouteBuilder(
    transitionDuration: const Duration(milliseconds: 320),
    reverseTransitionDuration: const Duration(milliseconds: 280),
    pageBuilder: (_, __, ___) => page,
    transitionsBuilder: (_, anim, secondary, child) {
      final inC = CurvedAnimation(
          parent: anim, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      final outC = CurvedAnimation(
          parent: secondary, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
      return SlideTransition(
        position: Tween<Offset>(begin: Offset.zero, end: const Offset(-0.18, 0)).animate(outC),
        child: SlideTransition(
          position: Tween<Offset>(begin: const Offset(0.35, 0), end: Offset.zero).animate(inC),
          child: FadeTransition(opacity: inC, child: child),
        ),
      );
    },
  ));
}

/// Used for the first (home) route so it only drifts left when a screen is pushed
/// over it, instead of Material's default zoom, matching openScreen.
class _DriftTransitions extends PageTransitionsBuilder {
  const _DriftTransitions();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation, Widget child) {
    final out = CurvedAnimation(
        parent: secondaryAnimation, curve: Curves.easeOutCubic, reverseCurve: Curves.easeInCubic);
    return SlideTransition(
      position: Tween<Offset>(begin: Offset.zero, end: const Offset(-0.18, 0)).animate(out),
      child: child,
    );
  }
}

Widget screenFrame(BuildContext c, Widget body) {
  final d = isDark(c);
  return AnnotatedRegion<SystemUiOverlayStyle>(
    value: (d ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
        .copyWith(statusBarColor: Colors.transparent),
    child: Stack(children: [
      const Positioned.fill(child: Background()),
      Scaffold(backgroundColor: Colors.transparent, body: SafeArea(child: body)),
    ]),
  );
}

class SubHeader extends StatelessWidget {
  final String title, subtitle;
  final List<Widget> actions;
  const SubHeader({super.key, required this.title, required this.subtitle, this.actions = const []});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
      child: Row(children: [
        GlassIconBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.of(context).pop()),
        const SizedBox(width: 14),
        Expanded(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, color: on)),
              Text(subtitle, style: TextStyle(fontSize: 13.5, color: on.withOpacity(0.6))),
            ]),
          ),
        ),
        for (final a in actions) ...[const SizedBox(width: 10), a],
      ]),
    );
  }
}

class NotificationBell extends StatelessWidget {
  const NotificationBell({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final n = store.unread;
        return Stack(clipBehavior: Clip.none, children: [
          GlassIconBtn(
            n > 0 ? Icons.notifications_active_rounded : Icons.notifications_none_rounded,
            () => openScreen(c, const NotificationCenterPage()),
          ),
          Positioned(
            top: -5,
            right: -5,
            child: AnimatedScale(
              scale: n > 0 ? 1 : 0,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutBack,
              child: Container(
                constraints: const BoxConstraints(minWidth: 19),
                height: 19,
                padding: const EdgeInsets.symmetric(horizontal: 5),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kExam,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isDark(c) ? const Color(0xFF15102E) : Colors.white,
                    width: 1.5,
                  ),
                ),
                child: Text(n > 9 ? '9+' : '$n',
                    style: const TextStyle(
                        fontSize: 10.5, fontWeight: FontWeight.w800, color: Colors.white)),
              ),
            ),
          ),
        ]);
      },
    );
  }
}

class NotificationCenterPage extends StatefulWidget {
  const NotificationCenterPage({super.key});
  @override
  State<NotificationCenterPage> createState() => _NotificationCenterPageState();
}

class _NotificationCenterPageState extends State<NotificationCenterPage> {
  String filter = 'all';

  String _group(int ms) {
    final t = DateTime.fromMillisecondsSinceEpoch(ms);
    final now = DateTime.now();
    if (sameDay(t, now)) return 'TODAY';
    if (sameDay(t, DateTime(now.year, now.month, now.day - 1))) return 'YESTERDAY';
    return DateFormat('d MMMM yyyy').format(t).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final on = onSurf(c);
          final items = store.inbox.where((n) => filter == 'all' || n.cat == filter).toList()
            ..sort((a, b) => b.at.compareTo(a.at));
          final unread = store.unread;
          final children = <Widget>[];
          String? last;
          for (var i = 0; i < items.length; i++) {
            final g = _group(items[i].at);
            if (g != last) {
              children.add(Padding(
                key: ValueKey('g_$g'),
                padding: const EdgeInsets.fromLTRB(24, 6, 20, 10),
                child: Text(g,
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                        color: on.withOpacity(0.5))),
              ));
              last = g;
            }
            children.add(NotifTile(key: ValueKey('n_${items[i].key}'), n: items[i], index: i));
          }
          return Column(children: [
            SubHeader(
              title: 'Notifications',
              subtitle: unread == 0 ? 'All caught up' : '$unread unread',
              actions: [
                GlassIconBtn(Icons.tune_rounded, () => openScreen(c, const NotificationSettingsPage())),
              ],
            ),
            SizedBox(
              height: 44,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: ['all', ...kNotifCats].map((f) {
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: ChoiceChip(
                      label: Text(f == 'all' ? 'All' : catLabel(f)),
                      selected: filter == f,
                      selectedColor: kAccent.withOpacity(0.35),
                      onSelected: (_) => setState(() => filter = f),
                    ),
                  );
                }).toList(),
              ),
            ),
            AnimatedSize(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              child: unread > 0
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton.icon(
                          onPressed: store.markAllRead,
                          icon: const Icon(Icons.done_all_rounded, size: 18),
                          label: const Text('Mark all as read'),
                        ),
                      ),
                    )
                  : const SizedBox(width: double.infinity, height: 8),
            ),
            Expanded(
              child: items.isEmpty
                  ? ListView(
                      padding: const EdgeInsets.only(top: 20),
                      children: const [
                        EmptyCard(Icons.notifications_none_rounded, 'Nothing here yet.\nYour reminders will show up as they arrive.'),
                      ],
                    )
                  : RevealList(
                      page: 'nc',
                      padding: const EdgeInsets.only(bottom: 30),
                      children: children,
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

class NotifTile extends StatelessWidget {
  final Notif n;
  final int index;
  const NotifTile({super.key, required this.n, required this.index});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final col = catColor(n.cat);
    final unread = !n.read;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: Duration.zero,
      curve: Curves.easeOutCubic,
      builder: (ctx, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * 14), child: child),
      ),
      child: Dismissible(
        key: ValueKey(n.key),
        direction: DismissDirection.endToStart,
        onDismissed: (_) => store.deleteNotif(n.key),
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 26),
          margin: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          decoration: BoxDecoration(
            color: kBad.withOpacity(0.22),
            borderRadius: BorderRadius.circular(24),
          ),
          child: const Icon(Icons.delete_outline_rounded, color: kBad),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Glass(
            padding: const EdgeInsets.all(14),
            onTap: () {
              store.markRead(n.key);
              Navigator.of(context).pop();
              navIndex.value = tabFor(n.cat);
            },
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  color: col.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(15),
                ),
                child: Icon(catIcon(n.cat), color: col),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(n.title,
                      style: TextStyle(
                          fontSize: 15.5,
                          fontWeight: unread ? FontWeight.w800 : FontWeight.w600,
                          color: on.withOpacity(unread ? 1 : 0.8))),
                  const SizedBox(height: 2),
                  Text(n.body, style: TextStyle(fontSize: 13, color: on.withOpacity(0.65))),
                  const SizedBox(height: 8),
                  Row(children: [
                    Pill(catLabel(n.cat), col),
                    const SizedBox(width: 8),
                    Text(notifTime(n.at),
                        style: TextStyle(fontSize: 12, color: on.withOpacity(0.55))),
                  ]),
                ]),
              ),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: unread ? 10 : 0,
                  height: unread ? 10 : 0,
                  decoration: const BoxDecoration(color: kAccent, shape: BoxShape.circle),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class NotificationSettingsPage extends StatelessWidget {
  const NotificationSettingsPage({super.key});

  static const Map<String, String> desc = {
    'habit': 'A daily nudge, skipped once all your habits are done',
    'assignment': 'The day before and on the due date',
    'exam': '3 days before, the day before and on exam day',
    'attendance': 'Weekday prompt, skipped once you have marked it',
  };

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final on = onSurf(c);
          return RevealList(
            page: 'ns',
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              const SubHeader(title: 'Reminder settings', subtitle: 'Choose what and when'),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
                child: ValueListenableBuilder<bool>(
                  valueListenable: notifier.allowed,
                  builder: (ctx, ok, _) => Glass(
                    padding: const EdgeInsets.all(14),
                    child: Row(children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: (ok ? kPresent : kBad).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(15),
                        ),
                        child: Icon(
                          ok ? Icons.notifications_active_rounded : Icons.notifications_off_rounded,
                          color: ok ? kPresent : kBad,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(ok ? 'Notifications are on' : 'Notifications are blocked',
                              style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: on)),
                          Text(
                            ok
                                ? 'Reminders arrive even when the app is closed'
                                : "Allow them in your phone's Settings > Apps > StudyFlow",
                            style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6)),
                          ),
                        ]),
                      ),
                      const SizedBox(width: 8),
                      FilledButton.tonal(
                        onPressed: () async {
                          if (ok) {
                            await notifier.sendTest();
                          } else {
                            await notifier.requestPermission();
                          }
                        },
                        child: Text(ok ? 'Test' : 'Allow'),
                      ),
                    ]),
                  ),
                ),
              ),
              ...kNotifCats.map((cat) {
                final enabled = store.nOn[cat] == true;
                final mins = store.nTime[cat]!;
                final col = catColor(cat);
                return Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                  child: Glass(
                    padding: const EdgeInsets.all(14),
                    child: Column(children: [
                      Row(children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: col.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(15),
                          ),
                          child: Icon(catIcon(cat), color: col),
                        ),
                        const SizedBox(width: 14),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(catLabel(cat),
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: on)),
                            Text(desc[cat]!,
                                style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                          ]),
                        ),
                        Switch(
                          value: enabled,
                          activeTrackColor: kAccent,
                          onChanged: (v) => store.setNotifOn(cat, v),
                        ),
                      ]),
                      AnimatedSize(
                        duration: const Duration(milliseconds: 260),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: enabled
                            ? Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: GestureDetector(
                                  behavior: HitTestBehavior.opaque,
                                  onTap: () async {
                                    final t = await showTimePicker(
                                      context: c,
                                      initialTime: TimeOfDay(hour: mins ~/ 60, minute: mins % 60),
                                    );
                                    if (t != null) store.setNotifTime(cat, t.hour * 60 + t.minute);
                                  },
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                                    decoration: BoxDecoration(
                                      color: on.withOpacity(0.07),
                                      borderRadius: BorderRadius.circular(16),
                                    ),
                                    child: Row(children: [
                                      Icon(Icons.schedule_rounded, size: 20, color: col),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Text('Remind me at',
                                            style: TextStyle(color: on.withOpacity(0.7))),
                                      ),
                                      Text(
                                        TimeOfDay(hour: mins ~/ 60, minute: mins % 60).format(c),
                                        style: TextStyle(fontWeight: FontWeight.w800, color: on),
                                      ),
                                      const SizedBox(width: 6),
                                      Icon(Icons.edit_rounded, size: 16, color: on.withOpacity(0.5)),
                                    ]),
                                  ),
                                ),
                              )
                            : const SizedBox(width: double.infinity),
                      ),
                    ]),
                  ),
                );
              }),
              Padding(
                padding: const EdgeInsets.fromLTRB(26, 4, 26, 0),
                child: Text(
                  'Reminders stay in sync with your habits, assignments, exams and attendance. Completed or deleted items never send reminders.',
                  style: TextStyle(fontSize: 12, color: on.withOpacity(0.5)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}


// ───────────────────────── motion system ─────────────────────────
const kRevealDuration = Duration(milliseconds: 400);
const int kStaggerMs = 70;
const double kRevealShift = 18;

class _RevealData extends InheritedWidget {
  final Set<String> seen;
  const _RevealData({required this.seen, required super.child});
  static Set<String>? of(BuildContext c) =>
      c.getInheritedWidgetOfExactType<_RevealData>()?.seen;
  @override
  bool updateShouldNotify(_RevealData old) => false;
}

/// Remembers which items were already revealed while a screen is open,
/// so scrolling back never replays an animation. A new screen visit starts fresh.
class RevealScope extends StatefulWidget {
  final Widget child;
  const RevealScope({super.key, required this.child});
  @override
  State<RevealScope> createState() => _RevealScopeState();
}

class _RevealScopeState extends State<RevealScope> {
  final Set<String> _seen = {};
  @override
  Widget build(BuildContext context) => _RevealData(seen: _seen, child: widget.child);
}

/// Fade + upward slide. Staggered when the item is on screen as the page opens,
/// and triggered individually when it scrolls into view.
class Reveal extends StatefulWidget {
  final String id;
  final int index;
  final Widget child;
  Reveal({required this.id, this.index = 0, required this.child}) : super(key: ValueKey('rv_$id'));
  @override
  State<Reveal> createState() => _RevealState();
}

class _RevealState extends State<Reveal> {
  bool _shown = false;
  bool _first = true;
  Timer? _timer;
  ScrollPosition? _pos;
  Set<String>? _seen;

  @override
  void initState() {
    super.initState();
    _seen = _RevealData.of(context);
    if (_seen?.contains(widget.id) ?? false) {
      _shown = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _attach();
    });
  }

  void _attach() {
    if (_shown) return;
    _pos = Scrollable.maybeOf(context)?.position;
    _pos?.addListener(_check);
    _check();
  }

  void _check() {
    if (_shown || !mounted) return;
    final ro = context.findRenderObject();
    if (ro is! RenderBox || !ro.attached || !ro.hasSize) return;
    final top = ro.localToGlobal(Offset.zero).dy;
    final h = MediaQuery.sizeOf(context).height;
    if (top < h - 100) {
      _pos?.removeListener(_check);
      _seen?.add(widget.id);
      final delay = _first ? (widget.index < 8 ? widget.index : 8) * kStaggerMs : 0;
      if (delay == 0) {
        setState(() => _shown = true);
      } else {
        _timer = Timer(Duration(milliseconds: delay), () {
          if (mounted) setState(() => _shown = true);
        });
      }
    }
    _first = false;
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pos?.removeListener(_check);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return widget.child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: _shown ? 1.0 : 0.0),
      duration: kRevealDuration,
      curve: Curves.easeOutCubic,
      builder: (c, v, child) => Opacity(
        opacity: v,
        child: Transform.translate(offset: Offset(0, (1 - v) * kRevealShift), child: child),
      ),
      child: widget.child,
    );
  }
}

String _revealId(Widget w, Map<String, int> counts) {
  final k = w.key;
  if (k is ValueKey) return 'k:${k.value}';
  if (w is SectionTitle) return 'st:${w.text}';
  if (w is EmptyCard) return 'ec:${w.text}';
  final t = w.runtimeType.toString();
  final n = counts[t] ?? 0;
  counts[t] = n + 1;
  return '$t#$n';
}

/// Drop-in replacement for ListView(children: ...) that adds entrance and scroll reveals.
class RevealList extends StatelessWidget {
  final String page;
  final EdgeInsetsGeometry? padding;
  final List<Widget> children;
  const RevealList({super.key, required this.page, this.padding, required this.children});

  @override
  Widget build(BuildContext context) {
    final counts = <String, int>{};
    return RevealScope(
      child: ListView(
        padding: padding,
        children: [
          for (var i = 0; i < children.length; i++)
            Reveal(id: '$page/${_revealId(children[i], counts)}', index: i, child: children[i]),
        ],
      ),
    );
  }
}

/// Small scale + fade pop used for calendar event markers.
class PopIn extends StatelessWidget {
  final Widget child;
  const PopIn({super.key, required this.child});
  @override
  Widget build(BuildContext context) {
    if (MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (c, v, ch) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.6 + 0.4 * v, child: ch),
      ),
      child: child,
    );
  }
}

/// Tab transition: incoming screen slides in from the direction of travel,
/// the outgoing screen fades out the other way.
class AnimatedPage extends StatefulWidget {
  final int index;
  final List<Widget> pages;
  const AnimatedPage({super.key, required this.index, required this.pages});
  @override
  State<AnimatedPage> createState() => _AnimatedPageState();
}

class _AnimatedPageState extends State<AnimatedPage> {
  int _dir = 1;

  @override
  void didUpdateWidget(AnimatedPage old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _dir = widget.index > old.index ? 1 : -1;
  }

  @override
  Widget build(BuildContext context) {
    final reduce = MediaQuery.disableAnimationsOf(context);
    return AnimatedSwitcher(
      duration: reduce ? Duration.zero : const Duration(milliseconds: 300),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, anim) {
        final incoming = child.key == ValueKey<int>(widget.index);
        final dx = 0.12 * _dir;
        final slide = SlideTransition(
          position: Tween<Offset>(begin: Offset(incoming ? dx : -dx, 0), end: Offset.zero)
              .animate(anim),
          child: child,
        );
        return incoming ? slide : FadeTransition(opacity: anim, child: slide);
      },
      child: KeyedSubtree(key: ValueKey<int>(widget.index), child: widget.pages[widget.index]),
    );
  }
}



// ───────────────────────── habits: states, progress, streak tracker ─────────────────────────
enum HDay { inactive, complete, partial, missed, upcoming }

const kMissed = Color(0xFFDC2626);
const kPartial = kWarn;

DateTime addDays(DateTime d, int n) => DateTime(d.year, d.month, d.day + n);

String fastKey(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, "0")}-${d.day.toString().padLeft(2, "0")}';

/// One shared rule for habit week indicators, graph and streak calculations.
/// Complete = daily target reached. Partial = progress made, target not reached.
/// Missed = a finished day with no completion. Days before the habit existed are
/// inactive; today (not yet over) and future days with no progress are upcoming.
HDay habitDay(Habit h, DateTime d, DateTime today) {
  final k = dayKey(d);
  if (h.days.contains(k)) return HDay.complete;
  if ((h.progress[k] ?? 0) > 0) return HDay.partial;
  final c = h.created == null ? today : DateTime.parse(h.created!);
  if (d.isBefore(c)) return HDay.inactive;
  if (d.isBefore(today)) return HDay.missed;
  return HDay.upcoming;
}

BoxDecoration squareDeco(HDay st, Color on) {
  switch (st) {
    case HDay.complete:
      return BoxDecoration(color: kHabit, borderRadius: BorderRadius.circular(3.5));
    case HDay.partial:
      return BoxDecoration(color: kPartial, borderRadius: BorderRadius.circular(3.5));
    case HDay.missed:
      return BoxDecoration(color: kMissed.withOpacity(0.92), borderRadius: BorderRadius.circular(3.5));
    case HDay.upcoming:
      return BoxDecoration(
        borderRadius: BorderRadius.circular(3.5),
        border: Border.all(color: on.withOpacity(0.3), width: 1.2),
      );
    case HDay.inactive:
      return BoxDecoration(color: on.withOpacity(0.06), borderRadius: BorderRadius.circular(3.5));
  }
}

class HabitsTodayCard extends StatelessWidget {
  const HabitsTodayCard({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final total = store.habits.length;
        final key = dayKey(DateTime.now());
        var done = 0;
        var sum = 0.0;
        for (final h in store.habits) {
          if (h.days.contains(key)) {
            done++;
            sum += 1;
          } else {
            final cn = h.progress[key] ?? 0;
            if (cn > 0) sum += cn / h.target;
          }
        }
        var pct = total == 0 ? 0 : (sum * 100 / total).round();
        if (done < total && pct > 99) pct = 99;
        String msg;
        if (total == 0) {
          msg = 'Add a habit to get started';
        } else if (pct == 100) {
          msg = 'All habits completed!';
        } else if (pct >= 75) {
          msg = 'Almost there!';
        } else if (pct >= 50) {
          msg = 'On track';
        } else if (pct > 0) {
          msg = 'Great progress!';
        } else {
          msg = "Let's get started";
        }
        return Glass(
          padding: const EdgeInsets.all(18),
          onTap: () => openScreen(c, const HabitTrackerPage()),
          child: Row(children: [
            SizedBox(
              width: 96,
              height: 96,
              child: Stack(alignment: Alignment.center, children: [
                TweenAnimationBuilder<double>(
                  tween: Tween<double>(begin: 0, end: pct / 100),
                  duration: const Duration(milliseconds: 700),
                  curve: Curves.easeOutCubic,
                  builder: (ctx, v, _) => CustomPaint(
                    size: const Size.square(96),
                    painter: RingPainter(
                      v,
                      phaseColors(PomoPhase.focus).$1,
                      phaseColors(PomoPhase.focus).$2,
                      on.withOpacity(0.1),
                      stroke: 9,
                      inset: 8,
                    ),
                  ),
                ),
                Text('$pct%',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: on)),
              ]),
            ),
            const SizedBox(width: 18),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('Habits Today',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
                const SizedBox(height: 2),
                Text('$done/$total completed',
                    style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
                const SizedBox(height: 10),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  layoutBuilder: (cur, prev) => Stack(
                    alignment: Alignment.centerLeft,
                    children: [...prev, if (cur != null) cur],
                  ),
                  child: Pill(msg, kHabit, key: ValueKey(msg)),
                ),
              ]),
            ),
          ]),
        );
      },
    );
  }
}

class HabitReorderList extends StatelessWidget {
  const HabitReorderList({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) => ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.zero,
        itemCount: store.habits.length,
        onReorder: store.reorderHabits,
        proxyDecorator: (child, index, anim) => AnimatedBuilder(
          animation: anim,
          builder: (ctx, ch) {
            final t = Curves.easeOut.transform(anim.value);
            return Transform.scale(
              scale: 1 + 0.03 * t,
              child: Opacity(opacity: 1 - 0.12 * t, child: ch),
            );
          },
          child: Material(type: MaterialType.transparency, child: child),
        ),
        itemBuilder: (ctx, i) {
          final h = store.habits[i];
          return HabitTile(key: ValueKey('hab_${h.id}'), h: h);
        },
      ),
    );
  }
}


void openHabitDetailPage(BuildContext context, Habit habit) {
  Navigator.of(context).push(PageRouteBuilder<void>(
    transitionDuration: const Duration(milliseconds: 280),
    reverseTransitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (_, animation, __) => HabitDetailPage(habitId: habit.id),
    transitionsBuilder: (_, animation, __, child) => FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
      child: SlideTransition(
        position: Tween<Offset>(begin: const Offset(0.035, 0), end: Offset.zero)
            .animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic)),
        child: child,
      ),
    ),
  ));
}

class HabitDetailPage extends StatefulWidget {
  final String habitId;
  const HabitDetailPage({super.key, required this.habitId});
  @override
  State<HabitDetailPage> createState() => _HabitDetailPageState();
}

class _HabitDetailPageState extends State<HabitDetailPage> {
  bool editing = false;
  String period = 'Week';

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final matches = store.habits.where((h) => h.id == widget.habitId);
        if (matches.isEmpty) {
          return screenFrame(context, const Center(child: Text('This habit is no longer available.')));
        }
        final habit = matches.first;
        final on = onSurf(context);
        return screenFrame(context, Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
            child: Row(children: [
              GlassIconBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.of(context).pop()),
              const SizedBox(width: 14),
              Container(
                width: 44, height: 44, alignment: Alignment.center,
                decoration: BoxDecoration(color: kHabit.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
                child: Icon(habitIconData(habit.iconKey), color: kHabit, size: 23),
              ),
              const SizedBox(width: 12),
              Expanded(child: Text(habit.name, maxLines: 2, overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on))),
              IconButton(
                tooltip: 'Edit habit',
                onPressed: () => showHabitSheet(context, habit: habit),
                icon: Icon(Icons.edit_rounded, color: on.withOpacity(0.72)),
              ),
            ]),
          ),
          Expanded(child: ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 28), children: [
            Row(children: [
              const Expanded(child: SectionTitle('Calendar')),
              Text(editing ? 'Editing' : 'View only', style: TextStyle(fontSize: 11, color: editing ? kHabit : on.withOpacity(0.5), fontWeight: FontWeight.w700)),
            ]),
            HabitCalendarHeatmap(
              habit: habit,
              editing: editing,
              onDateTap: (date) => _editDate(context, habit, date),
            ),
            const SizedBox(height: 8),
            Center(child: TextButton.icon(
              onPressed: () => setState(() => editing = !editing),
              icon: Icon(editing ? Icons.check_rounded : Icons.edit_calendar_rounded, size: 18),
              label: Text(editing ? 'Done' : 'Edit'),
              style: TextButton.styleFrom(foregroundColor: kAccent),
            )),
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(child: SectionTitle('History')),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(color: on.withOpacity(0.07), borderRadius: BorderRadius.circular(13)),
                child: DropdownButtonHideUnderline(child: DropdownButton<String>(
                  value: period,
                  borderRadius: BorderRadius.circular(14),
                  dropdownColor: isDark(context) ? const Color(0xFF1B1636) : Colors.white,
                  style: TextStyle(color: on, fontWeight: FontWeight.w600, fontSize: 13),
                  icon: Icon(Icons.keyboard_arrow_down_rounded, color: on.withOpacity(0.65)),
                  items: const ['Week', 'Month', 'Quarter', 'Year'].map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
                  onChanged: (v) => setState(() => period = v ?? period),
                )),
              ),
            ]),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: HabitHistoryChart(key: ValueKey('$period|${habit.days.join("|")}'), habit: habit, period: period),
            ),
          ])),
        ]));
      },
    );
  }

  Future<void> _editDate(BuildContext context, Habit habit, DateTime date) async {
    if (dateOnly(date).isAfter(dateOnly(DateTime.now()))) return;
    final on = onSurf(context);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 34),
        child: Glass(
          radius: 24,
          padding: EdgeInsets.zero,
          opacity: isDark(dialogContext) ? 0.22 : 0.94,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(padding: const EdgeInsets.fromLTRB(20, 24, 20, 22), child: Column(children: [
              Text('Notes', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 5),
              Text(DateFormat('EEE, d MMM yyyy').format(date), style: TextStyle(fontSize: 12, color: on.withOpacity(0.55))),
            ])),
            Divider(height: 1, color: on.withOpacity(0.12)),
            Row(children: [
              Expanded(child: InkWell(
                borderRadius: const BorderRadius.only(bottomLeft: Radius.circular(24)),
                onTap: () { store.setHabitDay(habit, date, true); Navigator.pop(dialogContext); },
                child: const SizedBox(height: 68, child: Center(child: Icon(Icons.check_rounded, color: kHabit, size: 30))),
              )),
              Container(width: 1, height: 68, color: on.withOpacity(0.12)),
              Expanded(child: InkWell(
                borderRadius: const BorderRadius.only(bottomRight: Radius.circular(24)),
                onTap: () { store.setHabitDay(habit, date, false); Navigator.pop(dialogContext); },
                child: SizedBox(height: 68, child: Center(child: Icon(Icons.close_rounded, color: on.withOpacity(0.55), size: 30))),
              )),
            ]),
          ]),
        ),
      ),
    );
  }
}

class HabitCalendarHeatmap extends StatefulWidget {
  final Habit habit;
  final bool editing;
  final ValueChanged<DateTime> onDateTap;
  const HabitCalendarHeatmap({super.key, required this.habit, required this.editing, required this.onDateTap});

  @override
  State<HabitCalendarHeatmap> createState() => _HabitCalendarHeatmapState();
}

class _HabitCalendarHeatmapState extends State<HabitCalendarHeatmap> {
  late final ScrollController _monthController;
  late DateTime _historyStart;

  @override
  void initState() {
    super.initState();
    _historyStart = _startFor(widget.habit);
    _monthController = ScrollController();
  }

  DateTime _startFor(Habit habit) {
    final today = dateOnly(DateTime.now());
    final created = habit.created == null ? null : DateTime.tryParse(habit.created!);
    final earliestRecord = habit.days.isEmpty
        ? null
        : habit.days.map(DateTime.parse).map(dateOnly).reduce((a, b) => a.isBefore(b) ? a : b);
    final start = created ?? earliestRecord ?? today;
    final bounded = start.isAfter(today) ? today : start;
    return DateTime(bounded.year, bounded.month);
  }

  @override
  void didUpdateWidget(covariant HabitCalendarHeatmap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.habit.id != widget.habit.id || oldWidget.habit.created != widget.habit.created) {
      _historyStart = _startFor(widget.habit);
      if (_monthController.hasClients) _monthController.jumpTo(0);
    }
  }

  @override
  void dispose() {
    _monthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final today = dateOnly(DateTime.now());
    final monthCount = math.max(1, (today.year - _historyStart.year) * 12 + today.month - _historyStart.month + 1);
    final on = onSurf(context);
    return Glass(padding: const EdgeInsets.fromLTRB(12, 14, 12, 12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.editing) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text('Select a past or current date to update its status.', style: TextStyle(fontSize: 11, color: on.withOpacity(0.58)))),
      SizedBox(
        height: 24 + 7 * 31,
        child: ListView.builder(
          controller: _monthController,
          scrollDirection: Axis.horizontal,
          reverse: true,
          itemCount: monthCount,
          itemBuilder: (context, index) {
            // Index zero is the current month at the right edge; older months
            // are built lazily as the user scrolls towards the left.
            final month = DateTime(today.year, today.month - index);
            return _month(context, month, today, on);
          },
        ),
      ),
    ]));
  }

  Widget _month(BuildContext context, DateTime month, DateTime today, Color on) {
    final first = DateTime(month.year, month.month, 1);
    final offset = first.weekday - 1;
    final count = DateUtils.getDaysInMonth(month.year, month.month);
    final completed = widget.habit.days.toSet();
    final weeks = ((offset + count + 6) ~/ 7);
    // Keep the original month width and cell geometry; only visible months
    // are built by the horizontal ListView.
    return Padding(
      padding: const EdgeInsets.only(right: 14),
      child: SizedBox(
        width: 28 + weeks * 31,
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(height: 24, child: Text(DateFormat('MMM yyyy').format(month), style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: on.withOpacity(0.68)))),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Column(children: List.generate(7, (row) => SizedBox(
              width: 28, height: 31,
              child: Center(child: Text(const ['M','T','W','T','F','S','S'][row], style: TextStyle(fontSize: 9, color: on.withOpacity(0.42)))),
            ))),
            for (int week = 0; week < weeks; week++)
              Column(children: List.generate(7, (weekday) {
                final day = week * 7 + weekday - offset + 1;
                if (day < 1 || day > count) return const SizedBox(width: 31, height: 31);
                final date = DateTime(month.year, month.month, day);
                final future = date.isAfter(today);
                final done = completed.contains(dayKey(date));
                final fill = done ? kHabit : on.withOpacity(future ? 0.025 : 0.075);
                return Padding(padding: const EdgeInsets.all(1), child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(7),
                    onTap: widget.editing && !future ? () => widget.onDateTap(date) : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 180),
                      width: 29, height: 29,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: fill,
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: widget.editing && !future ? kAccent.withOpacity(0.34) : on.withOpacity(0.045)),
                      ),
                      child: Text('$day', style: TextStyle(fontSize: 10.5, fontWeight: done ? FontWeight.w800 : FontWeight.w500, color: done ? Colors.white : on.withOpacity(future ? 0.22 : 0.58))),
                    ),
                  ),
                ));
              })),
          ]),
        ]),
      ),
    );
  }
}

class _HabitBucket {
  final String label;
  final int value;
  const _HabitBucket(this.label, this.value);
}

List<_HabitBucket> _habitBuckets(Habit habit, String period) {
  final dates = habit.days.map(DateTime.parse).map(dateOnly).toSet();
  final now = dateOnly(DateTime.now());
  DateTime first;
  if (habit.created != null) {
    first = dateOnly(DateTime.tryParse(habit.created!) ?? now);
  } else if (dates.isNotEmpty) {
    first = dates.reduce((a, b) => a.isBefore(b) ? a : b);
  } else {
    first = now;
  }
  if (period == 'Week') {
    final currentMonday = now.subtract(Duration(days: now.weekday - 1));
    return List.generate(12, (i) {
      final monday = currentMonday.subtract(Duration(days: (11 - i) * 7));
      final count = dates.where((d) => !d.isBefore(monday) && d.isBefore(monday.add(const Duration(days: 7)))).length;
      return _HabitBucket(DateFormat('d/M').format(monday), count);
    });
  }
  if (period == 'Month') {
    final count = ((now.year - first.year) * 12 + now.month - first.month + 1).clamp(1, 12).toInt();
    return List.generate(count, (i) {
      final month = DateTime(now.year, now.month - count + i + 1);
      final value = dates.where((d) => d.year == month.year && d.month == month.month).length;
      return _HabitBucket(DateFormat('MMM').format(month), value);
    });
  }
  if (period == 'Quarter') {
    final currentQ = (now.month - 1) ~/ 3;
    return List.generate(8, (i) {
      final qIndex = now.year * 4 + currentQ - (7 - i);
      final year = qIndex ~/ 4;
      final q = qIndex % 4;
      final value = dates.where((d) => d.year == year && (d.month - 1) ~/ 3 == q).length;
      return _HabitBucket('Q${q + 1}\n$year', value);
    });
  }
  final firstYear = first.year;
  final years = (now.year - firstYear + 1).clamp(1, 12).toInt();
  return List.generate(years, (i) {
    final year = now.year - years + i + 1;
    return _HabitBucket('$year', dates.where((d) => d.year == year).length);
  });
}

class HabitHistoryChart extends StatelessWidget {
  final Habit habit;
  final String period;
  const HabitHistoryChart({super.key, required this.habit, required this.period});
  @override
  Widget build(BuildContext context) {
    final buckets = _habitBuckets(habit, period);
    final on = onSurf(context);
    final maxValue = buckets.fold<int>(0, (m, b) => m > b.value ? m : b.value);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Glass(padding: const EdgeInsets.fromLTRB(12, 16, 12, 14), child: Column(children: [
        if (habit.days.isEmpty)
          Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('No completed days recorded yet.', style: TextStyle(fontSize: 12, color: on.withOpacity(0.58)))),
        SizedBox(
          height: 205,
          child: LayoutBuilder(builder: (context, constraints) {
            final minBarWidth = period == 'Year' ? 38.0 : 32.0;
            final contentWidth = math.max(constraints.maxWidth, buckets.length * minBarWidth).toDouble();
            return SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SizedBox(width: contentWidth, height: 205, child: TweenAnimationBuilder<double>(
                tween: Tween<double>(begin: 0, end: 1),
                duration: const Duration(milliseconds: 360),
                curve: Curves.easeOutCubic,
                builder: (context, t, _) => CustomPaint(
                  painter: _HabitBarsPainter(buckets, maxValue, kHabit, on.withOpacity(0.12), on.withOpacity(0.62), t),
                ),
              )),
            );
          }),
        ),
        const SizedBox(height: 8),
        Text('Completed days', style: TextStyle(fontSize: 11, color: on.withOpacity(0.52))),
      ])),
    );
  }
}

class _HabitBarsPainter extends CustomPainter {
  final List<_HabitBucket> buckets;
  final int maxValue;
  final Color barColor, gridColor, labelColor;
  final double progress;
  _HabitBarsPainter(this.buckets, this.maxValue, this.barColor, this.gridColor, this.labelColor, this.progress);
  @override
  void paint(Canvas canvas, Size size) {
    const left = 8.0, right = 8.0, top = 22.0, bottom = 42.0;
    final chart = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final grid = Paint()..color = gridColor..strokeWidth = 1;
    final bars = Paint()..color = barColor;
    final maxScale = math.max(1, maxValue).toDouble();
    for (int i = 0; i <= 4; i++) {
      final y = chart.bottom - chart.height * i / 4;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), grid);
    }
    if (buckets.isEmpty) return;
    final slot = chart.width / buckets.length;
    final barWidth = math.min(22.0, slot * 0.56).toDouble();
    for (int i = 0; i < buckets.length; i++) {
      final bucket = buckets[i];
      final height = chart.height * bucket.value / maxScale * progress;
      final rect = RRect.fromRectAndRadius(Rect.fromLTWH(chart.left + slot * i + (slot - barWidth) / 2, chart.bottom - height, barWidth, height), const Radius.circular(5));
      if (bucket.value > 0) canvas.drawRRect(rect, bars);
      final label = TextPainter(text: TextSpan(text: '${bucket.value}', style: TextStyle(color: barColor, fontSize: 10, fontWeight: FontWeight.w800)), textDirection: TextDirection.ltr)..layout();
      label.paint(canvas, Offset(chart.left + slot * i + (slot - label.width) / 2, chart.bottom - height - label.height - 4));
      final xLabel = TextPainter(text: TextSpan(text: bucket.label, style: TextStyle(color: labelColor, fontSize: 9)), textAlign: TextAlign.center, textDirection: TextDirection.ltr, maxLines: 2)..layout(maxWidth: slot);
      xLabel.paint(canvas, Offset(chart.left + slot * i + (slot - xLabel.width) / 2, chart.bottom + 7));
    }
  }
  @override
  bool shouldRepaint(covariant _HabitBarsPainter old) => old.buckets != buckets || old.maxValue != maxValue || old.barColor != barColor || old.gridColor != gridColor || old.progress != progress;
}

Future<void> showHabitDetails(BuildContext context, Habit h) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final on = onSurf(ctx);
      final since = h.created == null ? null : DateTime.parse(h.created!);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 56,
                height: 56,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: kHabit.withOpacity(0.18),
                  borderRadius: BorderRadius.circular(18),
                ),
                child: Icon(habitIconData(h.iconKey), size: 28, color: kHabit),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(h.name,
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
                  if (since != null)
                    Text('Tracking since ${DateFormat("d MMM yyyy").format(since)}',
                        style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
                ]),
              ),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(child: MiniStat('${streak(h)}', 'Day streak', kWarn)),
              const SizedBox(width: 10),
              Expanded(child: MiniStat('${h.days.length}', 'Days done', kHabit)),
            ]),
            const SizedBox(height: 18),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showHabitSheet(context, habit: h);
                  },
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBad,
                    side: BorderSide(color: kBad.withOpacity(0.5)),
                  ),
                  onPressed: () async {
                    if (await confirmDelete(ctx, h.name)) {
                      store.deleteHabit(h.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                ),
              ),
            ]),
          ]),
        ),
      );
    },
  );
}

Future<void> showAssignmentDetails(BuildContext context, Assignment a) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      final on = onSurf(ctx);
      final c = typeColor(a.type);
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Pill(a.type, c),
              const SizedBox(width: 8),
              Pill(a.done ? 'Completed' : rel(a.date), a.done ? kHabit : kAccent),
            ]),
            const SizedBox(height: 14),
            Text(a.title, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
            if (a.subject.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(a.subject, style: TextStyle(fontSize: 14, color: on.withOpacity(0.65))),
              ),
            const SizedBox(height: 16),
            Row(children: [
              Icon(Icons.event_rounded, size: 18, color: c),
              const SizedBox(width: 8),
              Text(DateFormat('EEEE, d MMMM yyyy').format(a.date),
                  style: TextStyle(fontSize: 14, color: on.withOpacity(0.8))),
            ]),
            const SizedBox(height: 20),
            Row(children: [
              Expanded(
                child: FilledButton.tonalIcon(
                  onPressed: () {
                    Navigator.pop(ctx);
                    showAssignmentSheet(context, a: a);
                  },
                  icon: const Icon(Icons.edit_rounded, size: 18),
                  label: const Text('Edit'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: kBad,
                    side: BorderSide(color: kBad.withOpacity(0.5)),
                  ),
                  onPressed: () async {
                    if (await confirmDelete(ctx, a.title)) {
                      store.deleteAssignment(a.id);
                      if (ctx.mounted) Navigator.pop(ctx);
                    }
                  },
                  icon: const Icon(Icons.delete_outline_rounded, size: 18),
                  label: const Text('Delete'),
                ),
              ),
            ]),
          ]),
        ),
      );
    },
  );
}

class GPoint {
  final String label;
  final double? value;
  const GPoint(this.label, this.value);
}

/// Completion rate (%) per bucket, from the same records as everything else.
/// Only finished days (or days already completed) count, so an unfinished
/// today never lowers the rate.
List<GPoint> graphPoints(String period, String habitId) {
  final today = dateOnly(DateTime.now());
  final habits =
      habitId == 'all' ? store.habits : store.habits.where((h) => h.id == habitId).toList();
  final sets = {for (final h in habits) h.id: h.days.toSet()};
  final created = {
    for (final h in habits) h.id: h.created == null ? today : DateTime.parse(h.created!),
  };

  double? rate(DateTime a, DateTime b) {
    var done = 0.0, total = 0;
    for (var d = a; !d.isAfter(b) && !d.isAfter(today); d = addDays(d, 1)) {
      final k = fastKey(d);
      for (final h in habits) {
        if (sets[h.id]!.contains(k)) {
          done += 1;
          total++;
        } else if ((h.progress[k] ?? 0) > 0) {
          done += h.progress[k]! / h.target;
          total++;
        } else if (!d.isBefore(created[h.id]!) && d.isBefore(today)) {
          total++;
        }
      }
    }
    return total == 0 ? null : done * 100 / total;
  }

  final pts = <GPoint>[];
  if (period == 'Day') {
    for (var i = 13; i >= 0; i--) {
      final d = addDays(today, -i);
      pts.add(GPoint('${d.day}', rate(d, d)));
    }
  } else if (period == 'Week') {
    final mon = addDays(today, -(today.weekday - 1));
    for (var i = 11; i >= 0; i--) {
      final st = addDays(mon, -7 * i);
      pts.add(GPoint('${st.day}/${st.month}', rate(st, addDays(st, 6))));
    }
  } else if (period == 'Month') {
    for (var i = 11; i >= 0; i--) {
      final st = DateTime(today.year, today.month - i, 1);
      pts.add(GPoint(DateFormat('MMM').format(st), rate(st, DateTime(st.year, st.month + 1, 0))));
    }
  } else if (period == 'Quarter') {
    final q0 = DateTime(today.year, ((today.month - 1) ~/ 3) * 3 + 1, 1);
    for (var i = 7; i >= 0; i--) {
      final st = DateTime(q0.year, q0.month - 3 * i, 1);
      pts.add(GPoint('Q${(st.month - 1) ~/ 3 + 1} ${st.year % 100}',
          rate(st, DateTime(st.year, st.month + 3, 0))));
    }
  } else {
    for (var i = 4; i >= 0; i--) {
      final y = today.year - i;
      pts.add(GPoint('$y', rate(DateTime(y, 1, 1), DateTime(y, 12, 31))));
    }
  }
  return pts;
}

class LineGraphPainter extends CustomPainter {
  final List<GPoint> pts;
  final Color line, text, grid;
  LineGraphPainter(this.pts, this.line, this.text, this.grid);

  void _label(Canvas canvas, String t, Offset at, double size, Color color, {bool center = false}) {
    final tp = TextPainter(
      text: TextSpan(text: t, style: TextStyle(fontSize: size, color: color)),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, center ? Offset(at.dx - tp.width / 2, at.dy) : at);
  }

  @override
  void paint(Canvas canvas, Size size) {
    const left = 34.0, right = 10.0, top = 10.0, bottom = 24.0;
    final w = size.width - left - right;
    final h = size.height - top - bottom;
    final n = pts.length;
    if (n == 0 || w <= 0 || h <= 0) return;
    double xAt(int i) => n == 1 ? left + w / 2 : left + w * i / (n - 1);
    double yAt(double v) => top + h * (1 - v / 100);

    final gp = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final v in [0, 50, 100]) {
      final y = yAt(v.toDouble());
      canvas.drawLine(Offset(left, y), Offset(size.width - right, y), gp);
      _label(canvas, '$v%', Offset(0, y - 6), 10.5, text.withOpacity(0.55));
    }

    final linePaint = Paint()
      ..color = line
      ..strokeWidth = 2.4
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    var run = <Offset>[];
    void flush() {
      if (run.length >= 2) {
        final path = Path()..moveTo(run.first.dx, run.first.dy);
        for (final o in run.skip(1)) {
          path.lineTo(o.dx, o.dy);
        }
        final area = Path.from(path)
          ..lineTo(run.last.dx, top + h)
          ..lineTo(run.first.dx, top + h)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [line.withOpacity(0.28), line.withOpacity(0)],
            ).createShader(Rect.fromLTWH(left, top, w, h)),
        );
        canvas.drawPath(path, linePaint);
      }
      run = <Offset>[];
    }

    for (var i = 0; i < n; i++) {
      final v = pts[i].value;
      if (v == null) {
        flush();
      } else {
        run.add(Offset(xAt(i), yAt(v)));
      }
    }
    flush();

    for (var i = 0; i < n; i++) {
      final v = pts[i].value;
      if (v == null) continue;
      final o = Offset(xAt(i), yAt(v));
      canvas.drawCircle(o, 6.5, Paint()..color = line.withOpacity(0.22));
      canvas.drawCircle(o, 3.6, Paint()..color = line);
    }

    final dx = n == 1 ? w : w / (n - 1);
    final step = (38 / dx).ceil().clamp(1, n).toInt();
    for (var i = n - 1; i >= 0; i -= step) {
      _label(canvas, pts[i].label, Offset(xAt(i), size.height - bottom + 7), 10,
          text.withOpacity(0.6),
          center: true);
    }
  }

  @override
  bool shouldRepaint(LineGraphPainter old) => true;
}

class HabitGraphCard extends StatefulWidget {
  const HabitGraphCard({super.key});
  @override
  State<HabitGraphCard> createState() => _HabitGraphCardState();
}

class _HabitGraphCardState extends State<HabitGraphCard> {
  String period = 'Week';
  String habitId = 'all';

  Widget _dropdown<T>(BuildContext c, T value, List<DropdownMenuItem<T>> items, ValueChanged<T?> onCh) {
    final on = onSurf(c);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: on.withOpacity(0.07),
        borderRadius: BorderRadius.circular(14),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          borderRadius: BorderRadius.circular(16),
          dropdownColor: isDark(c) ? const Color(0xFF1B1636) : Colors.white,
          icon: Icon(Icons.keyboard_arrow_down_rounded, color: on.withOpacity(0.6)),
          style: TextStyle(color: on, fontSize: 14, fontWeight: FontWeight.w600),
          items: items,
          onChanged: onCh,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final habits = store.habits;
        final sel = (habitId == 'all' || habits.any((h) => h.id == habitId)) ? habitId : 'all';
        final pts = graphPoints(period, sel);
        final vals = pts.where((p) => p.value != null).map((p) => p.value!).toList();
        final avg = vals.isEmpty ? null : vals.reduce((a, b) => a + b) / vals.length;
        var cur = 0;
        for (final h in habits) {
          if (sel == 'all' || h.id == sel) {
            final s = streak(h);
            if (s > cur) cur = s;
          }
        }
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
          child: Glass(
            padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: _dropdown<String>(
                    c,
                    period,
                    const ['Day', 'Week', 'Month', 'Quarter', 'Year']
                        .map((e) => DropdownMenuItem(value: e, child: Text(e)))
                        .toList(),
                    (v) => setState(() => period = v ?? period),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: _dropdown<String>(
                    c,
                    sel,
                    [
                      const DropdownMenuItem(value: 'all', child: Text('Overall')),
                      ...habits.map((h) => DropdownMenuItem(
                            value: h.id,
                            child: Text(h.name, overflow: TextOverflow.ellipsis),
                          )),
                    ],
                    (v) => setState(() => habitId = v ?? 'all'),
                  ),
                ),
              ]),
              const SizedBox(height: 14),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: SizedBox(
                  key: ValueKey('$period|$sel'),
                  height: 190,
                  width: double.infinity,
                  child: CustomPaint(
                    painter: LineGraphPainter(pts, kHabit, on, on.withOpacity(0.1)),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(child: MiniStat(avg == null ? '–' : '${avg.round()}%', 'Avg rate', kHabit)),
                const SizedBox(width: 10),
                Expanded(child: MiniStat('$cur', sel == 'all' ? 'Best streak' : 'Streak', kWarn)),
              ]),
            ]),
          ),
        );
      },
    );
  }
}


// ───────────────────────── tools hub ─────────────────────────
/// Every tool in the hub is described by a ToolDef. Adding a future tool means
/// adding one entry to kTools plus its page; nothing else changes.
class ToolDef {
  final String name, desc;
  final IconData icon;
  final Color color;
  final Widget Function() page;
  const ToolDef({
    required this.name,
    required this.desc,
    required this.icon,
    required this.color,
    required this.page,
  });
}

const kHabitTool = Color(0xFF6366F1);

final List<ToolDef> kTools = [
  ToolDef(
    name: 'Habit Tracker',
    desc: 'Build habits and track your streaks.',
    icon: Icons.track_changes_rounded,
    color: kHabitTool,
    page: () => const HabitTrackerPage(),
  ),
  ToolDef(
    name: 'Quick Links',
    desc: 'Shortcuts to the websites you use most',
    icon: Icons.link_rounded,
    color: kAccent,
    page: () => const QuickLinksPage(),
  ),
  ToolDef(
    name: 'Pomodoro Timer',
    desc: 'Focus, take breaks and stay productive.',
    icon: Icons.timer_rounded,
    color: kPomo,
    page: () => const PomodoroSetupPage(),
  ),
  ToolDef(
    name: 'PDF Reader',
    desc: 'Read, search and organise your PDFs offline.',
    icon: Icons.picture_as_pdf_rounded,
    color: kPdfTool,
    page: () => const PdfLibraryPage(),
  ),
];

class ToolsHubPage extends StatelessWidget {
  const ToolsHubPage({super.key});
  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      RevealList(
        page: 'tools',
        padding: const EdgeInsets.only(bottom: 40),
        children: [
          const SubHeader(title: 'Tools Hub', subtitle: 'Handy utilities in one place'),
          ...kTools.map((t) => ToolTile(key: ValueKey('tool_${t.name}'), tool: t)),
        ],
      ),
    );
  }
}

class ToolTile extends StatelessWidget {
  final ToolDef tool;
  const ToolTile({super.key, required this.tool});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
      child: Glass(
        padding: const EdgeInsets.all(16),
        onTap: () => openScreen(context, tool.page()),
        child: Row(children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: tool.color.withOpacity(0.2),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(tool.icon, color: tool.color, size: 26),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(tool.name,
                  style: TextStyle(fontSize: 16.5, fontWeight: FontWeight.w700, color: on)),
              const SizedBox(height: 2),
              Text(tool.desc, style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
            ]),
          ),
          Icon(Icons.chevron_right_rounded, color: on.withOpacity(0.5)),
        ]),
      ),
    );
  }
}

// ───────────────────────── quick links ─────────────────────────
const Map<String, IconData> kLinkIcons = {
  'link': Icons.link_rounded,
  'leave': Icons.event_busy_rounded,
  'results': Icons.emoji_events_rounded,
  'materials': Icons.menu_book_rounded,
  'fee': Icons.payments_rounded,
  'school': Icons.school_rounded,
  'assignment': Icons.assignment_rounded,
  'calendar': Icons.calendar_month_rounded,
  'library': Icons.local_library_rounded,
  'mail': Icons.mail_rounded,
  'video': Icons.play_circle_rounded,
  'forum': Icons.forum_rounded,
  'cloud': Icons.cloud_rounded,
  'work': Icons.work_rounded,
  'code': Icons.code_rounded,
  'science': Icons.science_rounded,
  'web': Icons.language_rounded,
  'bank': Icons.account_balance_rounded,
  'badge': Icons.badge_rounded,
  'news': Icons.newspaper_rounded,
  'download': Icons.download_rounded,
  'quiz': Icons.quiz_rounded,
};

const List<Color> kLinkColors = [kAccent, kAssign, kHabit, kExam, kWarn];

IconData linkIcon(String key) => kLinkIcons[key] ?? Icons.link_rounded;

Color linkColor(String key) {
  final i = kLinkIcons.keys.toList().indexOf(key);
  return kLinkColors[(i < 0 ? 0 : i) % kLinkColors.length];
}

class QuickLink {
  String id, name, url, icon;
  QuickLink({required this.id, required this.name, required this.url, required this.icon});
  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'url': url, 'icon': icon};
  factory QuickLink.fromJson(Map<String, dynamic> j) => QuickLink(
        id: j['id'],
        name: j['name'],
        url: j['url'],
        icon: j['icon'] ?? 'link',
      );
}

/// Returns a clean http(s) URL, adding https:// when no scheme was typed,
/// or null when the text is not a usable web address.
String? normalizeUrl(String raw) {
  var t = raw.trim();
  if (t.isEmpty || t.contains(' ')) return null;
  if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://').hasMatch(t)) t = 'https://$t';
  final u = Uri.tryParse(t);
  if (u == null || (u.scheme != 'http' && u.scheme != 'https')) return null;
  if (u.host.isEmpty || !u.host.contains('.') || u.host.endsWith('.')) return null;
  return u.toString();
}

Future<void> openQuickLink(BuildContext context, QuickLink l) async {
  var ok = false;
  final uri = Uri.tryParse(l.url);
  if (uri != null) {
    try {
      ok = await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {
      ok = false;
    }
  }
  if (!ok && context.mounted) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text("Couldn't open \"${l.name}\". Check the link and try again."),
      ));
  }
}

Future<void> showQuickLinkSheet(BuildContext context, {QuickLink? link}) {
  final name = TextEditingController(text: link?.name ?? '');
  final url = TextEditingController(text: link?.url ?? '');
  var icon = link?.icon ?? 'link';
  String? nameErr, urlErr;
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      final on = onSurf(ctx);

      void save() {
        final n = name.text.trim();
        final u = normalizeUrl(url.text);
        set(() {
          nameErr = n.isEmpty ? 'Enter a card name' : null;
          urlErr = url.text.trim().isEmpty
              ? 'Enter a website link'
              : (u == null ? 'Enter a valid link, like example.com' : null);
        });
        if (n.isEmpty || u == null) return;
        if (link == null) {
          store.addLink(QuickLink(id: newId(), name: n, url: u, icon: icon));
        } else {
          link.name = n;
          link.url = u;
          link.icon = icon;
          store.updateLink(link);
        }
        Navigator.pop(ctx);
      }

      return keyboardAwareSheet(
        ctx,
        Glass(
          radius: 30,
          opacity: isDark(ctx) ? 0.18 : 0.9,
          padding: const EdgeInsets.all(22),
          child: SingleChildScrollView(
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(link == null ? 'New quick link' : 'Edit quick link',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                textInputAction: TextInputAction.next,
                textCapitalization: TextCapitalization.sentences,
                inputFormatters: [LengthLimitingTextInputFormatter(40)],
                decoration: deco(ctx, 'Card name (e.g. Apply for Leave)').copyWith(errorText: nameErr),
                onChanged: (_) {
                  if (nameErr != null) set(() => nameErr = null);
                },
              ),
              const SizedBox(height: 12),
              TextField(
                controller: url,
                keyboardType: TextInputType.url,
                textInputAction: TextInputAction.done,
                autocorrect: false,
                decoration: deco(ctx, 'Website URL (e.g. example.com)').copyWith(errorText: urlErr),
                onChanged: (_) {
                  if (urlErr != null) set(() => urlErr = null);
                },
                onSubmitted: (_) => save(),
              ),
              const SizedBox(height: 16),
              Text('Icon', style: TextStyle(fontSize: 13, color: on.withOpacity(0.6))),
              const SizedBox(height: 10),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: kLinkIcons.entries.map((e) {
                  final sel = e.key == icon;
                  final col = linkColor(e.key);
                  return GestureDetector(
                    onTap: () => set(() => icon = e.key),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: sel ? col.withOpacity(0.25) : on.withOpacity(0.07),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: sel ? col : Colors.transparent, width: 2),
                      ),
                      child: Icon(e.value, size: 22, color: sel ? col : on.withOpacity(0.65)),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: kAccent,
                    padding: const EdgeInsets.symmetric(vertical: 15),
                  ),
                  onPressed: save,
                  child: Text(link == null ? 'Add quick link' : 'Save changes',
                      style: const TextStyle(fontSize: 16)),
                ),
              ),
            ]),
          ),
        ),
      );
    }),
  );
}

class QuickLinksPage extends StatefulWidget {
  const QuickLinksPage({super.key});
  @override
  State<QuickLinksPage> createState() => _QuickLinksPageState();
}

class _QuickLinksPageState extends State<QuickLinksPage> {
  final Set<String> _removing = {};

  Future<void> _delete(BuildContext c, QuickLink l) async {
    if (!await confirmDelete(c, l.name)) return;
    if (mounted) setState(() => _removing.add(l.id));
    await Future.delayed(const Duration(milliseconds: 240));
    store.deleteLink(l.id);
    if (mounted) setState(() => _removing.remove(l.id));
  }

  Widget _empty(BuildContext c) {
    final on = onSurf(c);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
      child: Glass(
        padding: const EdgeInsets.symmetric(vertical: 30, horizontal: 22),
        child: SizedBox(
          width: double.infinity,
          child: Column(children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: kAccent.withOpacity(0.2),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Icon(Icons.link_rounded, size: 30, color: kAccent),
            ),
            const SizedBox(height: 14),
            Text('No quick links yet',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 6),
            Text(
              'Save the websites you open most, like results, fee payment or leave forms.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: on.withOpacity(0.6)),
            ),
            const SizedBox(height: 18),
            FilledButton.icon(
              style: FilledButton.styleFrom(backgroundColor: kAccent),
              onPressed: () => showQuickLinkSheet(c),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add quick link'),
            ),
          ]),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final links = store.links;
          return ListView(
            padding: const EdgeInsets.only(bottom: 40),
            children: [
              SubHeader(
                title: 'Quick Links',
                subtitle: links.isEmpty
                    ? 'Save your favourite websites'
                    : '${links.length} saved',
                actions: [GlassIconBtn(Icons.add_rounded, () => showQuickLinkSheet(c))],
              ),
              if (links.isEmpty)
                _empty(c)
              else
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    padding: EdgeInsets.zero,
                    gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 180,
                      mainAxisSpacing: 12,
                      crossAxisSpacing: 12,
                      childAspectRatio: 1.0,
                    ),
                    itemCount: links.length,
                    itemBuilder: (ctx, i) {
                      final l = links[i];
                      return QuickLinkCard(
                        key: ValueKey(l.id),
                        link: l,
                        index: i,
                        removing: _removing.contains(l.id),
                        onOpen: () => openQuickLink(ctx, l),
                        onEdit: () => showQuickLinkSheet(ctx, link: l),
                        onDelete: () => _delete(ctx, l),
                      );
                    },
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class QuickLinkCard extends StatelessWidget {
  final QuickLink link;
  final int index;
  final bool removing;
  final VoidCallback onOpen, onEdit, onDelete;
  const QuickLinkCard({
    super.key,
    required this.link,
    required this.index,
    required this.removing,
    required this.onOpen,
    required this.onEdit,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final col = linkColor(link.icon);
    final reduce = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: reduce ? Duration.zero : Duration(milliseconds: 320 + (index < 8 ? index : 8) * 40),
      curve: Curves.easeOutCubic,
      builder: (c, v, child) => Opacity(
        opacity: v,
        child: Transform.scale(scale: 0.92 + 0.08 * v, child: child),
      ),
      child: AnimatedScale(
        scale: removing ? 0.85 : 1,
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeInCubic,
        child: AnimatedOpacity(
          opacity: removing ? 0 : 1,
          duration: const Duration(milliseconds: 220),
          child: Glass(
            padding: const EdgeInsets.all(14),
            onTap: removing ? null : onOpen,
            child: Stack(clipBehavior: Clip.none, children: [
              Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 220),
                    transitionBuilder: (child, anim) =>
                        ScaleTransition(scale: anim, child: FadeTransition(opacity: anim, child: child)),
                    child: Container(
                      key: ValueKey(link.icon),
                      width: 58,
                      height: 58,
                      decoration: BoxDecoration(
                        color: col.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      child: Icon(linkIcon(link.icon), size: 28, color: col),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text(link.name,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: on)),
                ]),
              ),
              Positioned(
                top: -4,
                right: -6,
                child: SizedBox(
                  width: 36,
                  height: 36,
                  child: PopupMenuButton<String>(
                    padding: EdgeInsets.zero,
                    tooltip: 'More',
                    icon: Icon(Icons.more_vert_rounded, size: 20, color: on.withOpacity(0.55)),
                    color: isDark(context) ? const Color(0xFF1B1636) : Colors.white,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    onSelected: (v) => v == 'edit' ? onEdit() : onDelete(),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Row(children: [
                          Icon(Icons.edit_rounded, size: 18, color: on),
                          const SizedBox(width: 10),
                          Text('Edit', style: TextStyle(color: on)),
                        ]),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Row(children: [
                          Icon(Icons.delete_outline_rounded, size: 18, color: kBad),
                          SizedBox(width: 10),
                          Text('Delete', style: TextStyle(color: kBad)),
                        ]),
                      ),
                    ],
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}


// ───────────────────────── pomodoro ─────────────────────────
const kPomo = Color(0xFFEC4899);

enum PomoPhase { focus, shortBreak }
enum PomoStatus { idle, running, paused, awaiting }

String phaseLabel(PomoPhase p) => p == PomoPhase.focus ? 'Focus' : 'Short Break';

(Color, Color) phaseColors(PomoPhase p) {
  if (p == PomoPhase.focus) return (const Color(0xFF8B5CF6), const Color(0xFF38BDF8));
  return (const Color(0xFF4ADE80), const Color(0xFF22D3EE));
}

String fmtFocusTime(int seconds) {
  if (seconds < 60) return '${seconds}s';
  final m = seconds ~/ 60;
  if (m >= 60) return '${m ~/ 60}h ${m % 60}m';
  final r = seconds % 60;
  return r == 0 ? '${m}m' : '${m}m ${r}s';
}

// ───────── completion sound ─────────
final pomoAudio = PomoAudio();

/// Plays the user's chosen completion sound. Playback is guarded against rapid
/// duplicate triggers, and a missing file simply reports failure.
class PomoAudio {
  AudioPlayer? _p;
  final ValueNotifier<bool> playing = ValueNotifier<bool>(false);
  DateTime? _last;

  AudioPlayer _player() {
    var p = _p;
    if (p == null) {
      p = AudioPlayer();
      p.onPlayerStateChanged.listen((st) => playing.value = st == PlayerState.playing);
      _p = p;
    }
    return p;
  }

  /// One shared player: it is always stopped before anything new is played, so
  /// two instances can never overlap. [loop] repeats until stop() is called.
  Future<bool> play(String path, {bool preview = false, bool loop = false}) async {
    final now = DateTime.now();
    if (!preview && _last != null && now.difference(_last!) < const Duration(milliseconds: 800)) {
      return true;
    }
    _last = now;
    try {
      if (!File(path).existsSync()) return false;
      final p = _player();
      await p.stop();
      await p.setReleaseMode(loop ? ReleaseMode.loop : ReleaseMode.stop);
      await p.play(DeviceFileSource(path));
      return true;
    } catch (_) {
      playing.value = false;
      return false;
    }
  }

  Future<void> stop() async {
    try {
      await _p?.stop();
      await _p?.setReleaseMode(ReleaseMode.stop);
      await _p?.release();
    } catch (_) {}
    playing.value = false;
  }

  Uint8List? _chime;

  /// A short two-note chime generated in code (no audio asset needed).
  Uint8List _chimeBytes() {
    final cached = _chime;
    if (cached != null) return cached;
    const sr = 44100;
    final n = (sr * 1.1).toInt();
    final data = ByteData(44 + n * 2);
    void tag(int o, String t) {
      for (var i = 0; i < t.length; i++) {
        data.setUint8(o + i, t.codeUnitAt(i));
      }
    }

    tag(0, 'RIFF');
    data.setUint32(4, 36 + n * 2, Endian.little);
    tag(8, 'WAVE');
    tag(12, 'fmt ');
    data.setUint32(16, 16, Endian.little);
    data.setUint16(20, 1, Endian.little);
    data.setUint16(22, 1, Endian.little);
    data.setUint32(24, sr, Endian.little);
    data.setUint32(28, sr * 2, Endian.little);
    data.setUint16(32, 2, Endian.little);
    data.setUint16(34, 16, Endian.little);
    tag(36, 'data');
    data.setUint32(40, n * 2, Endian.little);
    for (var i = 0; i < n; i++) {
      final t = i / sr;
      var v = math.sin(2 * math.pi * 880 * t) * math.exp(-4.0 * t);
      final t2 = t - 0.28;
      if (t2 >= 0) v += math.sin(2 * math.pi * 1318.5 * t2) * math.exp(-3.5 * t2);
      final attack = math.min(1.0, t * 200);
      final sample = (v * 0.35 * attack * 32767).round().clamp(-32768, 32767).toInt();
      data.setInt16(44 + i * 2, sample, Endian.little);
    }
    return _chime = data.buffer.asUint8List();
  }

  Future<void> playChime() async {
    try {
      final p = _player();
      await p.stop();
      await p.setReleaseMode(ReleaseMode.stop);
      await p.play(BytesSource(_chimeBytes(), mimeType: 'audio/wav'));
    } catch (_) {
      playing.value = false;
    }
  }
}

/// Opens the system picker (Storage Access Framework, no storage permission),
/// then keeps a private copy so the choice survives restarts. Returns an error
/// message, or null on success or cancel.
Future<String?> pickPomoSound() async {
  try {
    final res = await FilePicker.platform.pickFiles(type: FileType.audio, allowMultiple: false);
    if (res == null || res.files.isEmpty) return null;
    final f = res.files.first;
    final src = f.path;
    if (src == null) return "Couldn't read that file. Try another one.";
    final dot = f.name.lastIndexOf('.');
    final ext = dot >= 0 && dot < f.name.length - 1 ? f.name.substring(dot + 1).toLowerCase() : 'mp3';
    final dir = await getApplicationSupportDirectory();
    final dest = '${dir.path}/pomodoro_sound_${DateTime.now().millisecondsSinceEpoch}.$ext';
    await File(src).copy(dest);
    final old = store.pomoSoundPath;
    store.setPomoSound(dest, f.name);
    if (old != null) {
      try {
        await File(old).delete();
      } catch (_) {}
    }
    return null;
  } catch (_) {
    return "Couldn't load that sound. Try another file.";
  }
}

Future<void> removePomoSound() async {
  final old = store.pomoSoundPath;
  store.clearPomoSound();
  if (old != null) {
    try {
      await File(old).delete();
    } catch (_) {}
  }
}

final pomodoro = PomodoroEngine();

/// Deadline-based timer. The remaining time is always computed from the wall
/// clock, so it stays correct across pauses, backgrounding and screen changes.
/// When a countdown ends the engine stops and waits (awaiting) until the user
/// confirms the next session; nothing ever starts on its own.
class PomodoroEngine extends ChangeNotifier {
  PomoPhase phase = PomoPhase.focus;
  PomoStatus status = PomoStatus.idle;
  bool sessionActive = false;
  int focusSec = 1500, shortSec = 300, cycles = 4; // durations in seconds
  int focusIndex = 0; // focus sessions moved past (completed or skipped) in this cycle
  bool _foreground = true;
  DateTime? _endAt;
  Duration _left = const Duration(minutes: 25);
  Timer? _timer;

  bool get awaiting => status == PomoStatus.awaiting;

  Duration dur(PomoPhase p) => Duration(seconds: p == PomoPhase.focus ? focusSec : shortSec);

  Duration get total => dur(phase);

  Duration get remaining {
    if (status == PomoStatus.running && _endAt != null) {
      final d = _endAt!.difference(DateTime.now());
      return d.isNegative ? Duration.zero : d;
    }
    return _left;
  }

  double get fraction {
    final t = total.inMilliseconds;
    return t == 0 ? 0 : (remaining.inMilliseconds / t).clamp(0.0, 1.0).toDouble();
  }

  /// Session number for the current phase. While a focus session is waiting for
  /// confirmation, or during its break, it is the session that was just finished.
  int get sessionNumber {
    if (phase == PomoPhase.focus) return (focusIndex % cycles) + 1;
    return focusIndex < 1 ? 1 : (focusIndex > cycles ? cycles : focusIndex);
  }

  void configure({required int focus, required int shortB, required int cyc}) {
    focusSec = focus;
    shortSec = shortB;
    cycles = cyc < 1 ? 1 : cyc;
    if (status == PomoStatus.idle && !sessionActive) {
      phase = PomoPhase.focus;
      focusIndex = 0;
      _left = dur(phase);
    }
    notifyListeners();
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 250), (_) => tick());
  }

  void _stopTimer() {
    _timer?.cancel();
    _timer = null;
  }

  void start() {
    if (status == PomoStatus.running || status == PomoStatus.awaiting) return;
    _endAt = DateTime.now().add(_left);
    status = PomoStatus.running;
    sessionActive = true;
    _startTimer();
    notifyListeners();
  }

  void pause() {
    if (status != PomoStatus.running) return;
    _left = remaining;
    _endAt = null;
    _stopTimer();
    status = PomoStatus.paused;
    notifier.pomoCancel();
    notifyListeners();
  }

  void reset() {
    if (status == PomoStatus.awaiting) return;
    _stopTimer();
    _endAt = null;
    status = PomoStatus.idle;
    _left = dur(phase);
    notifier.pomoCancel();
    notifyListeners();
  }

  void stop() {
    _stopTimer();
    pomoAudio.stop();
    _endAt = null;
    status = PomoStatus.idle;
    phase = PomoPhase.focus;
    focusIndex = 0;
    sessionActive = false;
    _left = dur(PomoPhase.focus);
    notifier.pomoCancel();
    notifyListeners();
  }

  /// Moves to the next phase, ready but not started, without counting the
  /// skipped one as completed.
  void skip() {
    if (status == PomoStatus.awaiting) return;
    _stopTimer();
    _endAt = null;
    _moveToNext();
    status = PomoStatus.idle;
    notifier.pomoCancel();
    notifyListeners();
  }

  /// Focus is always followed by a short break, and a break by the next focus.
  /// After the last focus session of a cycle (and its break) a new cycle begins.
  void _moveToNext() {
    if (phase == PomoPhase.focus) {
      focusIndex++;
      phase = PomoPhase.shortBreak;
    } else {
      phase = PomoPhase.focus;
      if (focusIndex >= cycles) focusIndex = 0;
    }
    _left = dur(phase);
  }

  void tick() {
    if (status != PomoStatus.running || _endAt == null) return;
    final now = DateTime.now();
    if (now.isBefore(_endAt!)) return;
    _complete(now.difference(_endAt!));
  }

  /// Runs exactly once per countdown: the status leaves "running" before
  /// anything else happens, so a second tick can never record it again.
  void _complete(Duration lateness) {
    _stopTimer();
    status = PomoStatus.awaiting;
    _endAt = null;
    _left = Duration.zero;
    final wasFocus = phase == PomoPhase.focus;
    if (wasFocus) {
      store.addPomoFocus(dur(phase).inSeconds);
    } else {
      store.addPomoBreak();
    }
    _announce(wasFocus, lateness);
    notifyListeners();
  }

  /// The user confirmed the next session: the sound stops first, then the next
  /// countdown begins.
  Future<void> startNext() async {
    if (status != PomoStatus.awaiting) return;
    try {
      await pomoAudio.stop().timeout(const Duration(milliseconds: 800));
    } catch (_) {}
    if (status != PomoStatus.awaiting) return;
    _moveToNext();
    _endAt = DateTime.now().add(_left);
    status = PomoStatus.running;
    sessionActive = true;
    _startTimer();
    notifier.pomoCancel();
    notifyListeners();
  }

  String _nextText(bool wasFocus) =>
      wasFocus ? 'Time for a short break.' : 'Ready for your next focus session.';

  /// Sound and notifications are independent:
  /// - sound on         -> the custom sound loops until the next session is started
  ///                       (a built-in chime plays once when there is no custom file
  ///                       and no notification to carry the default sound);
  /// - notifications on -> one completion notification is shown.
  void _announce(bool wasFocus, Duration lateness) {
    if (!_foreground || lateness > const Duration(seconds: 5)) return;
    final soundOn = store.pomoSound;
    final notifyOn = store.pomoNotify;
    String? custom = soundOn ? store.pomoSoundPath : null;
    if (custom != null && !File(custom).existsSync()) {
      store.clearPomoSound(); // the file was deleted: fall back to the default sound
      custom = null;
    }
    if (soundOn) HapticFeedback.heavyImpact();
    final title = wasFocus ? 'Focus session complete' : 'Break over';
    final body = _nextText(wasFocus);
    if (notifyOn) notifier.pomoNow(title, body, soundOn && custom == null);
    if (custom != null) {
      pomoAudio.play(custom, loop: true).then((ok) {
        if (ok) return;
        store.clearPomoSound();
        if (notifyOn) {
          notifier.pomoNow(title, body, true);
        } else {
          pomoAudio.playChime();
        }
      });
    } else if (soundOn && !notifyOn) {
      pomoAudio.playChime();
    }
  }

  void onBackground() {
    _foreground = false;
    if (store.pomoNotify && status == PomoStatus.running && _endAt != null) {
      final wasFocus = phase == PomoPhase.focus;
      notifier.pomoSchedule(_endAt!, wasFocus ? 'Focus session complete' : 'Break over',
          _nextText(wasFocus), store.pomoSound);
    }
  }

  void onResume() {
    notifier.pomoCancel();
    tick();
    _foreground = true;
    store.rollPomoDay();
    notifyListeners();
  }
}

// ───────── focus orb ─────────
/// Animated fluid-gradient orb. Everything is drawn with Flutter gradients:
/// colour blobs drift inside a dark glass sphere and mix additively, a rim
/// light, shading and a glossy highlight give depth, and the whole orb breathes.
/// It repaints at about 30 fps and stops when the screen is covered.
class FocusOrb extends StatefulWidget {
  final double size;
  const FocusOrb({super.key, required this.size});
  @override
  State<FocusOrb> createState() => _FocusOrbState();
}

class _FocusOrbState extends State<FocusOrb> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final ValueNotifier<double> _t = ValueNotifier<double>(2.0);
  Duration _last = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((e) {
      if ((e - _last).inMilliseconds >= 32) {
        _last = e;
        _t.value = e.inMicroseconds / 1e6;
      }
    });
    _ticker.start();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (MediaQuery.disableAnimationsOf(context)) {
      _ticker.stop();
    } else if (!_ticker.isActive) {
      _ticker.start();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _t.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: RepaintBoundary(
        child: CustomPaint(painter: OrbPainter(_t, isDark(context))),
      ),
    );
  }
}

class OrbPainter extends CustomPainter {
  final ValueListenable<double> time;
  final bool dark;
  OrbPainter(this.time, this.dark) : super(repaint: time);

  static const _violet = Color(0xFF7C3AED);
  static const _blue = Color(0xFF3B82F6);
  static const _cyan = Color(0xFF22D3EE);
  static const _magenta = Color(0xFFD946EF);
  static const _indigo = Color(0xFF6366F1);

  @override
  void paint(Canvas canvas, Size size) {
    final t = time.value;
    final c = size.center(Offset.zero);
    final breathe = 1 + 0.035 * math.sin(t * 2 * math.pi / 4.2);
    final r = size.width * 0.29 * breathe;
    final rect = Rect.fromCircle(center: c, radius: r);

    // soft outer glow whose hue drifts between violet and magenta
    final hue = Color.lerp(_violet, _magenta, (math.sin(t * 0.55) + 1) / 2)!;
    final glowA = (dark ? 0.55 : 0.4) * (0.82 + 0.18 * math.sin(t * 1.1));
    final glowR = size.width * 0.5;
    canvas.drawCircle(
      c,
      glowR,
      Paint()
        ..shader = RadialGradient(
          colors: [hue.withOpacity(glowA), _blue.withOpacity(glowA * 0.35), Colors.transparent],
          stops: const [0.5, 0.74, 1.0],
        ).createShader(Rect.fromCircle(center: c, radius: glowR)),
    );

    // light pooling on the ground below the orb
    final ground = Rect.fromCenter(center: c.translate(0, r * 1.28), width: r * 1.5, height: r * 0.22);
    canvas.drawOval(
      ground,
      Paint()
        ..shader = RadialGradient(colors: [hue.withOpacity(0.35), Colors.transparent])
            .createShader(ground),
    );

    // sphere body
    canvas.drawCircle(
      c,
      r,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(-0.3, -0.35),
          radius: 1.05,
          colors: [Color(0xFF2B2A6B), Color(0xFF14123D), Color(0xFF080721)],
          stops: [0, 0.6, 1],
        ).createShader(rect),
    );

    canvas.save();
    canvas.clipPath(Path()..addOval(rect));

    // drifting colour blobs, blended additively so they mix like liquid light
    void blob(Color col, double fx, double fy, double ph, double base) {
      final pos = c + Offset(r * 0.5 * math.sin(t * fx + ph), r * 0.5 * math.cos(t * fy + ph * 1.3));
      final br = r * (base + 0.12 * math.sin(t * (fx + fy) * 0.7 + ph));
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(t * 0.25 + ph);
      canvas.scale(1 + 0.28 * math.sin(t * fx * 1.3 + ph), 1 - 0.22 * math.sin(t * fy * 1.1 + ph));
      canvas.drawCircle(
        Offset.zero,
        br,
        Paint()
          ..blendMode = BlendMode.plus
          ..shader = RadialGradient(
            colors: [col.withOpacity(0.95), col.withOpacity(0.0)],
            stops: const [0.15, 1.0],
          ).createShader(Rect.fromCircle(center: Offset.zero, radius: br)),
      );
      canvas.restore();
    }

    blob(_violet, 0.9, 0.7, 0.0, 0.85);
    blob(_blue, 0.7, 1.1, 1.7, 0.8);
    blob(_cyan, 1.2, 0.8, 3.1, 0.65);
    blob(_magenta, 0.8, 1.0, 4.6, 0.6);
    blob(_indigo, 1.0, 0.6, 5.9, 0.7);

    // depth: shaded lower right, bright rim, glossy highlight
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const RadialGradient(
          center: Alignment(0.5, 0.6),
          radius: 0.95,
          colors: [Colors.transparent, Color(0x73000000)],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = RadialGradient(
          colors: [
            Colors.transparent,
            Colors.transparent,
            _cyan.withOpacity(0.3),
            Colors.white.withOpacity(0.5),
          ],
          stops: const [0.0, 0.78, 0.92, 1.0],
        ).createShader(rect),
    );
    canvas.save();
    canvas.translate(c.dx - r * 0.34, c.dy - r * 0.42);
    canvas.rotate(-0.55);
    final hl = Rect.fromCenter(center: Offset.zero, width: r * 0.62, height: r * 0.3);
    canvas.drawOval(
      hl,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white.withOpacity(0.75), Colors.white.withOpacity(0.0)],
        ).createShader(hl),
    );
    canvas.restore();
    canvas.restore();

    canvas.drawCircle(
      c,
      r,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Colors.white.withOpacity(0.18),
    );
  }

  @override
  bool shouldRepaint(OrbPainter old) => old.dark != dark;
}

// ───────── shared bits ─────────
class GradientButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  const GradientButton({super.key, required this.label, required this.icon, required this.onTap});
  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: widget.onTap,
      child: AnimatedScale(
        scale: _down ? 0.97 : 1,
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOutCubic,
        child: Container(
          height: 58,
          width: double.infinity,
          decoration: BoxDecoration(
            gradient: const LinearGradient(colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6)]),
            borderRadius: BorderRadius.circular(29),
            boxShadow: [
              BoxShadow(
                color: kAccent.withOpacity(0.35),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Center(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 200),
              child: Row(
                key: ValueKey(widget.label),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(widget.icon, color: Colors.white, size: 24),
                  const SizedBox(width: 8),
                  Text(widget.label,
                      style: const TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w700, color: Colors.white)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Numeric entry dialog used by the tappable values in the timer settings.
Future<int?> askNumber(
  BuildContext context, {
  required String title,
  required int value,
  required int min,
  required int max,
  required String unit,
}) {
  final ctl = TextEditingController(text: '$value');
  ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
  String? err;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      void submit() {
        final v = int.tryParse(ctl.text.trim());
        if (v == null || v < min || v > max) {
          set(() => err = 'Enter a number from $min to $max');
          return;
        }
        Navigator.pop(ctx, v);
      }

      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          keyboardType: TextInputType.number,
          textInputAction: TextInputAction.done,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(3)],
          decoration: deco(ctx, unit).copyWith(errorText: err, helperText: 'Between $min and $max'),
          onChanged: (_) {
            if (err != null) set(() => err = null);
          },
          onSubmitted: (_) => submit(),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    }),
  );
}

String fmtDur(int seconds) {
  final m = seconds ~/ 60, r = seconds % 60;
  return '${m.toString().padLeft(2, "0")}:${r.toString().padLeft(2, "0")}';
}

/// Minutes + seconds entry. The total must be between [min] and [max] seconds.
Future<int?> askDuration(
  BuildContext context, {
  required String title,
  required int seconds,
  required int min,
  required int max,
}) {
  final mCtl = TextEditingController(text: '${seconds ~/ 60}');
  final sCtl = TextEditingController(text: (seconds % 60).toString().padLeft(2, '0'));
  mCtl.selection = TextSelection(baseOffset: 0, extentOffset: mCtl.text.length);
  String? err;
  return showDialog<int>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
      void submit() {
        final m = int.tryParse(mCtl.text.trim().isEmpty ? '0' : mCtl.text.trim());
        final r = int.tryParse(sCtl.text.trim().isEmpty ? '0' : sCtl.text.trim());
        if (m == null || r == null || r > 59) {
          set(() => err = 'Seconds must be between 0 and 59');
          return;
        }
        final total = m * 60 + r;
        if (total < min || total > max) {
          set(() => err = 'Enter a time from ${fmtDur(min)} to ${fmtDur(max)}');
          return;
        }
        Navigator.pop(ctx, total);
      }

      Widget field(TextEditingController c, String label, int len, bool first) => Expanded(
            child: TextField(
              controller: c,
              autofocus: first,
              keyboardType: TextInputType.number,
              textAlign: TextAlign.center,
              textInputAction: first ? TextInputAction.next : TextInputAction.done,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(len)],
              decoration: deco(ctx, label),
              onChanged: (_) {
                if (err != null) set(() => err = null);
              },
              onSubmitted: (_) {
                if (!first) submit();
              },
            ),
          );

      return AlertDialog(
        title: Text(title),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            field(mCtl, 'Minutes', 3, true),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text(':', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800)),
            ),
            field(sCtl, 'Seconds', 2, false),
          ]),
          const SizedBox(height: 10),
          Text(err ?? 'From ${fmtDur(min)} to ${fmtDur(max)}',
              style: TextStyle(
                  fontSize: 12.5,
                  color: err != null ? kBad : onSurf(ctx).withOpacity(0.6))),
        ]),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: submit, child: const Text('Save')),
        ],
      );
    }),
  );
}

// ───────── screen one: configuration ─────────
class PomodoroSetupPage extends StatelessWidget {
  const PomodoroSetupPage({super.key});

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: Listenable.merge([store, pomodoro]),
        builder: (c, _) {
          store.rollPomoDay();
          final on = onSurf(c);
          final cfg = store.pomoCfg;
          Widget stat(IconData icon, Color col, String value, String label) => Expanded(
                child: Column(children: [
                  Icon(icon, color: col, size: 24),
                  const SizedBox(height: 6),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(value,
                        style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
                  ),
                  const SizedBox(height: 2),
                  Text(label,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.6))),
                ]),
              );
          Widget durCard(IconData icon, Color tint, String title, String key) {
            final secs = cfg[key]!;
            return Expanded(
              child: Glass(
                padding: EdgeInsets.zero,
                onTap: () async {
                  final v = await askDuration(c, title: title, seconds: secs, min: 1, max: 59940);
                  if (v != null) store.setPomo(key, v);
                },
                child: Container(
                  height: 164,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [tint.withOpacity(isDark(c) ? 0.26 : 0.2), tint.withOpacity(0.04)],
                    ),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: tint.withOpacity(0.22),
                        borderRadius: BorderRadius.circular(13),
                      ),
                      child: Icon(icon, size: 20, color: tint),
                    ),
                    const SizedBox(height: 12),
                    Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: on)),
                    const SizedBox(height: 4),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(fmtDur(secs),
                          style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800, color: on)),
                    ),
                    const Spacer(),
                    Row(children: [
                      Icon(Icons.edit_rounded, size: 13, color: on.withOpacity(0.5)),
                      const SizedBox(width: 5),
                      Text('Tap to edit',
                          style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.55))),
                    ]),
                  ]),
                ),
              ),
            );
          }

          return Column(children: [
            SubHeader(
              title: 'Pomodoro',
              subtitle: 'Focus. Study. Achieve.',
              actions: [GlassIconBtn(Icons.settings_rounded, () => showPomoSettings(c))],
            ),
            Expanded(
              child: LayoutBuilder(builder: (ctx, box) {
                final orb = (box.maxHeight * 0.26).clamp(120.0, 170.0).toDouble();
                return RevealList(
                  page: 'pomo',
                  padding: const EdgeInsets.only(bottom: 32),
                  children: [
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Center(child: FocusOrb(size: orb)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 2, 20, 6),
                      child: Column(children: [
                        Text('Find Your Focus',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
                        const SizedBox(height: 4),
                        Text('Make time for what matters.',
                            textAlign: TextAlign.center,
                            style: TextStyle(fontSize: 14, color: on.withOpacity(0.6))),
                      ]),
                    ),
                    const SectionTitle('Session Setup'),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Row(children: [
                        durCard(Icons.timer_rounded, kAccent, 'Focus Time', 'focus'),
                        const SizedBox(width: 12),
                        durCard(Icons.coffee_rounded, kHabit, 'Short Break', 'short'),
                      ]),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                      child: Glass(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                        onTap: () async {
                          final v = await askNumber(c,
                              title: 'Focus Cycles',
                              value: cfg['cycles']!,
                              min: 3,
                              max: 12,
                              unit: 'Value');
                          if (v != null) store.setPomo('cycles', v);
                        },
                        child: Row(children: [
                          Container(
                            width: 40,
                            height: 40,
                            decoration: BoxDecoration(
                              color: kPomo.withOpacity(0.2),
                              borderRadius: BorderRadius.circular(13),
                            ),
                            child: const Icon(Icons.all_inclusive_rounded, size: 22, color: kPomo),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text('Focus Cycles',
                                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
                          ),
                          Text('${cfg['cycles']}',
                              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
                          const SizedBox(width: 4),
                          Icon(Icons.chevron_right_rounded, color: on.withOpacity(0.5)),
                        ]),
                      ),
                    ),
                    if (pomodoro.sessionActive)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(26, 0, 20, 10),
                        child: Text('Changes apply to your next session.',
                            style: TextStyle(fontSize: 12, color: on.withOpacity(0.55))),
                      ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                      child: Glass(
                        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Padding(
                            padding: const EdgeInsets.only(left: 8, bottom: 12),
                            child: Text("Today's Progress",
                                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: on)),
                          ),
                          Row(children: [
                            stat(Icons.check_circle_rounded, kHabit, '${store.pomoCycles}', 'Focus cycles'),
                            stat(Icons.coffee_rounded, kWarn, '${store.pomoBreaks}', 'Breaks'),
                            stat(Icons.schedule_rounded, kAccent, fmtFocusTime(store.pomoFocusSec),
                                'Focus time'),
                          ]),
                        ]),
                      ),
                    ),
                  ],
                );
              }),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 6, 20, 16),
              child: GradientButton(
                label: pomodoro.sessionActive ? 'Resume Session' : 'Start Session',
                icon: Icons.play_arrow_rounded,
                onTap: () {
                  if (!pomodoro.sessionActive) {
                    pomodoro.configure(
                      focus: cfg['focus']!,
                      shortB: cfg['short']!,
                      cyc: cfg['cycles']!,
                    );
                  }
                  openScreen(c, const PomodoroTimerPage());
                },
              ),
            ),
          ]);
        },
      ),
    );
  }
}

Future<void> showPomoSettings(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => const PomoSettingsSheet(),
  ).whenComplete(pomoAudio.stop);
}

class PomoSettingsSheet extends StatefulWidget {
  const PomoSettingsSheet({super.key});
  @override
  State<PomoSettingsSheet> createState() => _PomoSettingsSheetState();
}

class _PomoSettingsSheetState extends State<PomoSettingsSheet> {
  bool _busy = false;
  String? _error;

  Future<void> _pick() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final err = await pickPomoSound();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = err;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        final path = store.pomoSoundPath;
        final exists = path != null && File(path).existsSync();
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(c).height * 0.88),
            child: Glass(
              radius: 30,
              opacity: isDark(c) ? 0.18 : 0.9,
              padding: const EdgeInsets.all(22),
              child: SingleChildScrollView(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Pomodoro settings',
                      style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
                  const SizedBox(height: 14),
                  Row(children: [
                    Icon(store.pomoSound ? Icons.volume_up_rounded : Icons.volume_off_rounded,
                        color: kPomo),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Sound & vibration',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
                        Text('Completion sound and vibration',
                            style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                      ]),
                    ),
                    Switch(
                      value: store.pomoSound,
                      activeTrackColor: kAccent,
                      onChanged: (_) => store.togglePomoSound(),
                    ),
                  ]),
                  const SizedBox(height: 14),
                  Row(children: [
                    Icon(
                        store.pomoNotify
                            ? Icons.notifications_active_rounded
                            : Icons.notifications_off_rounded,
                        color: kPomo),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text('Notifications',
                            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
                        Text('Show an alert when a session ends',
                            style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                      ]),
                    ),
                    Switch(
                      value: store.pomoNotify,
                      activeTrackColor: kAccent,
                      onChanged: (_) async {
                        store.togglePomoNotify();
                        if (store.pomoNotify && !notifier.allowed.value) {
                          await notifier.requestPermission();
                        }
                      },
                    ),
                  ]),
                  const SizedBox(height: 18),
                  Text('Custom completion sound',
                      style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
                  const SizedBox(height: 2),
                  Text('Plays when a focus session or a break ends.',
                      style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                  const SizedBox(height: 10),
                  if (path == null)
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        onPressed: _busy ? null : _pick,
                        icon: const Icon(Icons.library_music_rounded, size: 20),
                        label: Text(_busy ? 'Loading...' : 'Select Sound'),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: on.withOpacity(0.06),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          const Icon(Icons.music_note_rounded, color: kPomo, size: 22),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(store.pomoSoundName ?? 'Custom sound',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w700, color: on)),
                          ),
                          if (!exists) const Pill('File missing', kBad),
                        ]),
                        const SizedBox(height: 10),
                        Wrap(spacing: 8, runSpacing: 8, children: [
                          ValueListenableBuilder<bool>(
                            valueListenable: pomoAudio.playing,
                            builder: (ctx, playing, _) => FilledButton.tonalIcon(
                              onPressed: exists
                                  ? () => playing
                                      ? pomoAudio.stop()
                                      : pomoAudio.play(path, preview: true)
                                  : null,
                              icon: Icon(playing ? Icons.stop_rounded : Icons.play_arrow_rounded,
                                  size: 18),
                              label: Text(playing ? 'Stop' : 'Preview'),
                            ),
                          ),
                          OutlinedButton.icon(
                            onPressed: _busy ? null : _pick,
                            icon: const Icon(Icons.swap_horiz_rounded, size: 18),
                            label: Text(_busy ? 'Loading...' : 'Replace'),
                          ),
                          OutlinedButton.icon(
                            style: OutlinedButton.styleFrom(
                              foregroundColor: kBad,
                              side: BorderSide(color: kBad.withOpacity(0.5)),
                            ),
                            onPressed: _busy
                                ? null
                                : () async {
                                    await pomoAudio.stop();
                                    await removePomoSound();
                                  },
                            icon: const Icon(Icons.delete_outline_rounded, size: 18),
                            label: const Text('Remove'),
                          ),
                        ]),
                      ]),
                    ),
                  if (_error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text(_error!, style: const TextStyle(fontSize: 12.5, color: kBad)),
                    ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: store.resetPomoConfig,
                      icon: const Icon(Icons.restart_alt_rounded, size: 18),
                      label: const Text('Reset durations to default'),
                    ),
                  ),
                ]),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ───────── screen two: minimal timer ─────────
/// Bold, rounded countdown. Poppins Bold supplies the geometric numerals and a
/// round-joined outline softens every corner. Each character sits in a fixed
/// cell, so digits never shift as the time changes, and the optical centre of
/// the digits is aligned with the middle of the box.
class RoundedClock extends StatelessWidget {
  final String text;
  final double fontSize;
  final Color color;
  const RoundedClock({super.key, required this.text, required this.fontSize, required this.color});

  TextStyle _style({required bool outline}) => TextStyle(
        fontFamily: 'Poppins',
        fontWeight: FontWeight.w700,
        fontSize: fontSize,
        height: 1.0,
        leadingDistribution: TextLeadingDistribution.even,
        color: outline ? null : color,
        foreground: outline
            ? (Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = fontSize * 0.05
              ..strokeJoin = StrokeJoin.round
              ..strokeCap = StrokeCap.round
              ..color = color)
            : null,
      );

  @override
  Widget build(BuildContext context) {
    final fs = fontSize;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final ch in text.split(''))
          SizedBox(
            width: fs * (ch == ':' ? 0.34 : 0.66),
            height: fs,
            child: Transform.translate(
              offset: Offset(0, fs * (ch == ':' ? -0.06 : 0.02)),
              child: OverflowBox(
                maxWidth: fs * 1.2,
                child: Stack(alignment: Alignment.center, children: [
                  Text(ch,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: _style(outline: true)),
                  Text(ch,
                      maxLines: 1,
                      softWrap: false,
                      overflow: TextOverflow.visible,
                      style: _style(outline: false)),
                ]),
              ),
            ),
          ),
      ],
    );
  }
}

class RingPainter extends CustomPainter {
  final double fraction;
  final Color c1, c2, track;
  final double stroke, inset;
  RingPainter(this.fraction, this.c1, this.c2, this.track, {this.stroke = 14.0, this.inset = 18.0});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2 - inset;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = track
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke,
    );
    final sweep = 2 * math.pi * fraction;
    if (sweep < 0.02) return;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final shader = SweepGradient(
      startAngle: 0,
      endAngle: sweep,
      colors: [c1, c2],
      transform: const GradientRotation(-math.pi / 2),
    ).createShader(rect);
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke + 8
        ..strokeCap = StrokeCap.round
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, stroke * 12 / 14)
        ..color = Colors.white.withOpacity(0.55),
    );
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..shader = shader
        ..style = PaintingStyle.stroke
        ..strokeWidth = stroke
        ..strokeCap = StrokeCap.round,
    );
    final endAngle = -math.pi / 2 + sweep;
    canvas.drawCircle(
      Offset(center.dx + radius * math.cos(endAngle), center.dy + radius * math.sin(endAngle)),
      stroke * 4.5 / 14,
      Paint()..color = Colors.white.withOpacity(0.95),
    );
  }

  @override
  bool shouldRepaint(RingPainter old) => true;
}

class TimerRing extends StatefulWidget {
  final double size;
  const TimerRing({super.key, required this.size});
  @override
  State<TimerRing> createState() => _TimerRingState();
}

class _TimerRingState extends State<TimerRing> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => setState(() {}));
    pomodoro.addListener(_sync);
    if (pomodoro.status == PomoStatus.running) _ticker.start();
  }

  void _sync() {
    if (!mounted) return;
    final run = pomodoro.status == PomoStatus.running;
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
    setState(() {});
  }

  @override
  void dispose() {
    pomodoro.removeListener(_sync);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final size = widget.size;
    final secs = (pomodoro.remaining.inMilliseconds / 1000).ceil();
    final mm = (secs ~/ 60).toString().padLeft(2, '0');
    final ss = (secs % 60).toString().padLeft(2, '0');
    final pair = phaseColors(pomodoro.phase);
    final idle = pomodoro.status == PomoStatus.idle;
    final phase = pomodoro.phase;
    // Time is laid out on its own at the exact centre; the labels hang below it.
    final units = (mm.length + 2) * 0.66 + 0.34;
    final fs = math.min(size * 0.215, size * 0.64 / units);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: pomodoro.status == PomoStatus.running ? null : pomodoro.start,
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(children: [
          Positioned.fill(
            child: TweenAnimationBuilder<Color?>(
              tween: ColorTween(end: pair.$1),
              duration: const Duration(milliseconds: 500),
              builder: (c, c1, _) => TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: pair.$2),
                duration: const Duration(milliseconds: 500),
                builder: (c, c2, _) => RepaintBoundary(
                  child: CustomPaint(
                    painter: RingPainter(
                      pomodoro.fraction,
                      c1 ?? pair.$1,
                      c2 ?? pair.$2,
                      on.withOpacity(0.08),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Center(child: RoundedClock(text: '$mm:$ss', fontSize: fs, color: on)),
          Positioned(
            left: 0,
            right: 0,
            top: size / 2 + fs / 2 + size * 0.03,
            child: Center(
              child: SizedBox(
                width: size * 0.56,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 300),
                      child: Container(
                        key: ValueKey(phase),
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                        decoration: BoxDecoration(
                          color: on.withOpacity(0.08),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(mainAxisSize: MainAxisSize.min, children: [
                          Icon(
                            phase == PomoPhase.focus ? Icons.timer_rounded : Icons.coffee_rounded,
                            size: 17,
                            color: pair.$2,
                          ),
                          const SizedBox(width: 7),
                          Text(phaseLabel(phase),
                              style: TextStyle(
                                  fontSize: 14, fontWeight: FontWeight.w700, color: on)),
                        ]),
                      ),
                    ),
                    const SizedBox(height: 8),
                    AnimatedOpacity(
                      opacity: idle ? 1 : 0,
                      duration: const Duration(milliseconds: 250),
                      child: Text('Tap to start',
                          style: TextStyle(fontSize: 13, color: on.withOpacity(0.55))),
                    ),
                  ]),
                ),
              ),
            ),
          ),
        ]),
      ),
    );
  }
}

/// Shown instead of the ring once a countdown ends, until the user confirms.
class CompletionPanel extends StatelessWidget {
  const CompletionPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final focus = pomodoro.phase == PomoPhase.focus;
    final pair = phaseColors(pomodoro.phase);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Glass(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(colors: [pair.$1, pair.$2]),
                boxShadow: [
                  BoxShadow(color: pair.$2.withOpacity(0.45), blurRadius: 22, offset: const Offset(0, 6)),
                ],
              ),
              child: const Icon(Icons.check_rounded, color: Colors.white, size: 42),
            ),
            const SizedBox(height: 18),
            Text(focus ? 'Focus Session Completed!' : 'Break Completed!',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
            const SizedBox(height: 8),
            Text(
              focus
                  ? 'Great work! Take a short break to recharge.'
                  : "Break's over. Ready for the next focus session?",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: on.withOpacity(0.65)),
            ),
          ]),
        ),
      ),
    );
  }
}

class PomodoroTimerPage extends StatelessWidget {
  const PomodoroTimerPage({super.key});

  Widget _mini(BuildContext c, IconData icon, String label, VoidCallback onTap) {
    final on = onSurf(c);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      GlassIconBtn(icon, onTap),
      const SizedBox(height: 6),
      Text(label, style: TextStyle(fontSize: 11.5, color: on.withOpacity(0.6))),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // leaving a finished session silences its alert
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && pomodoro.awaiting) pomoAudio.stop();
      },
      child: screenFrame(
        context,
        ListenableBuilder(
          listenable: pomodoro,
          builder: (c, _) {
            final on = onSurf(c);
            final st = pomodoro.status;
            final done = st == PomoStatus.awaiting;
            final focusDone = pomodoro.phase == PomoPhase.focus;
            final line =
                '${phaseLabel(pomodoro.phase)} • Session ${pomodoro.sessionNumber} of ${pomodoro.cycles}';
            String label;
            IconData icon;
            VoidCallback onTap;
            if (done) {
              label = focusDone ? 'Start Short Break' : 'Start Next Focus Session';
              icon = focusDone ? Icons.coffee_rounded : Icons.play_arrow_rounded;
              onTap = () => pomodoro.startNext();
            } else if (st == PomoStatus.running) {
              label = 'Pause';
              icon = Icons.pause_rounded;
              onTap = pomodoro.pause;
            } else {
              label = st == PomoStatus.paused ? 'Resume' : 'Start';
              icon = Icons.play_arrow_rounded;
              onTap = pomodoro.start;
            }
            return Column(children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: GlassIconBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.of(c).pop()),
                ),
              ),
              Expanded(
                child: LayoutBuilder(builder: (ctx, box) {
                  final size = math.max(
                      0.0, math.min(math.min(box.maxWidth - 48, box.maxHeight - 16), 340.0));
                  return AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    child: done
                        ? CompletionPanel(key: ValueKey('done-${pomodoro.phase}'))
                        : Center(key: const ValueKey('ring'), child: TimerRing(size: size)),
                  );
                }),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(line,
                      key: ValueKey(line),
                      style: TextStyle(
                          fontSize: 14, fontWeight: FontWeight.w600, color: on.withOpacity(0.7))),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 0, 28, 24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  AnimatedSize(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    child: pomodoro.sessionActive
                        ? Padding(
                            padding: const EdgeInsets.only(bottom: 16),
                            child: Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
                              if (!done) _mini(c, Icons.restart_alt_rounded, 'Reset', pomodoro.reset),
                              if (!done) _mini(c, Icons.skip_next_rounded, 'Skip', pomodoro.skip),
                              _mini(c, Icons.stop_rounded, 'Stop', () {
                                pomodoro.stop();
                                Navigator.of(c).pop();
                              }),
                            ]),
                          )
                        : const SizedBox(width: double.infinity),
                  ),
                  GradientButton(label: label, icon: icon, onTap: onTap),
                ]),
              ),
            ]);
          },
        ),
      ),
    );
  }
}


// ───────────────────────── assignments: FAB + settings ─────────────────────────
class FabButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const FabButton({super.key, required this.icon, required this.onTap});
  @override
  State<FabButton> createState() => _FabButtonState();
}

class _FabButtonState extends State<FabButton> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapUp: (_) => setState(() => _down = false),
      onTapCancel: () => setState(() => _down = false),
      onTap: () {
        HapticFeedback.selectionClick();
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.92 : 1,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOutCubic,
        child: Container(
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF8B5CF6), Color(0xFF3B82F6)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: Colors.white.withOpacity(0.28)),
            boxShadow: [
              BoxShadow(
                color: kAccent.withOpacity(0.4),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: Icon(widget.icon, color: Colors.white, size: 30),
        ),
      ),
    );
  }
}

Future<void> showAssignmentSettings(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) => ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        return Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: Glass(
            radius: 30,
            opacity: isDark(c) ? 0.18 : 0.9,
            padding: const EdgeInsets.all(22),
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Assignment settings',
                  style: TextStyle(fontSize: 21, fontWeight: FontWeight.w800, color: on)),
              const SizedBox(height: 14),
              Row(children: [
                const Icon(Icons.swipe_rounded, color: kAccent),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Swipe actions',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: on)),
                    Text('Swipe right to mark done, swipe left to delete.',
                        style: TextStyle(fontSize: 12.5, color: on.withOpacity(0.6))),
                  ]),
                ),
                Switch(
                  value: store.swipeActions,
                  activeTrackColor: kAccent,
                  onChanged: (_) => store.toggleSwipe(),
                ),
              ]),
            ]),
          ),
        );
      },
    ),
  );
}


// ───────────────────────── habit tracker (Tools Hub) ─────────────────────────
/// Longest run of consecutive completed days for one habit (same completion
/// records as streak() and every other habit view).
int longestStreak(Habit h) {
  if (h.days.isEmpty) return 0;
  final ds = h.days.map(DateTime.parse).toList()..sort();
  var best = 1, run = 1;
  for (var i = 1; i < ds.length; i++) {
    if (sameDay(nextDay(ds[i - 1]), ds[i])) {
      run++;
    } else if (!sameDay(ds[i - 1], ds[i])) {
      run = 1;
    }
    if (run > best) best = run;
  }
  return best;
}

class HabitGradientProgressTrack extends StatelessWidget {
  final double progress;
  final double height;
  final Color trackColor;
  const HabitGradientProgressTrack({
    super.key,
    required this.progress,
    required this.height,
    required this.trackColor,
  });

  @override
  Widget build(BuildContext context) {
    final value = progress.clamp(0.0, 1.0).toDouble();
    final colors = attendanceGradient(value * 100);
    return LayoutBuilder(
      builder: (context, constraints) => Container(
        height: height,
        width: double.infinity,
        decoration: BoxDecoration(
          color: trackColor,
          borderRadius: BorderRadius.circular(30),
        ),
        clipBehavior: Clip.antiAlias,
        child: Align(
          alignment: Alignment.centerLeft,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 420),
            curve: Curves.easeInOut,
            width: constraints.maxWidth * value,
            height: height,
            decoration: BoxDecoration(
              gradient: LinearGradient(colors: [colors.$1, colors.$2]),
              borderRadius: BorderRadius.circular(30),
              boxShadow: [
                BoxShadow(
                  color: colors.$2.withOpacity(0.22),
                  blurRadius: 7,
                  spreadRadius: 0.5,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HabitProgressBar extends StatelessWidget {
  final Habit habit;
  final bool compact;
  const HabitProgressBar({super.key, required this.habit, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final key = dayKey(DateTime.now());
    final target = habit.target > 0 ? habit.target : 1;
    final done = habit.days.contains(key);
    final current = done ? target : (habit.progress[key] ?? 0).clamp(0, target);
    final ratio = (current / target).clamp(0.0, 1.0).toDouble();
    final on = onSurf(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text(done ? 'Target completed today' : '$current / $target completed today',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: compact ? 9.5 : 10.5, fontWeight: FontWeight.w700, color: done ? kHabit : on.withOpacity(0.68))),
        const Spacer(),
        Text('${(ratio * 100).round()}%',
            style: TextStyle(fontSize: compact ? 10 : 11, color: on.withOpacity(0.52))),
      ]),
      const SizedBox(height: 5),
      HabitGradientProgressTrack(
        progress: ratio,
        height: compact ? 5 : 6,
        trackColor: on.withOpacity(0.09),
      ),
    ]);
  }
}

class HabitDailyProgress extends StatelessWidget {
  const HabitDailyProgress({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) {
          final total = store.habits.length;
          final key = dayKey(DateTime.now());
          final completed = store.habits.where((h) => h.days.contains(key)).length;
          final ratio = total == 0 ? 0.0 : completed / total;
          final on = onSurf(context);
          return Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
            child: Glass(
              padding: const EdgeInsets.fromLTRB(16, 13, 16, 13),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Text('Today · $completed', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w800, color: on)),
                  const Spacer(),
                  Text('$total habits', style: TextStyle(fontSize: 12, color: on.withOpacity(0.55))),
                ]),
                const SizedBox(height: 9),
                HabitGradientProgressTrack(
                  progress: ratio,
                  height: 8,
                  trackColor: on.withOpacity(0.09),
                ),
              ]),
            ),
          );
        },
      );
}

class HabitStatsCard extends StatelessWidget {
  const HabitStatsCard({super.key});
  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (c, _) {
        final on = onSurf(c);
        var cur = 0, best = 0;
        for (final h in store.habits) {
          final s = streak(h);
          if (s > cur) cur = s;
          final l = longestStreak(h);
          if (l > best) best = l;
        }
        final cons = graphPoints('Month', 'all').last.value;
        Widget cell(IconData icon, Color col, String value, String label) => Expanded(
              child: Column(children: [
                Icon(icon, color: col, size: 26),
                const SizedBox(height: 6),
                Text(value, style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: on)),
                const SizedBox(height: 2),
                Text(label, style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
              ]),
            );
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
          child: Glass(
            child: Row(children: [
              cell(Icons.local_fire_department_rounded, kWarn, '$cur', 'Current streak'),
              cell(Icons.emoji_events_rounded, kAccent, '$best', 'Longest streak'),
              cell(Icons.insights_rounded, kHabit, cons == null ? '–' : '${cons.round()}%',
                  'Consistency'),
            ]),
          ),
        );
      },
    );
  }
}

class HabitCompactCard extends StatelessWidget {
  final Habit habit;
  const HabitCompactCard({super.key, required this.habit});

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final currentStreak = streak(habit);
    return SizedBox(
      height: 184,
      child: Glass(
        radius: 22,
        padding: const EdgeInsets.all(13),
        onTap: () => openHabitDetailPage(context, habit),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Container(
              width: 42, height: 42, alignment: Alignment.center,
              decoration: BoxDecoration(color: kHabit.withOpacity(0.16), borderRadius: BorderRadius.circular(14)),
              child: Icon(habitIconData(habit.iconKey), size: 22, color: kHabit),
            ),
            const Spacer(),
            HabitCompletionButton(habit: habit, size: 44),
          ]),
          const SizedBox(height: 11),
          Text(habit.name, maxLines: 2, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 14, height: 1.2, fontWeight: FontWeight.w800, color: on)),
          const SizedBox(height: 6),
          HabitProgressBar(habit: habit, compact: true),
          const SizedBox(height: 4),
          _HabitStreakLine(value: currentStreak, color: on.withOpacity(0.62), fontSize: 10.5),
        ]),
      ),
    );
  }
}

class HabitCompactGrid extends StatelessWidget {
  const HabitCompactGrid({super.key});
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: store,
        builder: (context, _) => Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final gap = constraints.maxWidth < 340 ? 8.0 : 10.0;
              final cardWidth = (constraints.maxWidth - gap) / 2;
              return Wrap(
                alignment: WrapAlignment.start,
                runAlignment: WrapAlignment.start,
                crossAxisAlignment: WrapCrossAlignment.start,
                spacing: gap,
                runSpacing: gap,
                children: [
                  for (final habit in store.habits)
                    SizedBox(
                      width: cardWidth,
                      child: HabitCompactCard(
                        key: ValueKey('compact_hab_${habit.id}'),
                        habit: habit,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      );
}

class HabitViewSelector extends StatelessWidget {
  final bool compact;
  const HabitViewSelector({super.key, required this.compact});
  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    Widget option({required bool selected, required IconData icon, required String label, required VoidCallback tap}) =>
        Semantics(
          button: true, selected: selected, label: label,
          child: InkWell(
            borderRadius: BorderRadius.circular(11), onTap: tap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: selected ? kAccent.withOpacity(0.22) : Colors.transparent,
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: selected ? kAccent.withOpacity(0.7) : Colors.transparent),
              ),
              child: Icon(icon, size: 19, color: selected ? kAccent : on.withOpacity(0.62)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(color: on.withOpacity(0.06), borderRadius: BorderRadius.circular(14)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        option(selected: compact, icon: Icons.grid_view_rounded, label: 'Compact view',
            tap: () => store.setCompactHabitView(true)),
        option(selected: !compact, icon: Icons.view_agenda_rounded, label: 'List view',
            tap: () => store.setCompactHabitView(false)),
      ]),
    );
  }
}

class HabitTrackerPage extends StatelessWidget {
  const HabitTrackerPage({super.key});
  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) => Stack(children: [
          Positioned.fill(
            child: RevealList(
              page: 'habits',
              padding: const EdgeInsets.only(bottom: 120),
              children: [
                const SubHeader(title: 'Habit Tracker', subtitle: 'Build habits and track your streaks.'),
                const HabitDailyProgress(),
                SectionTitle(
                  'My Habits',
                  trailing: HabitViewSelector(compact: store.compactHabitView),
                ),
                if (store.habits.isEmpty)
                  const EmptyCard(Icons.flag_circle_rounded, 'No habits yet.\nTap + to start tracking one.')
                else
                  AnimatedSize(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeInOutCubic,
                    alignment: Alignment.topCenter,
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 220),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      layoutBuilder: (current, previous) =>
                          current ?? const SizedBox.shrink(),
                      transitionBuilder: (child, animation) =>
                          FadeTransition(opacity: animation, child: child),
                      child: store.compactHabitView
                          ? const HabitCompactGrid(key: ValueKey('habit_compact_grid'))
                          : const HabitReorderList(key: ValueKey('habit_list_view')),
                    ),
                  ),
              ],
            ),
          ),
          Positioned(
            right: 20,
            bottom: 16,
            child: FabButton(icon: Icons.add_rounded, onTap: () => showHabitSheet(c)),
          ),
        ]),
      ),
    );
  }
}


// ───────────────────────── pdf reader ─────────────────────────
const kPdfTool = Color(0xFFE5484D);

/// One PDF in the local index. The file itself is never copied; only its path,
/// size and modified time are indexed, plus a little per-file metadata.
class LibDoc {
  String path;
  int size, modified;
  bool fav;
  int lastPage, pageCount;
  LibDoc(this.path, this.size, this.modified, {this.fav = false, this.lastPage = 0, this.pageCount = 0});
  String get name => path.split('/').last;
  String get title {
    final n = name;
    return n.toLowerCase().endsWith('.pdf') ? n.substring(0, n.length - 4) : n;
  }

  Map<String, dynamic> toJson() => {'p': path, 's': size, 'm': modified};
  factory LibDoc.fromJson(Map<String, dynamic> j) => LibDoc(j['p'], j['s'] ?? 0, j['m'] ?? 0);
}

String fmtBytes(int b) {
  if (b < 1024) return '$b B';
  final kb = b / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  return '${(mb / 1024).toStringAsFixed(2)} GB';
}

/// Walks shared storage and returns [path, size, modifiedMs] for every PDF.
/// Runs in a background isolate. Unreadable folders are skipped, hidden folders
/// and the Android/ data area are ignored.
List<List<Object>> scanForPdfs() {
  final roots = <String>['/storage/emulated/0'];
  try {
    for (final e in Directory('/storage').listSync(followLinks: false)) {
      final n = e.path.split('/').last;
      if (e is Directory && n != 'emulated' && n != 'self') roots.add(e.path);
    }
  } catch (_) {}
  final skip = <String>{for (final r in roots) '$r/Android'};
  final out = <List<Object>>[];
  final stack = <Directory>[for (final r in roots) Directory(r)];
  while (stack.isNotEmpty) {
    final dir = stack.removeLast();
    List<FileSystemEntity> items;
    try {
      items = dir.listSync(followLinks: false);
    } catch (_) {
      continue;
    }
    for (final e in items) {
      final name = e.path.split('/').last;
      if (name.startsWith('.')) continue;
      if (e is Directory) {
        if (!skip.contains(e.path)) stack.add(e);
      } else if (e is File && name.toLowerCase().endsWith('.pdf')) {
        try {
          final st = e.statSync();
          out.add([e.path, st.size, st.modified.millisecondsSinceEpoch]);
        } catch (_) {}
      }
    }
  }
  return out;
}

Future<bool> hasPdfAccess() async {
  if (await Permission.manageExternalStorage.isGranted) return true;
  return Permission.storage.isGranted;
}

/// Android 11+: opens the "All files access" screen. Android 10 and below:
/// the normal storage permission dialog.
Future<bool> requestPdfAccess() async {
  final st = await Permission.manageExternalStorage.request();
  if (st.isGranted) return true;
  final legacy = await Permission.storage.request();
  return legacy.isGranted;
}

/// Rescans storage and merges the result into the index, keeping favourites and
/// last-read pages (also for files that were moved or renamed outside the app).
Future<int> scanPdfLibrary() async {
  final found = await Isolate.run(scanForPdfs);
  final old = {for (final d in store.pdfs) d.path: d};
  final seen = <String>{};
  final next = <LibDoc>[];
  for (final r in found) {
    final path = r[0] as String;
    final prev = old[path];
    seen.add(path);
    next.add(LibDoc(path, r[1] as int, r[2] as int,
        fav: prev?.fav ?? false, lastPage: prev?.lastPage ?? 0, pageCount: prev?.pageCount ?? 0));
  }
  for (final lost in old.values.where((d) => !seen.contains(d.path) && (d.fav || d.lastPage > 0))) {
    for (final d in next) {
      if (!d.fav && d.lastPage == 0 && d.size == lost.size && d.modified == lost.modified) {
        d.fav = lost.fav;
        d.lastPage = lost.lastPage;
        d.pageCount = lost.pageCount;
        break;
      }
    }
  }
  store.setPdfIndex(next);
  return next.length;
}

Future<int?> pdfPageCount(String path) async {
  try {
    final d = await PdfDocument.openFile(path);
    final n = d.pages.length;
    await d.dispose();
    return n;
  } catch (_) {
    return null;
  }
}

List<LibDoc> sortedPdfs(List<LibDoc> src, String mode) {
  final l = [...src];
  int byName(LibDoc a, LibDoc b) => a.title.toLowerCase().compareTo(b.title.toLowerCase());
  switch (mode) {
    case 'modOld':
      l.sort((a, b) => a.modified.compareTo(b.modified));
    case 'nameAz':
      l.sort(byName);
    case 'nameZa':
      l.sort((a, b) => byName(b, a));
    case 'sizeBig':
      l.sort((a, b) => b.size.compareTo(a.size));
    case 'sizeSmall':
      l.sort((a, b) => a.size.compareTo(b.size));
    default:
      l.sort((a, b) => b.modified.compareTo(a.modified));
  }
  return l;
}

const Map<String, String> kPdfSortLabels = {
  'modNew': 'Last modified · newest first',
  'modOld': 'Last modified · oldest first',
  'nameAz': 'Name · A to Z',
  'nameZa': 'Name · Z to A',
  'sizeBig': 'Size · largest first',
  'sizeSmall': 'Size · smallest first',
};

void pdfSnack(BuildContext c, String msg) {
  if (!c.mounted) return;
  ScaffoldMessenger.of(c)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(behavior: SnackBarBehavior.floating, content: Text(msg)));
}

// ───────── library ─────────
class PdfLibraryPage extends StatefulWidget {
  const PdfLibraryPage({super.key});
  @override
  State<PdfLibraryPage> createState() => _PdfLibraryPageState();
}

class _PdfLibraryPageState extends State<PdfLibraryPage> with WidgetsBindingObserver {
  bool? _perm; // null = checking
  bool _scanning = false;
  bool _favOnly = false;
  String _query = '';
  String? _note;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _check();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  // returning from Android settings (or a revoked permission) is picked up here
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  Future<void> _check() async {
    final ok = await hasPdfAccess();
    if (!mounted) return;
    setState(() => _perm = ok);
    if (!ok) return;
    store.pruneMissingPdfs();
    final stale = DateTime.now().millisecondsSinceEpoch - store.pdfScanAt > 12 * 3600 * 1000;
    if (store.pdfs.isEmpty || stale) await _scan();
  }

  Future<void> _scan() async {
    if (_scanning) return;
    setState(() {
      _scanning = true;
      _note = null;
    });
    try {
      await scanPdfLibrary();
    } catch (_) {
      _note = "Couldn't finish scanning your storage.";
    }
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _ask() async {
    final ok = await requestPdfAccess();
    if (!mounted) return;
    setState(() => _perm = ok);
    if (ok) {
      store.pruneMissingPdfs();
      await _scan();
    }
  }

  void _open(BuildContext c, LibDoc d) {
    if (!File(d.path).existsSync()) {
      store.removePdf(d.path);
      pdfSnack(c, 'That file no longer exists. It was removed from the list.');
      return;
    }
    openScreen(c, PdfReaderPage(doc: d));
  }

  Future<void> _rename(BuildContext c, LibDoc d) async {
    final ctl = TextEditingController(text: d.title);
    ctl.selection = TextSelection(baseOffset: 0, extentOffset: ctl.text.length);
    String? err;
    final dir = d.path.substring(0, d.path.lastIndexOf('/'));
    final name = await showDialog<String>(
      context: c,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        void submit() {
          final t = ctl.text.trim();
          if (t.isEmpty || t.contains('/') || t.startsWith('.')) {
            set(() => err = 'Enter a valid file name');
            return;
          }
          if (t != d.title && File('$dir/$t.pdf').existsSync()) {
            set(() => err = 'A file with that name already exists');
            return;
          }
          Navigator.pop(ctx, t);
        }

        return AlertDialog(
          title: const Text('Rename PDF'),
          content: TextField(
            controller: ctl,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: deco(ctx, 'Name').copyWith(errorText: err, suffixText: '.pdf'),
            onChanged: (_) {
              if (err != null) set(() => err = null);
            },
            onSubmitted: (_) => submit(),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            FilledButton(onPressed: submit, child: const Text('Rename')),
          ],
        );
      }),
    );
    if (name == null || name == d.title) return;
    try {
      await File(d.path).rename('$dir/$name.pdf');
      store.renamePdf(d, '$dir/$name.pdf');
    } on FileSystemException {
      if (c.mounted) pdfSnack(c, "Couldn't rename the file. Check that StudyFlow still has file access.");
    }
  }

  Future<void> _share(BuildContext c, LibDoc d) async {
    if (!File(d.path).existsSync()) {
      store.removePdf(d.path);
      pdfSnack(c, 'That file no longer exists.');
      return;
    }
    try {
      await Share.shareXFiles([XFile(d.path)]);
    } catch (_) {
      if (c.mounted) pdfSnack(c, "Couldn't share this file.");
    }
  }

  Future<void> _delete(BuildContext c, LibDoc d) async {
    if (!await confirmDelete(c, d.name)) return;
    try {
      await File(d.path).delete();
      store.removePdf(d.path);
    } on FileSystemException {
      if (c.mounted) pdfSnack(c, "Couldn't delete the file. Check that StudyFlow still has file access.");
    }
  }

  Future<void> _info(BuildContext c, LibDoc d) async {
    final count = d.pageCount > 0 ? d.pageCount : await pdfPageCount(d.path);
    if (count != null && count != d.pageCount) store.setPdfPage(d, d.lastPage, count: count);
    if (!c.mounted) return;
    Widget row(String k, String v) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 84, child: Text(k, style: TextStyle(color: onSurf(c).withOpacity(0.6)))),
            Expanded(child: Text(v)),
          ]),
        );
    await showDialog<void>(
      context: c,
      builder: (ctx) => AlertDialog(
        title: const Text('PDF information'),
        content: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            row('Name', d.name),
            row('Size', fmtBytes(d.size)),
            row('Pages', count == null ? 'Unavailable' : '$count'),
            row('Modified', DateFormat('d MMM yyyy, h:mm a').format(DateTime.fromMillisecondsSinceEpoch(d.modified))),
            row('Location', d.path),
            row('Favourite', d.fav ? 'Yes' : 'No'),
          ]),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close'))],
      ),
    );
  }

  Widget _permissionCard(BuildContext c) {
    final on = onSurf(c);
    return ListView(padding: const EdgeInsets.fromLTRB(20, 20, 20, 40), children: [
      Glass(
        padding: const EdgeInsets.all(24),
        child: Column(children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              color: kPdfTool.withOpacity(0.18),
              borderRadius: BorderRadius.circular(22),
            ),
            child: const Icon(Icons.folder_open_rounded, size: 34, color: kPdfTool),
          ),
          const SizedBox(height: 16),
          Text('Allow access to your files',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: on)),
          const SizedBox(height: 8),
          Text(
            'To find the PDFs on your phone automatically, StudyFlow needs "All files access". '
            'Your files stay where they are: nothing is copied, uploaded or shared.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 13.5, height: 1.4, color: on.withOpacity(0.65)),
          ),
          const SizedBox(height: 20),
          SizedBox(width: double.infinity, child: GradientButton(label: 'Allow access', icon: Icons.lock_open_rounded, onTap: _ask)),
          const SizedBox(height: 8),
          TextButton(
            onPressed: openAppSettings,
            child: const Text('Open Android settings'),
          ),
        ]),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return screenFrame(
      context,
      ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final on = onSurf(c);
          Widget header = SubHeader(
            title: 'PDF Reader',
            subtitle: _perm == true ? '${store.pdfs.length} documents' : 'Offline and ad-free',
            actions: _perm == true
                ? [
                    GlassIconBtn(Icons.refresh_rounded, _scan),
                    PopupMenuButton<String>(
                      tooltip: 'Sort',
                      color: isDark(c) ? const Color(0xFF1B1636) : Colors.white,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                      onSelected: store.setPdfSort,
                      itemBuilder: (_) => [
                        for (final e in kPdfSortLabels.entries)
                          PopupMenuItem(
                            value: e.key,
                            child: Row(children: [
                              Icon(Icons.check_rounded,
                                  size: 18, color: store.pdfSort == e.key ? kAccent : Colors.transparent),
                              const SizedBox(width: 8),
                              Text(e.value),
                            ]),
                          ),
                      ],
                      child: Glass(
                        radius: 16,
                        padding: const EdgeInsets.all(11),
                        child: Icon(Icons.sort_rounded, size: 22, color: on),
                      ),
                    ),
                  ]
                : const [],
          );
          if (_perm == null) {
            return Column(children: [header, const Expanded(child: Center(child: CircularProgressIndicator()))]);
          }
          if (_perm == false) return Column(children: [header, Expanded(child: _permissionCard(c))]);

          final q = _query.trim().toLowerCase();
          var items = sortedPdfs(store.pdfs, store.pdfSort);
          if (_favOnly) items = items.where((d) => d.fav).toList();
          if (q.isNotEmpty) items = items.where((d) => d.name.toLowerCase().contains(q)).toList();

          return Column(children: [
            header,
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
              child: TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: deco(c, 'Search PDFs by name').copyWith(
                  prefixIcon: const Icon(Icons.search_rounded),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(children: [
                ChoiceChip(
                  label: const Text('All'),
                  selected: !_favOnly,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => _favOnly = false),
                ),
                const SizedBox(width: 8),
                ChoiceChip(
                  avatar: const Icon(Icons.star_rounded, size: 18, color: kWarn),
                  label: const Text('Favourites'),
                  selected: _favOnly,
                  selectedColor: kAccent.withOpacity(0.35),
                  onSelected: (_) => setState(() => _favOnly = true),
                ),
              ]),
            ),
            if (_scanning) const LinearProgressIndicator(minHeight: 2),
            if (_note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(22, 6, 22, 0),
                child: Text(_note!, style: const TextStyle(fontSize: 12.5, color: kBad)),
              ),
            Expanded(
              child: items.isEmpty
                  ? ListView(padding: const EdgeInsets.only(top: 20), children: [
                      EmptyCard(
                        Icons.picture_as_pdf_rounded,
                        _scanning
                            ? 'Looking for PDFs on your phone...'
                            : (store.pdfs.isEmpty
                                ? 'No PDFs found yet.\nTap refresh to scan again.'
                                : 'No PDFs match.'),
                      ),
                    ])
                  : ListView.builder(
                      physics: const ClampingScrollPhysics(
                        parent: AlwaysScrollableScrollPhysics(),
                      ),
                      padding: const EdgeInsets.only(bottom: 30),
                      itemCount: items.length,
                      itemBuilder: (ctx, i) => PdfTile(
                        key: ValueKey(items[i].path),
                        doc: items[i],
                        onOpen: () => _open(ctx, items[i]),
                        onRename: () => _rename(ctx, items[i]),
                        onShare: () => _share(ctx, items[i]),
                        onInfo: () => _info(ctx, items[i]),
                        onDelete: () => _delete(ctx, items[i]),
                      ),
                    ),
            ),
          ]);
        },
      ),
    );
  }
}

/// Library row. It uses a flat translucent card instead of the blurred Glass so
/// long lists scroll smoothly.
class PdfTile extends StatelessWidget {
  final LibDoc doc;
  final VoidCallback onOpen, onRename, onShare, onInfo, onDelete;
  const PdfTile({
    super.key,
    required this.doc,
    required this.onOpen,
    required this.onRename,
    required this.onShare,
    required this.onInfo,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final on = onSurf(context);
    final d = isDark(context);
    final sub = [
      fmtBytes(doc.size),
      DateFormat('d MMM yyyy').format(DateTime.fromMillisecondsSinceEpoch(doc.modified)),
      if (doc.lastPage > 0) 'page ${doc.lastPage}${doc.pageCount > 0 ? '/${doc.pageCount}' : ''}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onOpen,
          child: Ink(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            decoration: BoxDecoration(
              color: Colors.white.withOpacity(d ? 0.08 : 0.6),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withOpacity(d ? 0.14 : 0.8)),
            ),
            child: Row(children: [
              Container(
                width: 44,
                height: 52,
                decoration: BoxDecoration(
                  color: kPdfTool.withOpacity(0.16),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.picture_as_pdf_rounded, color: kPdfTool, size: 24),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(doc.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 14.5, fontWeight: FontWeight.w700, color: on)),
                  const SizedBox(height: 3),
                  Text(sub,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: on.withOpacity(0.6))),
                ]),
              ),
              IconButton(
                visualDensity: VisualDensity.compact,
                tooltip: doc.fav ? 'Remove from favourites' : 'Add to favourites',
                icon: Icon(doc.fav ? Icons.star_rounded : Icons.star_border_rounded,
                    color: doc.fav ? kWarn : on.withOpacity(0.5)),
                onPressed: () => store.togglePdfFav(doc),
              ),
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert_rounded, color: on.withOpacity(0.55)),
                color: d ? const Color(0xFF1B1636) : Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                onSelected: (v) {
                  if (v == 'rename') onRename();
                  if (v == 'share') onShare();
                  if (v == 'info') onInfo();
                  if (v == 'delete') onDelete();
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(value: 'share', child: Text('Share')),
                  const PopupMenuItem(value: 'info', child: Text('Information')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: kBad))),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

// ───────── reader ─────────
Color pdfBgColor(String m) {
  if (m == 'sepia') return const Color(0xFFF1E4C8);
  if (m == 'blue') return const Color(0xFFD7E8F7);
  if (m == 'black') return Colors.black;
  return Colors.white;
}

/// Reading backgrounds are applied as a colour filter over the rendered pages;
/// the PDF file itself is never changed.
ColorFilter pdfFilter(String m) {
  if (m == 'sepia') return const ColorFilter.mode(Color(0xFFF1E4C8), BlendMode.multiply);
  if (m == 'blue') return const ColorFilter.mode(Color(0xFFD7E8F7), BlendMode.multiply);
  if (m == 'black') {
    return const ColorFilter.matrix(<double>[
      -1, 0, 0, 0, 255, //
      0, -1, 0, 0, 255,
      0, 0, -1, 0, 255,
      0, 0, 0, 1, 0,
    ]);
  }
  return const ColorFilter.mode(Colors.transparent, BlendMode.dst);
}

PdfPageLayout horizontalPdfLayout(List<PdfPage> pages, PdfViewerParams params) {
  final height = pages.fold<double>(0, (p, e) => math.max(p, e.height)) + params.margin * 2;
  final rects = <Rect>[];
  var x = params.margin;
  for (final pg in pages) {
    rects.add(Rect.fromLTWH(x, (height - pg.height) / 2, pg.width, pg.height));
    x += pg.width + params.margin;
  }
  return PdfPageLayout(pageLayouts: rects, documentSize: Size(x, height));
}

class PdfReaderPage extends StatefulWidget {
  final LibDoc doc;
  const PdfReaderPage({super.key, required this.doc});
  @override
  State<PdfReaderPage> createState() => _PdfReaderPageState();
}

class _PdfReaderPageState extends State<PdfReaderPage> {
  late PdfViewerController _ctrl = PdfViewerController();
  PdfTextSearcher? _searcher;
  final TextEditingController _q = TextEditingController();
  int _viewerGen = 0; // bumped to give the viewer a fresh start when the layout mode changes
  bool _ready = false, _searchOpen = false, _hasText = true;
  int _page = 1, _pages = 0;
  Timer? _saveT, _snapT;
  bool _lastHoriz = false;
  // page-by-page bookkeeping
  double? _navScale;
  int _pointers = 0, _startPage = 1;
  bool _multi = false;
  Offset _downPos = Offset.zero;

  @override
  void initState() {
    super.initState();
    _lastHoriz = store.pdfHoriz;
    WakelockPlus.toggle(enable: store.pdfKeepOn);
  }

  @override
  void dispose() {
    _saveT?.cancel();
    _snapT?.cancel();
    if (_ready) store.setPdfPage(widget.doc, _page);
    WakelockPlus.disable();
    _searcher?.removeListener(_onSearch);
    _searcher?.dispose();
    _searcher = null;
    _q.dispose();
    super.dispose();
  }

  void _onSearch() {
    if (mounted) setState(() {});
  }

  Future<String?> _askPassword() async {
    final ctl = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Password required'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          obscureText: true,
          decoration: deco(ctx, 'Password'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctl.text), child: const Text('Open')),
        ],
      ),
    );
  }

  Future<bool> _detectTextLayer(PdfDocument doc) async {
    try {
      final n = math.min(5, doc.pages.length);
      for (var i = 0; i < n; i++) {
        final t = await doc.pages[i].loadText();
        if ((t?.fullText ?? '').trim().isNotEmpty) return true;
      }
      return false;
    } catch (_) {
      return true;
    }
  }

  void _onReady(PdfDocument doc, PdfViewerController ctrl) {
    if (!mounted) return;

    // PdfTextSearcher registers for document changes in its constructor.
    // Create it only after PdfViewer reports that its document is ready.
    if (_searcher != null) {
      _searcher?.removeListener(_onSearch);
      _searcher?.dispose();
    }
    _searcher = PdfTextSearcher(ctrl)..addListener(_onSearch);

    setState(() {
      _ready = true;
      _pages = doc.pages.length;
    });
    store.setPdfPage(widget.doc, widget.doc.lastPage, count: doc.pages.length);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _navScale = _ctrl.value.getMaxScaleOnAxis();
    });
    _detectTextLayer(doc).then((v) {
      if (mounted) setState(() => _hasText = v);
    });
  }

  void _onPage(int? n) {
    if (n == null || !mounted) return;
    setState(() => _page = n);
    _saveT?.cancel();
    _saveT = Timer(const Duration(milliseconds: 600), () => store.setPdfPage(widget.doc, n));
  }

  void _go(int n) {
    if (!_ready) return;
    final t = n.clamp(1, _pages).toInt();
    _ctrl.goToPage(pageNumber: t, anchor: store.pdfHoriz ? PdfPageAnchor.center : null);
  }

  Future<void> _gotoDialog() async {
    if (!_ready) return;
    final v = await askNumber(context,
        title: 'Go to page', value: _page, min: 1, max: _pages, unit: 'Page number');
    if (v != null) _go(v);
  }

  // ── page-by-page: after a single-finger drag ends, settle on exactly one page ──
  void _pointerDown(PointerDownEvent e) {
    _pointers++;
    if (_pointers == 1) {
      _downPos = e.position;
      _startPage = _page;
      _multi = false;
    } else {
      _multi = true;
    }
  }

  void _pointerUp(PointerUpEvent e) {
    _pointers = math.max(0, _pointers - 1);
    if (_pointers != 0 || _multi || !store.pdfPaged || !_ready) return;
    final delta = e.position - _downPos;
    _snapT?.cancel();
    _snapT = Timer(const Duration(milliseconds: 90), () => _snap(delta));
  }

  void _pointerCancel(PointerCancelEvent e) => _pointers = math.max(0, _pointers - 1);

  Future<void> _snap(Offset delta) async {
    if (!mounted || !_ready) return;
    final scale = _ctrl.value.getMaxScaleOnAxis();
    _navScale ??= scale;
    if (scale > _navScale! * 1.12) return; // zoomed in: let the reader pan freely
    final dist = store.pdfHoriz ? delta.dx : delta.dy;
    var target = _ctrl.pageNumber ?? _page;
    if (dist.abs() > 36) target = _startPage + (dist < 0 ? 1 : -1);
    target = target.clamp(1, _pages).toInt();
    await _ctrl.goToPage(pageNumber: target, anchor: store.pdfHoriz ? PdfPageAnchor.center : null);
    if (mounted) _navScale = _ctrl.value.getMaxScaleOnAxis();
  }

  void _modeChanged() {
    WakelockPlus.toggle(enable: store.pdfKeepOn);
    if (_lastHoriz == store.pdfHoriz) return;
    _lastHoriz = store.pdfHoriz;
    // pdfrx 2.4 has no relayout(): a new viewer with its own controller is
    // created, and its searcher is initialized when the new viewer is ready.
    if (_ready) store.setPdfPage(widget.doc, _page);
    _searcher?.removeListener(_onSearch);
    _searcher?.dispose();
    _searcher = null;
    _q.clear();
    setState(() {
      _ctrl = PdfViewerController();
      _viewerGen++;
      _ready = false;
      _navScale = null;
    });
  }

  void _search(String v) {
    final t = v.trim();
    final searcher = _searcher;
    if (searcher == null) return;
    if (t.isEmpty) {
      searcher.resetTextSearch();
    } else {
      searcher.startTextSearch(t, caseInsensitive: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop && _ready) store.setPdfPage(widget.doc, _page);
      },
      child: ListenableBuilder(
        listenable: store,
        builder: (c, _) {
          final bg = store.pdfBg;
          final fg = bg == 'black' ? Colors.white : const Color(0xFF1B1636);
          final dim = (1 - store.pdfBright).clamp(0.0, 0.75).toDouble();
          final searcher = _searcher;
          final matches = searcher?.matches.length ?? 0;
          final cur = searcher?.currentIndex;

          Widget barBtn(IconData i, VoidCallback? f, {String? tip}) => IconButton(
                tooltip: tip,
                icon: Icon(i, color: f == null ? fg.withOpacity(0.3) : fg),
                onPressed: f,
              );

          final top = Container(
            color: pdfBgColor(bg),
            child: SafeArea(
              bottom: false,
              child: Container(
                height: 54,
                padding: const EdgeInsets.symmetric(horizontal: 4),
                color: fg.withOpacity(0.06),
                child: Row(children: [
                  barBtn(Icons.arrow_back_ios_new_rounded, () => Navigator.of(c).pop(), tip: 'Back'),
                  Expanded(
                    child: Text(widget.doc.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 15.5, fontWeight: FontWeight.w700, color: fg)),
                  ),
                  barBtn(Icons.search_rounded, () => setState(() => _searchOpen = !_searchOpen), tip: 'Search'),
                  barBtn(Icons.tune_rounded, () => showReaderSettings(c, _modeChanged), tip: 'Reading settings'),
                ]),
              ),
            ),
          );

          final searchBar = AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: !_searchOpen
                ? const SizedBox(width: double.infinity)
                : Container(
                    color: pdfBgColor(bg),
                    child: Container(
                      color: fg.withOpacity(0.06),
                      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(
                            child: TextField(
                              controller: _q,
                              autofocus: true,
                              textInputAction: TextInputAction.search,
                              style: TextStyle(color: fg),
                              cursorColor: fg,
                              decoration: InputDecoration(
                                hintText: 'Search in this PDF',
                                hintStyle: TextStyle(color: fg.withOpacity(0.5)),
                                border: InputBorder.none,
                                isDense: true,
                              ),
                              onSubmitted: _search,
                            ),
                          ),
                          if (searcher?.isSearching ?? false)
                            const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 8),
                              child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                            )
                          else if (_q.text.trim().isNotEmpty)
                            Text(matches == 0 ? 'No matches' : '${(cur ?? 0) + 1} / $matches',
                                style: TextStyle(fontSize: 12.5, color: fg.withOpacity(0.8))),
                          barBtn(Icons.keyboard_arrow_up_rounded,
                              matches > 0 ? searcher?.goToPrevMatch : null,
                              tip: 'Previous match'),
                          barBtn(Icons.keyboard_arrow_down_rounded,
                              matches > 0 ? searcher?.goToNextMatch : null,
                              tip: 'Next match'),
                          barBtn(Icons.close_rounded, () {
                            _q.clear();
                            searcher?.resetTextSearch();
                            setState(() => _searchOpen = false);
                          }, tip: 'Close search'),
                        ]),
                        if (!_hasText)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 4, right: 8),
                            child: Text(
                              'This PDF looks scanned, so it has no searchable text. Text search needs a text layer (OCR is not included).',
                              style: TextStyle(fontSize: 12, color: fg.withOpacity(0.7)),
                            ),
                          ),
                      ]),
                    ),
                  ),
          );

          final bottom = Container(
            color: pdfBgColor(bg),
            child: SafeArea(
              top: false,
              child: Container(
                height: 52,
                color: fg.withOpacity(0.06),
                child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  barBtn(Icons.chevron_left_rounded, _page > 1 ? () => _go(_page - 1) : null, tip: 'Previous page'),
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: _gotoDialog,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                      child: Text(_pages == 0 ? '– / –' : '$_page / $_pages',
                          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: fg)),
                    ),
                  ),
                  barBtn(Icons.chevron_right_rounded, _page < _pages ? () => _go(_page + 1) : null,
                      tip: 'Next page'),
                ]),
              ),
            ),
          );

          return Scaffold(
            backgroundColor: pdfBgColor(bg),
            body: Column(children: [
              top,
              searchBar,
              Expanded(
                child: Stack(children: [
                  Positioned.fill(
                    child: Listener(
                      behavior: HitTestBehavior.translucent,
                      onPointerDown: _pointerDown,
                      onPointerUp: _pointerUp,
                      onPointerCancel: _pointerCancel,
                      child: ColorFiltered(
                        colorFilter: pdfFilter(bg),
                        child: PdfViewer.file(
                          widget.doc.path,
                          key: ValueKey('pdf_${widget.doc.path}_$_viewerGen'),
                          controller: _ctrl,
                          passwordProvider: _askPassword,
                          params: PdfViewerParams(
                            backgroundColor: Colors.white,
                            layoutPages: store.pdfHoriz ? horizontalPdfLayout : null,
                            pagePaintCallbacks: searcher == null
                                ? const []
                                : [searcher.pageTextMatchPaintCallback],
                            calculateInitialPageNumber: (doc, ctrl) {
                              final n = widget.doc.lastPage;
                              return (n >= 1 && n <= doc.pages.length) ? n : 1;
                            },
                            onViewerReady: _onReady,
                            onPageChanged: _onPage,
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (dim > 0)
                    Positioned.fill(
                      child: IgnorePointer(child: ColoredBox(color: Colors.black.withOpacity(dim))),
                    ),
                ]),
              ),
              bottom,
            ]),
          );
        },
      ),
    );
  }
}

Future<void> showReaderSettings(BuildContext context, VoidCallback onChanged) {
  const panelBackground = Color(0xF21D1A30);
  const panelTop = Color(0xF226203D);
  const panelBorder = Color(0x35FFFFFF);
  const primaryText = Color(0xFFF7F5FF);
  const secondaryText = Color(0xFFB9B1D0);
  const violet = Color(0xFF9B75FF);
  const violetSoft = Color(0xFF7654D6);

  return showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black54,
    builder: (ctx) {
      // The reader's selected page background is deliberately not consulted here.
      // This modal owns a stable dark palette regardless of White/Sepia/Blue/Black.
      final modalTheme = Theme.of(ctx).copyWith(
        brightness: Brightness.dark,
        colorScheme: const ColorScheme.dark(
          primary: violet,
          secondary: violetSoft,
          surface: panelBackground,
          onSurface: primaryText,
        ),
        scaffoldBackgroundColor: panelBackground,
        canvasColor: panelBackground,
        iconTheme: const IconThemeData(color: violet, size: 22),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected) ? Colors.white : secondaryText),
          trackColor: WidgetStateProperty.resolveWith((states) =>
              states.contains(WidgetState.selected)
                  ? violet.withOpacity(0.78)
                  : Colors.white.withOpacity(0.20)),
          trackOutlineColor: WidgetStateProperty.all(Colors.white.withOpacity(0.16)),
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: violet,
          inactiveTrackColor: Color(0xFF514A67),
          thumbColor: Color(0xFFF7F5FF),
          overlayColor: Color(0x339B75FF),
          valueIndicatorColor: violetSoft,
        ),
      );

      return Theme(
        data: modalTheme,
        child: ListenableBuilder(
          listenable: store,
          builder: (c, _) {
            Widget settingRow(IconData icon, String title, bool value, VoidCallback toggle) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: [
                    SizedBox(
                      width: 30,
                      height: 42,
                      child: Icon(icon, color: violet, size: 22),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        title,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: primaryText,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Switch(
                      value: value,
                      materialTapTargetSize: MaterialTapTargetSize.padded,
                      onChanged: (_) {
                        toggle();
                        onChanged();
                      },
                    ),
                  ],
                ),
              );
            }

            Widget swatch(String key, String label) {
              final selected = store.pdfBg == key;
              return Expanded(
                child: Semantics(
                  button: true,
                  selected: selected,
                  label: '$label reading background',
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      if (store.pdfBg != key) {
                        store.pdfBg = key;
                        store.savePdfPrefs();
                        onChanged();
                      }
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Column(
                        children: [
                          AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 46,
                            height: 46,
                            decoration: BoxDecoration(
                              color: pdfBgColor(key),
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: selected ? violet : Colors.white.withOpacity(0.34),
                                width: selected ? 3 : 1,
                              ),
                              boxShadow: selected
                                  ? [
                                      BoxShadow(
                                        color: violet.withOpacity(0.30),
                                        blurRadius: 9,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                            child: selected
                                ? const Center(
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        color: violet,
                                        shape: BoxShape.circle,
                                      ),
                                      child: SizedBox(width: 9, height: 9),
                                    ),
                                  )
                                : null,
                          ),
                          const SizedBox(height: 7),
                          Text(
                            label,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: selected ? FontWeight.w800 : FontWeight.w500,
                              color: selected ? primaryText : secondaryText,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }

            return SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(c).height * 0.88,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(30),
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [panelTop, panelBackground],
                          ),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(color: panelBorder, width: 1),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withOpacity(0.24),
                              blurRadius: 24,
                              offset: const Offset(0, 10),
                            ),
                          ],
                        ),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(22, 22, 22, 20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                'Reading settings',
                                style: TextStyle(
                                  fontSize: 21,
                                  fontWeight: FontWeight.w800,
                                  color: primaryText,
                                ),
                              ),
                              const SizedBox(height: 18),
                              const Text(
                                'Background',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: secondaryText,
                                ),
                              ),
                              const SizedBox(height: 10),
                              Row(
                                children: [
                                  swatch('white', 'White'),
                                  swatch('sepia', 'Sepia'),
                                  swatch('blue', 'Light blue'),
                                  swatch('black', 'Black'),
                                ],
                              ),
                              const SizedBox(height: 15),
                              Divider(color: Colors.white.withOpacity(0.12), height: 1),
                              const SizedBox(height: 14),
                              Row(
                                children: const [
                                  Icon(Icons.brightness_6_rounded, color: violet, size: 22),
                                  SizedBox(width: 12),
                                  Text(
                                    'Brightness',
                                    style: TextStyle(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: primaryText,
                                    ),
                                  ),
                                ],
                              ),
                              Slider(
                                value: store.pdfBright.clamp(0.25, 1.0).toDouble(),
                                min: 0.25,
                                max: 1.0,
                                onChanged: (value) {
                                  store.pdfBright = value;
                                  store.savePdfPrefs();
                                },
                              ),
                              const SizedBox(height: 5),
                              Divider(color: Colors.white.withOpacity(0.12), height: 1),
                              const SizedBox(height: 7),
                              settingRow(
                                Icons.screen_lock_portrait_rounded,
                                'Keep screen on',
                                store.pdfKeepOn,
                                () {
                                  store.pdfKeepOn = !store.pdfKeepOn;
                                  store.savePdfPrefs();
                                },
                              ),
                              Divider(color: Colors.white.withOpacity(0.10), height: 1),
                              settingRow(
                                Icons.swap_horiz_rounded,
                                'Horizontal reading',
                                store.pdfHoriz,
                                () {
                                  store.pdfHoriz = !store.pdfHoriz;
                                  store.savePdfPrefs();
                                },
                              ),
                              Divider(color: Colors.white.withOpacity(0.10), height: 1),
                              settingRow(
                                Icons.auto_stories_rounded,
                                'Page by page',
                                store.pdfPaged,
                                () {
                                  store.pdfPaged = !store.pdfPaged;
                                  store.savePdfPrefs();
                                },
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      );
    },
  );
}
