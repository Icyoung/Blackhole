import 'package:flutter/material.dart';

class FadeOverflowText extends StatelessWidget {
  const FadeOverflowText({
    super.key,
    required this.text,
    this.style,
    this.fadeWidth = 20,
  });

  final String text;
  final TextStyle? style;
  final double fadeWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final textPainter = TextPainter(
          text: TextSpan(text: text, style: style),
          maxLines: 1,
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: double.infinity);

        final isOverflow = textPainter.width > constraints.maxWidth;

        final textWidget = Text(
          text,
          maxLines: 1,
          overflow: TextOverflow.clip,
          style: style,
        );

        if (!isOverflow) return textWidget;

        return ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            colors: const [Colors.white, Colors.transparent],
            stops: [1 - (fadeWidth / bounds.width).clamp(0.0, 1.0), 1.0],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: textWidget,
        );
      },
    );
  }
}
