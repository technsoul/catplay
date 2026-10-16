import 'package:flutter/widgets.dart';

/// Screen-size breakpoints. The desktop/TV layout (navigation rail, side
/// columns, preview panes) needs roughly 1000×520 logical px; anything
/// smaller — phones in either orientation, small tablets — gets the compact
/// single-column layout with bottom navigation.
class Breakpoints {
  /// Below this width the side-by-side panes no longer fit.
  static const compactWidth = 1000.0;

  /// Below this height (phones in landscape) the page header, toolbars and
  /// lists don't fit stacked, so the compact layout is used too.
  static const compactHeight = 520.0;

  /// Poster grids on phones: about three columns in portrait.
  static const posterExtent = 128.0;

  /// Side padding for compact pages.
  static const gutter = 16.0;
}

extension LayoutContext on BuildContext {
  /// True when the compact (phone) layout should be used.
  bool get isCompact {
    final s = MediaQuery.sizeOf(this);
    return s.width < Breakpoints.compactWidth || s.height < Breakpoints.compactHeight;
  }

  /// Compact and wider than tall: a phone held sideways.
  bool get isCompactLandscape {
    final s = MediaQuery.sizeOf(this);
    return isCompact && s.width > s.height;
  }
}
