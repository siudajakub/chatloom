#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-or-later
"""Flag raw design values outside the Notion design system (see DESIGN.md).

Rules (per file, per rule counts):
  raw-color        Color(0x…), Color.fromARGB/fromRGBO
  material-color   Colors.* other than Colors.transparent
  font-size        fontSize: <number>
  edge-insets      EdgeInsets.*(…<number>…) other than 0
  radius           BorderRadius.circular(<number>) / Radius.circular(<number>)
  legacy-widget    AlertDialog(, ElevatedButton(, showAboutDialog(
  backdrop-filter  raw BackdropFilter( outside lib/ui/notion (use NotionGlassSurface)
  motion-import    importing flutter_animate or skeletonizer outside lib/ui/notion
                   (use NotionEntrance, NotionPop, NotionSkeleton, ...)
  motion-blur      flutter_animate .blur(, BlurEffect(, ImageFiltered( (blur is
                   expensive on Android and never animated)
  motion-duration  a literal Duration in a duration:/reverseDuration: argument
                   (use NotionMotion.* tokens)
  legacy-material-import  package:flutter/material.dart (the app uses material_ui)
  motion-animate-widget   (lib/ui/notion only) mounting flutter_animate's
                   Animate/AnimateList or `.animate(...)`: they start timers
  square-corner    (also in lib/ui/notion) a square or near-square shape:
                   BorderRadius.zero, Radius.zero, a literal radius below 6,
                   RoundedRectangleBorder/OutlineInputBorder without a
                   borderRadius, ContinuousRectangleBorder, BeveledRectangleBorder
                   (use NotionRadius.* / NotionShapes.*; nothing is square)

Exempt: lib/ui/notion/ (the token source), lib/utils/code_highlight_theme.dart,
lib/l10n/ and generated files. A line ending in `// design-lint: allow`
is skipped; say why in the same comment.

The baseline (scripts/design-baseline.json) freezes today's debt. Default
mode only reports. --strict fails when any file/rule count grows above the
baseline (ratchet); --update-baseline rewrites it after debt was paid down.
"""
import argparse
import json
from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]
BASELINE = ROOT / 'scripts/design-baseline.json'
EXEMPT_DIRS = ('lib/ui/notion/', 'lib/l10n/')
EXEMPT_FILES = {'lib/utils/code_highlight_theme.dart'}
ALLOW = 'design-lint: allow'
NUMBER = re.compile(r'(?<![\w.])(\d+(?:\.\d+)?)(?![\w.])')

# Matched on the raw line (import URIs are string literals).
RAW = {
    'motion-import': re.compile(r'^\s*(?:import|export)\s+[\'"]package:(?:flutter_animate|skeletonizer)/'),
    'legacy-material-import': re.compile(r'^\s*(?:import|export)\s+[\'"]package:flutter/material\.dart'),
}
# Checked inside lib/ui/notion, which is otherwise exempt.
NOTION_RULES = {
    'motion-animate-widget': re.compile(r'\bAnimate(?:List)?\(|\.animate\(\s*(?:\)|[a-zA-Z]+\s*:)'),
}
SIMPLE = {
    'raw-color': re.compile(r'\bColor(?:\(\s*0x|\.from(?:ARGB|RGBO)\()'),
    'material-color': re.compile(r'\bColors\.(?!transparent\b)[a-zA-Z]'),
    'font-size': re.compile(r'\bfontSize:\s*\d'),
    'radius': re.compile(r'\b(?:BorderRadius|Radius)\.circular\(\s*\d'),
    'legacy-widget': re.compile(r'\b(?:AlertDialog|ElevatedButton|showAboutDialog)\('),
    'backdrop-filter': re.compile(r'\bBackdropFilter(?:\.grouped)?\('),
    'motion-blur': re.compile(r'(?<!ImageFilter)\.blur\(|\bBlurEffect\(|\bImageFiltered\('),
    'motion-duration': re.compile(r'\b(?:duration|reverseDuration|transitionDuration|reverseTransitionDuration):\s*(?:const\s+)?Duration\('),
}
SQUARE = re.compile(
    r'\b(?:BorderRadius(?:Directional)?|Radius)\.zero\b'
    r'|\b(?:ContinuousRectangleBorder|BeveledRectangleBorder)\('
    r'|\b(?:BorderRadius|Radius)\.circular\(\s*[0-5](?:\.\d+)?\s*\)'
)
# Default radius is zero (RoundedRectangleBorder) or 4 (OutlineInputBorder).
NEEDS_RADIUS = re.compile(r'\b(?:RoundedRectangleBorder|OutlineInputBorder)\(')
INSETS = re.compile(r'\bEdgeInsets(?:Directional)?\.(?:all|symmetric|only|fromLTRB|fromSTEB)\(')
HINTS = {
    'raw-color': 'context.notion.colors.*',
    'material-color': 'context.notion.colors.* (danger/success/warning/info for status)',
    'font-size': 'NotionType.* or context.notion.typography.*',
    'edge-insets': 'NotionSpace.* (4/8/12/16/20/24/32)',
    'radius': 'NotionRadius.smAll/mdAll/lgAll/pillAll',
    'legacy-widget': 'NotionDialog/showNotionDialog or NotionButton',
    'backdrop-filter': 'NotionGlassSurface/NotionGlassBar (header, dock, composer only)',
    'motion-import': 'Notion motion primitives from notion.dart (DESIGN.md "Motion")',
    'motion-blur': 'opacity/transform motion; static blur only via NotionGlassSurface',
    'motion-duration': 'NotionMotion.instant/quick/short/medium/long',
    'legacy-material-import': "package:material_ui/material_ui.dart",
    'motion-animate-widget': 'controller-driven effects (_EffectChain in notion_entrance.dart)',
    'square-corner': 'NotionRadius.* / NotionShapes.* (DESIGN.md "Radius": nothing is square)',
}


def strip_comment(line):
    # Good enough for Dart sources: drop `//` comments and blank out string
    # literal contents so that copy text never counts as code.
    quote, out = None, []
    for index, char in enumerate(line):
        if quote:
            if char == quote and line[index - 1] != '\\':
                quote = None
                out.append(char)
            else:
                out.append(' ')
        elif char in '\'"':
            quote = char
            out.append(char)
        elif line.startswith('//', index):
            break
        else:
            out.append(char)
    return ''.join(out)


def matching_paren(text, start):
    depth = 0
    for index in range(start, len(text)):
        if text[index] == '(':
            depth += 1
        elif text[index] == ')':
            depth -= 1
            if depth == 0:
                return index
    return len(text)


def square_corners(code, allowed):
    hits = []
    for number, line in enumerate(code.split('\n'), 1):
        if number not in allowed:
            hits += [('square-corner', number)] * len(SQUARE.findall(line))
    for match in NEEDS_RADIUS.finditer(code):
        number = code.count('\n', 0, match.start()) + 1
        if number in allowed:
            continue
        args = code[match.end():matching_paren(code, match.end() - 1)]
        if 'borderRadius' not in args:
            hits.append(('square-corner', number))
    return hits


def scan(path, notion=False):
    raw = path.read_text(encoding='utf-8')
    lines = raw.split('\n')
    allowed = {i for i, line in enumerate(lines, 1) if ALLOW in line}
    code = '\n'.join(strip_comment(line) for line in lines)
    hits = square_corners(code, allowed)
    if notion:
        for number, line in enumerate(code.split('\n'), 1):
            if number in allowed:
                continue
            for rule, pattern in NOTION_RULES.items():
                hits += [(rule, number)] * len(pattern.findall(line))
        return hits
    for number, line in enumerate(lines, 1):
        if number in allowed:
            continue
        for rule, pattern in RAW.items():
            if pattern.search(line):
                hits.append((rule, number))
    for number, line in enumerate(code.split('\n'), 1):
        if number in allowed:
            continue
        for rule, pattern in SIMPLE.items():
            hits += [(rule, number)] * len(pattern.findall(line))
    for match in INSETS.finditer(code):
        number = code.count('\n', 0, match.start()) + 1
        if number in allowed:
            continue
        args = code[match.end():matching_paren(code, match.end() - 1)]
        if any(float(value) != 0 for value in NUMBER.findall(args)):
            hits.append(('edge-insets', number))
    return hits


def sources():
    """Yields (relative, path, notion): notion files get only NOTION_RULES."""
    for path in sorted((ROOT / 'lib').rglob('*.dart')):
        relative = path.relative_to(ROOT).as_posix()
        if relative.endswith(('.g.dart', '.freezed.dart')):
            continue
        if relative.startswith('lib/ui/notion/'):
            yield relative, path, True
            continue
        if relative.startswith(EXEMPT_DIRS) or relative in EXEMPT_FILES:
            continue
        yield relative, path, False


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--strict', action='store_true', help='fail on counts above the baseline')
    parser.add_argument('--update-baseline', action='store_true')
    parser.add_argument('--verbose', action='store_true', help='list every new hit with its line')
    args = parser.parse_args()

    counts, lines = {}, {}
    for relative, path, notion in sources():
        for rule, number in scan(path, notion):
            key = f'{relative}::{rule}'
            counts[key] = counts.get(key, 0) + 1
            lines.setdefault(key, []).append(number)

    if args.update_baseline:
        BASELINE.write_text(json.dumps(dict(sorted(counts.items())), indent=1) + '\n')
        print(f'design-lint: baseline updated with {sum(counts.values())} hits in {len({k.split("::")[0] for k in counts})} files')
        return 0

    baseline = json.loads(BASELINE.read_text()) if BASELINE.is_file() else {}
    grown = {key: (count, baseline.get(key, 0)) for key, count in counts.items() if count > baseline.get(key, 0)}
    paid = sum(max(0, value - counts.get(key, 0)) for key, value in baseline.items())
    totals = {}
    for key, count in counts.items():
        rule = key.split('::')[1]
        totals[rule] = totals.get(rule, 0) + count
    summary = ', '.join(f'{rule} {count}' for rule, count in sorted(totals.items()))
    print(f'design-lint: {sum(counts.values())} legacy hits ({summary}); baseline {sum(baseline.values())}, paid down {paid}')
    for key, (count, allowed) in sorted(grown.items()):
        relative, rule = key.split('::')
        where = ','.join(str(n) for n in lines[key]) if args.verbose else str(lines[key][-1])
        print(f'  NEW {relative}:{where} {rule} {count} > baseline {allowed}; use {HINTS[rule]}')
    if paid:
        print('  Debt was paid down; run scripts/check-design-tokens.py --update-baseline to lock it in.')
    if grown and args.strict:
        print('FAIL design-lint: new raw design values; see client/DESIGN.md')
        return 1
    if grown:
        print('REPORT design-lint: new raw design values (report mode, not failing)')
    else:
        print('PASS design-lint: no growth above baseline')
    return 0


if __name__ == '__main__':
    sys.exit(main())
