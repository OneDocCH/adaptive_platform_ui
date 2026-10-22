import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:adaptive_platform_ui/adaptive_platform_ui.dart';

// The UITabBarController itself is native and iOS 26+ only: on the test host
// `Platform.isIOS` is false, so these tests cover the flag on the Dart side —
// its default, that it is kept and replaced, and that a bar asking for it
// still renders off iOS.

const _destinations = [
  AdaptiveNavigationDestination(icon: Icons.home, label: 'Home'),
  AdaptiveNavigationDestination(icon: Icons.person, label: 'Profile'),
  AdaptiveNavigationDestination(
    icon: Icons.search,
    label: 'Search',
    isSearch: true,
  ),
];

AdaptiveBottomNavigationBar _bar({bool useTabBarController = false}) {
  return AdaptiveBottomNavigationBar(
    useTabBarController: useTabBarController,
    selectedIndex: 0,
    onTap: (_) {},
    items: _destinations,
  );
}

void main() {
  group('AdaptiveBottomNavigationBar useTabBarController', () {
    test('defaults to false, keeping the standalone UITabBar', () {
      expect(const AdaptiveBottomNavigationBar().useTabBarController, isFalse);
    });

    test('keeps the value it is given', () {
      expect(_bar(useTabBarController: true).useTabBarController, isTrue);
    });

    test('copyWith keeps it when it is not given', () {
      final copy = _bar(useTabBarController: true).copyWith(selectedIndex: 1);

      expect(copy.useTabBarController, isTrue);
      expect(copy.selectedIndex, 1);
    });

    test('copyWith replaces it when it is given', () {
      final copy = _bar(
        useTabBarController: true,
      ).copyWith(useTabBarController: false);

      expect(copy.useTabBarController, isFalse);
    });
  });

  group('IOS26NativeTabBar useTabBarController', () {
    test('defaults to false', () {
      final bar = IOS26NativeTabBar(
        destinations: _destinations,
        selectedIndex: 0,
        onTap: (_) {},
      );

      expect(bar.useTabBarController, isFalse);
    });
  });

  group('AdaptiveScaffold with useTabBarController', () {
    for (final useTabBarController in [false, true]) {
      testWidgets(
        'renders every destination off iOS (useTabBarController: $useTabBarController)',
        (WidgetTester tester) async {
          await tester.pumpWidget(
            MaterialApp(
              home: AdaptiveScaffold(
                body: const SizedBox.shrink(),
                bottomNavigationBar: _bar(
                  useTabBarController: useTabBarController,
                ),
              ),
            ),
          );

          expect(find.text('Home'), findsWidgets);
          expect(find.text('Profile'), findsOneWidget);
          expect(find.text('Search'), findsOneWidget);
        },
      );
    }

    testWidgets('switching the flag at runtime rebuilds without errors', (
      WidgetTester tester,
    ) async {
      var useTabBarController = false;
      late StateSetter setState;

      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder: (context, set) {
              setState = set;
              return AdaptiveScaffold(
                body: const SizedBox.shrink(),
                bottomNavigationBar: _bar(
                  useTabBarController: useTabBarController,
                ),
              );
            },
          ),
        ),
      );

      setState(() => useTabBarController = true);
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Profile'), findsOneWidget);
    });
  });
}
