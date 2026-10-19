# SPDX-License-Identifier: AGPL-3.0-or-later
"""Pure tests for the design-token lint; no Flutter or network."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location('design_lint', Path(__file__).with_name('check-design-tokens.py'))
lint = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lint)


class DesignLintTest(unittest.TestCase):
    def hits(self, source, notion=False):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / 'sample.dart'
            path.write_text(source)
            return sorted(rule for rule, _ in lint.scan(path, notion))

    def test_flags_raw_values(self):
        self.assertEqual(self.hits('''
final a = Color(0xFF000000);
final b = Colors.red;
final c = TextStyle(fontSize: 13);
final d = BorderRadius.circular(18);
final e = EdgeInsets.fromLTRB(
  0,
  8,
  0,
  0,
);
final f = AlertDialog(title: x);
final g = BackdropFilter(filter: blur, child: x);
'''), ['backdrop-filter', 'edge-insets', 'font-size', 'legacy-widget', 'material-color', 'radius', 'raw-color'])

    def test_allows_tokens_zero_transparent_comments_and_opt_out(self):
        self.assertEqual(self.hits('''
final a = Colors.transparent;
final b = EdgeInsets.all(0);
final c = EdgeInsets.symmetric(horizontal: NotionSpace.md);
final d = TextStyle(fontSize: AppConfig.messageFontSize);
// final e = Colors.red;
final f = 'Colors.red // not code';
final g = Colors.black; // design-lint: allow video scrim must be pure black
'''), [])


    def test_flags_motion_debt(self):
        self.assertEqual(self.hits('''
import 'package:flutter_animate/flutter_animate.dart';
import "package:skeletonizer/skeletonizer.dart";
import 'package:flutter/material.dart';
final a = child.animate().blur(begin: Offset(4, 4));
final b = ImageFiltered(imageFilter: f, child: x);
final c = AnimatedOpacity(duration: const Duration(milliseconds: 250), opacity: 1);
final d = AnimatedSwitcher(reverseDuration: Duration(milliseconds: 90), child: x);
'''), ['legacy-material-import', 'motion-blur', 'motion-blur', 'motion-duration', 'motion-duration', 'motion-import', 'motion-import'])

    def test_allows_motion_tokens_and_static_blur_filters(self):
        self.assertEqual(self.hits('''
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
// import 'package:flutter_animate/flutter_animate.dart';
final a = AnimatedOpacity(duration: NotionMotion.short, opacity: 1);
final b = ImageFilter.blur(sigmaX: 2, sigmaY: 2);
final c = Future.delayed(const Duration(milliseconds: 300));
final d = Tween<double>(begin: 0, end: 1).animate(controller);
'''), [])

    def test_notion_files_never_mount_the_animate_widget(self):
        self.assertEqual(self.hits('''
final a = Animate(effects: effects, child: x);
final b = child.animate(delay: 100.ms).fadeIn();
final c = AnimateList(interval: 30.ms, children: x);
final d = Tween<double>(begin: 0, end: 1).animate(controller);
final e = Animate(); // design-lint: allow unmounted owner
final f = Colors.red;
''', notion=True), ['motion-animate-widget', 'motion-animate-widget', 'motion-animate-widget'])


if __name__ == '__main__':
    unittest.main()
