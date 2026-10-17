import 'package:flutter/material.dart';

import '../theme.dart';

/// The top row of a page over the drive screen: back, the title, what the last command did (in
/// green, until the next one) and an optional button such as refresh.
class PageHeader extends StatelessWidget {
  const PageHeader({super.key, required this.title, this.done, this.action});

  final String title;
  final String? done;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final done = this.done;
    final action = this.action;
    return Row(
      children: [
        IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        Flexible(child: Text(title, style: Txt.title, overflow: TextOverflow.ellipsis)),
        const SizedBox(width: 12),
        Expanded(
          child: done == null
              ? const SizedBox.shrink()
              : Row(
                  key: const ValueKey('page-done'),
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    const Icon(Icons.check_circle_rounded, size: 16, color: Palette.ok),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        done,
                        style: Txt.small.copyWith(color: Palette.ok),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
        ),
        if (action != null) action else const SizedBox(width: 8),
      ],
    );
  }
}

/// A section title in a page: small capitals in the AUTO colour.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.title, {super.key, this.top = 10});

  final String title;
  final double top;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: top, bottom: 6),
      child: Text(
        title.toUpperCase(),
        style: Txt.small.copyWith(
          color: Palette.auto,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// A column of a page, scrolled as a whole: every control in it is built, also below the fold.
class PageColumn extends StatelessWidget {
  const PageColumn({super.key, required this.children, this.padding = EdgeInsets.zero});

  final List<Widget> children;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: padding,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children),
    );
  }
}
