// SPDX-License-Identifier: AGPL-3.0-or-later
// J, 2026-10-24: sending media never asks whether to compress. Every entry
// point (attach menu, gallery, camera, paste, drag and drop, sharing into
// the app, merged person chat, keyboard-inserted images) compresses on the
// device; the only choice is the small "HD" chip in the send preview, and
// the original file is reachable only through the attach menu's "File".
// These source checks keep a new entry point from bringing a prompt back;
// the preview itself is covered by test/notion/attachment_flow_test.dart.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _dartFiles(String root) => Directory(root)
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('only the two composers open the send preview', () {
    final openers = {
      for (final file in _dartFiles('lib'))
        if (_read(file.path).contains(RegExp(r'\bSendFileDialog\(')))
          file.path.replaceAll(r'\', '/'),
    };
    expect(openers, {
      'lib/pages/chat/chat.dart',
      'lib/pages/chat/send_file_dialog.dart', // the class itself
      'lib/personal/merged_chat_page.dart',
    });
  });

  test('no compression question or quality pills remain in lib/', () {
    final forbidden = [
      RegExp(r'\binitialCompress\b'),
      RegExp(r"label:\s*'Compressed'"),
      RegExp(r"'Original file'"),
      RegExp(r"'Original · "),
      RegExp(r'\b(l10n|L10n\.of\(\w+\))\.compress\b'),
      RegExp(r'\b(l10n|L10n\.of\(\w+\))\.sendOriginal\b'),
      RegExp(r'\b_QualityChoice\b'),
    ];
    final hits = <String>[];
    for (final file in _dartFiles('lib')) {
      final source = _read(file.path);
      for (final pattern in forbidden) {
        if (pattern.hasMatch(source)) hits.add('${file.path}: $pattern');
      }
    }
    expect(hits, isEmpty);
  });

  test('in a chat only the attach menu "File" sends originals', () {
    final chat = _read('lib/pages/chat/chat.dart');
    // The one caller that passes asFiles: the "File" picker (any type).
    expect(
      RegExp(r'\basFiles:\s*[^,)]+').allMatches(chat).map((m) => m[0]).toList(),
      ['asFiles: type == FileType.any'],
    );
    expect(RegExp(r'sendAsFiles:\s*[^,)]+').allMatches(chat).map((m) => m[0]), [
      'sendAsFiles: asFiles',
    ]);
    final action = chat.substring(
      chat.indexOf('Future<void> sendFileAction('),
      chat.indexOf('Future<void> sendImageFromClipBoard('),
    );
    expect(action, contains('asFiles: type == FileType.any'));
    // Every other route (gallery, cameras, paste, drop, share intent)
    // calls _pickAttachments without asFiles.
    final routes = RegExp(r'_pickAttachments\(').allMatches(chat).length;
    expect(routes, greaterThanOrEqualTo(7));
    final menu = chat.substring(
      chat.indexOf('case AddPopupMenuActions.gallery:'),
      chat.indexOf('case AddPopupMenuActions.poll:'),
    );
    expect(menu, contains('sendFileAction(type: FileType.media)'));
  });

  test('in a merged chat only the attach menu "File" sends originals', () {
    final merged = _read('lib/personal/merged_chat_page.dart');
    final originals = RegExp(r'asFiles:\s*true').allMatches(merged).toList();
    expect(originals, hasLength(1));
    final fileCase = merged.indexOf('case AddPopupMenuActions.file:');
    final nextCase = merged.indexOf('case AddPopupMenuActions.poll:');
    expect(originals.single.start, greaterThan(fileCase));
    expect(originals.single.start, lessThan(nextCase));
  });

  test('keyboard-inserted images are compressed without a preview', () {
    final input = _read('lib/pages/chat/input_bar.dart');
    final start = input.indexOf('onContentInserted:');
    final insert = input.substring(start, input.indexOf('minLines:', start));
    expect(
      insert,
      contains('shrinkImageMaxDimension: MediaQuality.photoMaxSide'),
    );
    expect(insert, isNot(contains('showSendFileDialog')));
    expect(insert, isNot(contains('Compress')));
  });
}
