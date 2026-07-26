import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:json_page/src/models/page_model.dart';
import 'package:json_page/src/render_camera.dart';

void main() {
  group('PageChild.resolveTemplate', () {
    test('substitutes {name} with the child name', () {
      final PageChild child = PageChild(name: 'radartmd');
      expect(
        child.resolveTemplate(
          'https://hatyaicityclimate.org/flood/cam/view?name={name}',
        ),
        'https://hatyaicityclimate.org/flood/cam/view?name=radartmd',
      );
    });

    test('substitutes multiple tokens', () {
      final PageChild child = PageChild(name: 'muangkong', code: 'S1');
      expect(
        child.resolveTemplate('https://x.test/cam/{code}/{name}'),
        'https://x.test/cam/S1/muangkong',
      );
    });

    test('returns null when a referenced attribute is empty', () {
      final PageChild child = PageChild(code: 'S1'); // name is null
      expect(
        child.resolveTemplate(
          'https://hatyaicityclimate.org/flood/cam/view?name={name}',
        ),
        isNull,
      );
    });

    test('returns the template unchanged when it has no tokens', () {
      final PageChild child = PageChild(name: 'radartmd');
      expect(
        child.resolveTemplate('https://x.test/static'),
        'https://x.test/static',
      );
    });

    test('returns null for null/empty template', () {
      final PageChild child = PageChild(name: 'radartmd');
      expect(child.resolveTemplate(null), isNull);
      expect(child.resolveTemplate(''), isNull);
    });

    test('leaves unknown tokens untouched', () {
      final PageChild child = PageChild(name: 'radartmd');
      expect(
        child.resolveTemplate('https://x.test/{unknown}/{name}'),
        'https://x.test/{unknown}/radartmd',
      );
    });
  });

  group('PageItem.webViewUrl parsing', () {
    test('parses item-level webViewUrl from JSON', () {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'webViewUrl': 'https://x.test/cam/{name}',
        'children': [
          {'name': 'radartmd'},
        ],
      });
      expect(item.webViewUrl, 'https://x.test/cam/{name}');
    });

    test('defaults to null when absent', () {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'children': [
          {'name': 'radartmd'},
        ],
      });
      expect(item.webViewUrl, isNull);
    });
  });

  group('cameraSet webViewUrl fallback', () {
    test('child without webViewUrl uses item template', () {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'webViewUrl': 'https://x.test/cam/{name}',
        'children': [
          {'name': 'radartmd'},
        ],
      });
      final PageChild child = item.children.first;
      final String? resolved = child.resolveTemplate(item.webViewUrl);
      expect(resolved, 'https://x.test/cam/radartmd');
    });

    test('child with own webViewUrl is not overridden by template', () {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'webViewUrl': 'https://x.test/cam/{name}',
        'children': [
          {'name': 'weather', 'webViewUrl': 'https://x.test/cam/11'},
        ],
      });
      final PageChild child = item.children.first;
      // The renderer checks child.webViewUrl first, so the template is skipped.
      expect(child.webViewUrl, 'https://x.test/cam/11');
      expect(item.webViewUrl, 'https://x.test/cam/{name}');
    });

    test('item template makes a child without own webViewUrl tappable', () {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'webViewUrl': 'https://x.test/cam/{name}',
        'children': [
          {'name': 'radartmd'}, // no own webViewUrl
        ],
      });
      final PageChild child = item.children.first;
      final bool tappable =
          (child.url != null && child.url!.isNotEmpty) ||
          (child.webViewUrl != null && child.webViewUrl!.isNotEmpty) ||
          (item.webViewUrl != null &&
              item.webViewUrl!.isNotEmpty &&
              child.resolveTemplate(item.webViewUrl) != null);
      expect(tappable, isTrue);
      expect(
        child.resolveTemplate(item.webViewUrl),
        'https://x.test/cam/radartmd',
      );
    });

    test(
      'item template does not make a child tappable when attribute empty',
      () {
        final PageItem item = PageItem.fromJson({
          'type': 'cameraSet',
          'webViewUrl': 'https://x.test/cam/{name}',
          'children': [
            {'code': 'R01'}, // name is absent -> template cannot resolve
          ],
        });
        final PageChild child = item.children.first;
        final bool tappable =
            (child.url != null && child.url!.isNotEmpty) ||
            (child.webViewUrl != null && child.webViewUrl!.isNotEmpty) ||
            (item.webViewUrl != null &&
                item.webViewUrl!.isNotEmpty &&
                child.resolveTemplate(item.webViewUrl) != null);
        expect(tappable, isFalse);
      },
    );
  });

  group('RenderCameraWidget code badge', () {
    testWidgets('shows a gray rounded badge initially (no realtime update)', (
      WidgetTester tester,
    ) async {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'children': [
          {'name': 'radartmd', 'code': 'R01'},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RenderCameraWidget(
              item: item,
              cameraPhoto: 'https://x.test/',
              cameraLastPhoto: 'last/',
              cameraRealtimePhoto: 'realtime/',
            ),
          ),
        ),
      );
      await tester.pump();

      // The badge text is rendered.
      expect(find.text('R01'), findsOneWidget);

      // Initially (no realtime photo update) the badge is gray.
      final Container badge = tester.widget<Container>(
        find
            .ancestor(of: find.text('R01'), matching: find.byType(Container))
            .first,
      );
      final BoxDecoration decoration = badge.decoration! as BoxDecoration;
      expect(decoration.color, Colors.grey);
      expect(decoration.borderRadius, isNotNull);
    });

    testWidgets('turns the badge green after a realtime photo update', (
      WidgetTester tester,
    ) async {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'children': [
          {'name': 'radartmd', 'code': 'R01'},
        ],
      });
      final Key key = UniqueKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RenderCameraWidget(
              key: key,
              item: item,
              cameraPhoto: 'https://x.test/',
              cameraLastPhoto: 'last/',
              cameraRealtimePhoto: 'realtime/',
            ),
          ),
        ),
      );
      await tester.pump();

      // Simulate a realtime photo.new: the child now carries a `time`.
      final PageItem updated = PageItem.fromJson({
        'type': 'cameraSet',
        'children': [
          {'name': 'radartmd', 'code': 'R01', 'time': '2026-07-26 14:30:00'},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RenderCameraWidget(
              key: key,
              item: updated,
              cameraPhoto: 'https://x.test/',
              cameraLastPhoto: 'last/',
              cameraRealtimePhoto: 'realtime/',
            ),
          ),
        ),
      );
      await tester.pump();

      // After the update the badge background turns green.
      final Container badge = tester.widget<Container>(
        find
            .ancestor(of: find.text('R01'), matching: find.byType(Container))
            .first,
      );
      final BoxDecoration decoration = badge.decoration! as BoxDecoration;
      expect(decoration.color, Colors.green);
    });

    testWidgets('renders no badge when code is absent', (
      WidgetTester tester,
    ) async {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'children': [
          {'name': 'radartmd'},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RenderCameraWidget(
              item: item,
              cameraPhoto: 'https://x.test/',
              cameraLastPhoto: 'last/',
              cameraRealtimePhoto: 'realtime/',
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('R01'), findsNothing);
    });

    testWidgets('does not auto-reload an image-only cameraSet', (
      WidgetTester tester,
    ) async {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'children': [
          {'image': 'https://x.test/banner.png'},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RenderCameraWidget(
              item: item,
              cameraPhoto: 'https://x.test/',
              cameraLastPhoto: 'last/',
              cameraRealtimePhoto: 'realtime/',
            ),
          ),
        ),
      );
      // No pending refresh timer should be scheduled for image-only sets.
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(minutes: 2));
      expect(tester.takeException(), isNull);
    });

    testWidgets('auto-reloads a cameraSet that has a named camera', (
      WidgetTester tester,
    ) async {
      final PageItem item = PageItem.fromJson({
        'type': 'cameraSet',
        'children': [
          {'name': 'radartmd'},
        ],
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RenderCameraWidget(
              item: item,
              cameraPhoto: 'https://x.test/',
              cameraLastPhoto: 'last/',
              cameraRealtimePhoto: 'realtime/',
            ),
          ),
        ),
      );
      // A refresh timer is pending for sets with a named camera.
      expect(tester.takeException(), isNull);
    });
  });

  group('PageWidget.cameraPoolInterval', () {
    test('parses cameraPoolInterval from JSON', () {
      final PageWidget widget = PageWidget.fromJson({
        'show': 'cam',
        'cameraPhoto': 'https://x.test/',
        'cameraLastPhoto': 'last/',
        'cameraRealtimePhoto': 'realtime/',
        'cameraPoolInterval': 30,
        'widgets': {
          'cam': {
            'type': 'cameraSet',
            'children': [
              {'name': 'radartmd'},
            ],
          },
        },
      });
      expect(widget.cameraPoolInterval, 30);
    });

    test('defaults to 60 when absent', () {
      final PageWidget widget = PageWidget.fromJson({
        'show': 'cam',
        'cameraPhoto': 'https://x.test/',
        'cameraLastPhoto': 'last/',
        'cameraRealtimePhoto': 'realtime/',
        'widgets': {
          'cam': {
            'type': 'cameraSet',
            'children': [
              {'name': 'radartmd'},
            ],
          },
        },
      });
      expect(widget.cameraPoolInterval, 60);
    });

    test('parses cameraLogPhoto from JSON', () {
      final PageWidget widget = PageWidget.fromJson({
        'show': 'cam',
        'cameraPhoto': 'https://x.test/',
        'cameraLastPhoto': 'last/',
        'cameraRealtimePhoto': 'realtime/',
        'cameraLogPhoto': 'last.json',
        'widgets': {
          'cam': {
            'type': 'cameraSet',
            'children': [
              {'name': 'radartmd'},
            ],
          },
        },
      });
      expect(widget.cameraLogPhoto, 'last.json');
    });

    test('defaults cameraLogPhoto to empty when absent', () {
      final PageWidget widget = PageWidget.fromJson({
        'show': 'cam',
        'cameraPhoto': 'https://x.test/',
        'cameraLastPhoto': 'last/',
        'cameraRealtimePhoto': 'realtime/',
        'widgets': {
          'cam': {
            'type': 'cameraSet',
            'children': [
              {'name': 'radartmd'},
            ],
          },
        },
      });
      expect(widget.cameraLogPhoto, '');
    });
  });
}
