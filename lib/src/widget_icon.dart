import 'package:flutter/widgets.dart';

/// Outlines from the website live chat's 24-unit SVG view boxes.
enum ChatGlyph {
  launcher,
  home,
  message,
  help,
  attachment,
  back,
  close,
  more,
  expandArticle,
  restoreArticle,
  openArticle,
  search;

  Path get path {
    switch (this) {
      case launcher:
        return Path()
          ..moveTo(20, 11.5)
          ..arcToPoint(const Offset(12, 19), radius: const Radius.circular(7.5))
          ..arcToPoint(
            const Offset(8.5, 18.3),
            radius: const Radius.circular(8.8),
          )
          ..lineTo(4, 20)
          ..lineTo(5.4, 16.2)
          ..arcToPoint(
            const Offset(4, 11.5),
            radius: const Radius.circular(7.2),
          )
          ..arcToPoint(const Offset(12, 4), radius: const Radius.circular(7.5))
          ..arcToPoint(
            const Offset(20, 11.5),
            radius: const Radius.circular(7.5),
          )
          ..close();
      case home:
        return Path()
          ..moveTo(4, 10.5)
          ..lineTo(12, 4)
          ..lineTo(20, 10.5)
          ..lineTo(20, 18.5)
          ..arcToPoint(
            const Offset(18.5, 20),
            radius: const Radius.circular(1.5),
          )
          ..lineTo(5.5, 20)
          ..arcToPoint(
            const Offset(4, 18.5),
            radius: const Radius.circular(1.5),
          )
          ..close()
          ..moveTo(9, 20)
          ..lineTo(9, 14)
          ..lineTo(15, 14)
          ..lineTo(15, 20);
      case message:
        return Path()
          ..moveTo(5, 5.5)
          ..lineTo(19, 5.5)
          ..arcToPoint(const Offset(21, 7.5), radius: const Radius.circular(2))
          ..lineTo(21, 14.5)
          ..arcToPoint(const Offset(19, 16.5), radius: const Radius.circular(2))
          ..lineTo(12, 16.5)
          ..lineTo(7.5, 19.5)
          ..lineTo(7.5, 16.5)
          ..lineTo(5, 16.5)
          ..arcToPoint(const Offset(3, 14.5), radius: const Radius.circular(2))
          ..lineTo(3, 7.5)
          ..arcToPoint(const Offset(5, 5.5), radius: const Radius.circular(2))
          ..close();
      case help:
        return Path()
          ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 9))
          ..moveTo(9.8, 9)
          ..relativeArcToPoint(
            const Offset(3.4, 2.2),
            radius: const Radius.circular(2.4),
            largeArc: true,
          )
          ..relativeCubicTo(-.8, .4, -1.2, .9, -1.2, 1.8)
          ..moveTo(12, 17)
          ..relativeLineTo(.01, 0);
      case attachment:
        return Path()
          ..moveTo(20.5, 11.5)
          ..relativeLineTo(-8.9, 8.9)
          ..relativeArcToPoint(
            const Offset(-8.5, -8.5),
            radius: const Radius.circular(6),
          )
          ..relativeLineTo(9.6, -9.6)
          ..relativeArcToPoint(
            const Offset(5.7, 5.7),
            radius: const Radius.circular(4),
          )
          ..relativeLineTo(-9.6, 9.6)
          ..relativeArcToPoint(
            const Offset(-2.8, -2.8),
            radius: const Radius.circular(2),
          )
          ..relativeLineTo(8.9, -8.9);
      case back:
        return Path()
          ..moveTo(15, 18)
          ..lineTo(9, 12)
          ..lineTo(15, 6);
      case close:
        return Path()
          ..moveTo(6, 6)
          ..lineTo(18, 18)
          ..moveTo(18, 6)
          ..lineTo(6, 18);
      case more:
        return Path()
          ..addOval(Rect.fromCircle(center: const Offset(5, 12), radius: 1.7))
          ..addOval(Rect.fromCircle(center: const Offset(12, 12), radius: 1.7))
          ..addOval(Rect.fromCircle(center: const Offset(19, 12), radius: 1.7));
      case expandArticle:
        return Path()
          ..moveTo(15, 3)
          ..lineTo(21, 3)
          ..lineTo(21, 9)
          ..moveTo(21, 3)
          ..lineTo(14, 10)
          ..moveTo(3, 21)
          ..lineTo(10, 14)
          ..moveTo(9, 21)
          ..lineTo(3, 21)
          ..lineTo(3, 15);
      case restoreArticle:
        return Path()
          ..moveTo(14, 10)
          ..lineTo(21, 3)
          ..moveTo(20, 10)
          ..lineTo(14, 10)
          ..lineTo(14, 4)
          ..moveTo(3, 21)
          ..lineTo(10, 14)
          ..moveTo(4, 14)
          ..lineTo(10, 14)
          ..lineTo(10, 20);
      case openArticle:
        return Path()
          ..moveTo(14, 5)
          ..lineTo(19, 5)
          ..lineTo(19, 10)
          ..moveTo(19, 5)
          ..lineTo(11, 13)
          ..moveTo(18, 13)
          ..lineTo(18, 18)
          ..arcToPoint(const Offset(17, 19), radius: const Radius.circular(1))
          ..lineTo(6, 19)
          ..arcToPoint(const Offset(5, 18), radius: const Radius.circular(1))
          ..lineTo(5, 7)
          ..arcToPoint(const Offset(6, 6), radius: const Radius.circular(1))
          ..lineTo(11, 6);
      case search:
        return Path()
          ..addOval(Rect.fromCircle(center: const Offset(11, 11), radius: 6.5))
          ..moveTo(16, 16)
          ..lineTo(20, 20);
    }
  }
}

class ChatWidgetIcon extends StatelessWidget {
  const ChatWidgetIcon(this.glyph, {super.key, required this.size, this.color});

  final ChatGlyph glyph;
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final theme = IconTheme.of(context);
    final ink = color ?? theme.color ?? const Color(0xff000000);
    return ExcludeSemantics(
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: CustomPaint(
          size: Size.square(size),
          painter: _GlyphPainter(
            glyph,
            ink.withValues(alpha: ink.a * (theme.opacity ?? 1)),
          ),
        ),
      ),
    );
  }
}

class _GlyphPainter extends CustomPainter {
  const _GlyphPainter(this.glyph, this.color);
  final ChatGlyph glyph;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    canvas.drawPath(
      glyph.path,
      Paint()
        ..color = color
        ..style = glyph == ChatGlyph.more
            ? PaintingStyle.fill
            : PaintingStyle.stroke
        ..strokeWidth =
            const {
              ChatGlyph.home,
              ChatGlyph.message,
              ChatGlyph.help,
              ChatGlyph.attachment,
            }.contains(glyph)
            ? 1.8
            : 2
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_GlyphPainter old) =>
      old.glyph != glyph || old.color != color;
}
