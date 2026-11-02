import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';
import 'package:adaptive_platform_ui/src/widgets/ios26/ios26_native_toolbar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The native bar cannot be reached from a Flutter test (`Platform.isIOS` is
/// false on the test host), so these check the Dart side: what the toolbar
/// asks of its platform view.
void main() {
  /// Records the method calls every native toolbar receives.
  List<String> recordToolbarCalls(WidgetTester tester) {
    final calls = <String>[];
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
      call,
    ) async {
      if (call.method == 'create') {
        final id = (call.arguments as Map)['id'] as int;
        final channel = MethodChannel('adaptive_platform_ui/ios26_toolbar_$id');
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return null;
        });
        addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      }
      return null;
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        SystemChannels.platform_views,
        null,
      ),
    );
    return calls;
  }

  Widget toolbar() => Align(
    alignment: Alignment.topCenter,
    child: IOS26NativeToolbar(
      actions: [AdaptiveAppBarAction(iosSymbol: 'xmark', onPressed: () {})],
    ),
  );

  testWidgets(
    'asks the native bar to lay its items out again once its page has arrived',
    (tester) async {
      final calls = recordToolbarCalls(tester);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const SizedBox.shrink()),
      );

      navigator.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => toolbar()),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(calls, isNot(contains('relayout')), reason: 'still arriving');

      await tester.pumpAndSettle();
      expect(calls.where((call) => call == 'relayout'), hasLength(1));

      navigator.currentState!.pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(
        calls.where((call) => call == 'relayout'),
        hasLength(1),
        reason: 'leaving is no arrival',
      );
      await tester.pumpAndSettle();
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );

  testWidgets(
    'asks nothing of a bar whose page never moved',
    (tester) async {
      final calls = recordToolbarCalls(tester);
      await tester.pumpWidget(MaterialApp(home: toolbar()));
      await tester.pumpAndSettle();

      expect(calls, isNot(contains('relayout')));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
