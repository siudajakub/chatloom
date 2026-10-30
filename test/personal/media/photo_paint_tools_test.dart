// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:ui' show Offset, Rect, Size;

import 'package:chatloom/personal/media/editor/paint_layer_geometry.dart';
import 'package:chatloom/personal/media/editor/paint_session.dart';
import 'package:chatloom/personal/media/editor/photo_editor_source.dart';
import 'package:flutter/widgets.dart' show Matrix4, MatrixUtils;
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pro_image_editor/pro_image_editor.dart';

PaintedModel _stroke(
  PaintMode mode,
  List<Offset?> offsets, {
  double width = 4,
  bool fill = false,
}) => PaintedModel(
  mode: mode,
  offsets: offsets,
  erasedOffsets: [],
  color: const ui.Color(0xFFFFFFFF),
  strokeWidth: width,
  opacity: 1,
  fill: fill,
);

PaintLayer _layer(PaintedModel item, Size rawSize, {LayerMask? mask}) =>
    PaintLayer(item: item, rawSize: rawSize, opacity: 1, mask: mask);

Future<ui.Image> _decode(Uint8List bytes) async {
  final codec = await ui.instantiateImageCodec(bytes);
  final frame = await codec.getNextFrame();
  codec.dispose();
  return frame.image;
}

Future<List<int>> _pixel(ui.Image image, int x, int y) async {
  final data = (await image.toByteData(
    format: ui.ImageByteFormat.rawStraightRgba,
  ))!;
  final i = (y * image.width + x) * 4;
  return [for (var c = 0; c < 4; c++) data.getUint8(i + c)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('paintedModelHit', () {
    test('a box censor area is hit inside its box only', () {
      final area = _stroke(PaintMode.blur, const [
        Offset.zero,
        Offset(100, 60),
      ]);
      expect(paintedModelHit(area, const Offset(50, 30)), isTrue);
      expect(paintedModelHit(area, const Offset(2, 2)), isTrue);
      expect(paintedModelHit(area, const Offset(110, 30)), isFalse);
      expect(paintedModelHit(area, const Offset(108, 30), slop: 10), isTrue);
    });

    test('an oval censor area misses its corners', () {
      final area = _stroke(PaintMode.pixelate, const [
        Offset.zero,
        Offset(100, 60),
      ]);
      expect(
        paintedModelHit(area, const Offset(50, 30), ovalCensor: true),
        isTrue,
      );
      expect(
        paintedModelHit(area, const Offset(4, 4), ovalCensor: true),
        isFalse,
      );
      expect(paintedModelHit(area, const Offset(4, 4)), isTrue);
    });

    test('a pen stroke is hit near its line, also across a gap', () {
      final pen = _stroke(PaintMode.freeStyle, const [
        Offset(0, 50),
        Offset(100, 50),
        null,
        Offset(200, 50),
      ]);
      expect(paintedModelHit(pen, const Offset(50, 51)), isTrue);
      expect(paintedModelHit(pen, const Offset(50, 60)), isFalse);
      expect(paintedModelHit(pen, const Offset(50, 60), slop: 10), isTrue);
      // The null breaks the line: nothing between 100 and 200.
      expect(paintedModelHit(pen, const Offset(150, 50), slop: 10), isFalse);
      expect(paintedModelHit(pen, const Offset(200, 52)), isTrue);
    });

    test('an outlined box is hit on its edge, a filled one inside', () {
      const points = [Offset(0, 0), Offset(100, 100)];
      final outline = _stroke(PaintMode.rect, points);
      expect(paintedModelHit(outline, const Offset(1, 50)), isTrue);
      expect(paintedModelHit(outline, const Offset(50, 50)), isFalse);
      final filled = _stroke(PaintMode.rect, points, fill: true);
      expect(paintedModelHit(filled, const Offset(50, 50)), isTrue);
    });

    test('a circle is hit on its outline', () {
      final circle = _stroke(PaintMode.circle, const [
        Offset(0, 0),
        Offset(100, 100),
      ]);
      expect(paintedModelHit(circle, const Offset(50, 1)), isTrue);
      expect(paintedModelHit(circle, const Offset(50, 50)), isFalse);
      expect(paintedModelHit(circle, const Offset(2, 2)), isFalse);
    });

    test('an arrow is hit along its shaft', () {
      final arrow = _stroke(PaintMode.arrow, const [
        Offset(0, 0),
        Offset(100, 100),
      ]);
      expect(paintedModelHit(arrow, const Offset(50, 51)), isTrue);
      expect(paintedModelHit(arrow, const Offset(80, 20)), isFalse);
    });
  });

  group('PaintLayerPlacement', () {
    test('maps the canvas into the layer through scale, turn and flip', () {
      const placement = PaintLayerPlacement(
        center: Offset(200, 100),
        rawSize: Size(100, 50),
        scale: 2,
      );
      expect(placement.rect, const Rect.fromLTWH(100, 50, 200, 100));
      expect(placement.toLayer(const Offset(200, 100)), const Offset(50, 25));
      expect(placement.toLayer(const Offset(100, 50)), Offset.zero);

      const turned = PaintLayerPlacement(
        center: Offset(200, 100),
        rawSize: Size(100, 50),
        scale: 1,
        rotation: math.pi / 2,
      );
      // A quarter turn clockwise: the layer's right edge points down.
      final local = turned.toLayer(const Offset(200, 140));
      expect(local.dx, closeTo(90, 1e-9));
      expect(local.dy, closeTo(25, 1e-9));

      const flipped = PaintLayerPlacement(
        center: Offset(200, 100),
        rawSize: Size(100, 50),
        scale: 1,
        flipX: true,
      );
      expect(flipped.toLayer(const Offset(160, 100)), const Offset(90, 25));
    });

    test('undoes turn and flips in reverse of the package\'s LayerWidget', () {
      // `layer_widget.dart` `_calcTransformMatrix`: the content is turned
      // first, then flipped (rotateX/Y act after rotateZ on the point).
      Offset toCanvas(PaintLayerPlacement p, Offset local) {
        final matrix = Matrix4.identity()
          ..setEntry(3, 2, 0.001)
          ..rotateX(p.flipY ? math.pi : 0)
          ..rotateY(p.flipX ? math.pi : 0)
          ..rotateZ(p.rotation);
        final half = Offset(p.rawSize.width, p.rawSize.height) / 2;
        return p.center +
            MatrixUtils.transformPoint(matrix, (local - half) * p.scale);
      }

      for (final (flipX, flipY, rotation) in [
        (true, false, 0.7),
        (false, true, -1.2),
        (true, true, 2.0),
        (false, false, 0.3),
      ]) {
        final placement = PaintLayerPlacement(
          center: const Offset(180, 240),
          rawSize: const Size(120, 40),
          scale: 1.5,
          rotation: rotation,
          flipX: flipX,
          flipY: flipY,
        );
        for (final local in const [Offset(10, 5), Offset(110, 30)]) {
          final back = placement.toLayer(toCanvas(placement, local));
          expect(back.dx, closeTo(local.dx, 1e-6), reason: '$flipX $flipY');
          expect(back.dy, closeTo(local.dy, 1e-6), reason: '$flipX $flipY');
        }
        // The turned box holds every corner.
        for (final corner in const [
          Offset.zero,
          Offset(120, 0),
          Offset(0, 40),
          Offset(120, 40),
        ]) {
          expect(
            placement.bounds
                .inflate(1e-6)
                .contains(toCanvas(placement, corner)),
            isTrue,
          );
        }
      }
    });

    test('a swipe is tested as a segment, layers away are skipped', () {
      final pen = _stroke(PaintMode.freeStyle, const [
        Offset(0, 20),
        Offset(200, 20),
      ], width: 2);
      final layer = _layer(pen, const Size(200, 40));
      const placement = PaintLayerPlacement(
        center: Offset(200, 200),
        rawSize: Size(200, 40),
        scale: 1,
      );
      // Both ends far from the line, the move crosses it.
      expect(paintLayerHit(layer, placement, const Offset(200, 120)), isFalse);
      expect(
        paintLayerHit(
          layer,
          placement,
          const Offset(200, 120),
          to: const Offset(200, 280),
        ),
        isTrue,
      );
      // Beside the layer's box: rejected before any stroke is walked.
      expect(placement.bounds, const Rect.fromLTWH(100, 180, 200, 40));
      expect(
        paintLayerHit(
          layer,
          placement,
          const Offset(320, 120),
          to: const Offset(320, 280),
          touchRadius: 12,
        ),
        isFalse,
      );
      // An oval area: a sweep through its box corner misses it.
      final area = _stroke(PaintMode.blur, const [
        Offset.zero,
        Offset(100, 100),
      ]);
      expect(
        paintedModelHit(
          area,
          const Offset(-5, 10),
          to: const Offset(10, -5),
          ovalCensor: true,
        ),
        isFalse,
      );
      expect(
        paintedModelHit(area, const Offset(-5, 10), to: const Offset(10, -5)),
        isTrue,
      );
    });

    test('paintLayerHit uses the layer box on the canvas and its mask', () {
      final area = _stroke(PaintMode.blur, const [
        Offset.zero,
        Offset(100, 50),
      ]);
      final box = _layer(area, const Size(100, 50));
      final oval = _layer(area, const Size(100, 50), mask: censorOvalMask);
      final placement = PaintLayerPlacement.of(
        box,
        canvasSize: const Size(400, 200),
        stackScale: 1,
      );
      expect(placement.center, const Offset(200, 100));
      expect(paintLayerHit(box, placement, const Offset(152, 77)), isTrue);
      expect(paintLayerHit(oval, placement, const Offset(152, 77)), isFalse);
      expect(paintLayerHit(oval, placement, const Offset(200, 100)), isTrue);
      expect(isOvalCensorArea(oval), isTrue);
      expect(isOvalCensorArea(box), isFalse);
    });
  });

  group('CensorStrength', () {
    test('maps the slider to each mode, strong even at its lowest', () {
      expect(CensorStrength.blurSigma(0), CensorStrength.minBlurSigma);
      expect(CensorStrength.blurSigma(1), CensorStrength.maxBlurSigma);
      expect(CensorStrength.blurSigma(2), CensorStrength.maxBlurSigma);
      // Pixelate blocks are dp · dpr² in the package's units.
      expect(
        CensorStrength.pixelBlockSize(0, 2),
        CensorStrength.minBlockDp * 4,
      );
      expect(
        CensorStrength.of(PaintMode.pixelate, 1, 3),
        CensorStrength.maxBlockDp * 9,
      );
      expect(CensorStrength.of(PaintMode.freeStyle, 0.5, 2), isNull);
    });

    test('the session clamps and notifies', () {
      final session = PhotoPaintSession();
      var changes = 0;
      session.addListener(() => changes++);
      session
        ..strength = 3
        ..shape = CensorShape.oval
        ..censor = true;
      expect(session.strength, 1);
      expect(changes, 3);
      session.dispose();
    });
  });

  group('preparePhotoForEditing', () {
    test('the bitmap wrapper decodes to the same pixels', () async {
      final rgba = Uint8List.fromList([
        255, 0, 0, 255, 0, 255, 0, 255, //
        0, 0, 255, 128, 10, 20, 30, 255,
      ]);
      final opaque = await _decode(rgbaBitmap(rgba, 2, 2));
      expect(await _pixel(opaque, 0, 0), [255, 0, 0, 255]);
      expect(await _pixel(opaque, 1, 0), [0, 255, 0, 255]);
      // Without alpha the bitmap is opaque.
      expect(await _pixel(opaque, 0, 1), [0, 0, 255, 255]);
      expect(await _pixel(opaque, 1, 1), [10, 20, 30, 255]);
      final transparent = await _decode(rgbaBitmap(rgba, 2, 2, alpha: true));
      expect((await _pixel(transparent, 0, 1))[3], 128);
    });

    test('a photo within the output size is kept as it is', () async {
      final small = img.encodeJpg(img.Image(width: 64, height: 48));
      expect(identical(await preparePhotoForEditing(small), small), isTrue);
    });

    test('a larger photo is scaled down to the output size', () async {
      final image = img.Image(width: 300, height: 100);
      img.fill(image, color: img.ColorRgb8(30, 120, 220));
      final bytes = img.encodePng(image);
      final prepared = await preparePhotoForEditing(bytes, maxSide: 150);
      expect(identical(prepared, bytes), isFalse);
      expect(prepared.sublist(0, 2), [0x42, 0x4D]);
      final decoded = await _decode(prepared);
      expect((decoded.width, decoded.height), (150, 50));
      final pixel = await _pixel(decoded, 75, 25);
      expect(pixel[0], closeTo(30, 2));
      expect(pixel[1], closeTo(120, 2));
      expect(pixel[2], closeTo(220, 2));
    });

    test('an undecodable source is passed through', () async {
      final junk = Uint8List.fromList(List.filled(64, 7));
      expect(identical(await preparePhotoForEditing(junk), junk), isTrue);
    });
  });
}
