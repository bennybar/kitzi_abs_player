import 'dart:math';
import 'package:flutter/material.dart';

/// Animated horizontal waveform bars that respond to playback state
class AudioWaveform extends StatefulWidget {
  const AudioWaveform({
    super.key,
    required this.isPlaying,
    this.barCount = 5,
    this.height = 24,
    this.spacing = 3,
    this.color,
    this.animationSpeed = const Duration(milliseconds: 300),
  });

  final bool isPlaying;
  final int barCount;
  final double height;
  final double spacing;
  final Color? color;
  final Duration animationSpeed;

  @override
  State<AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<AudioWaveform>
    with TickerProviderStateMixin {
  final List<Animation<double>> _barAnimations = [];
  final Random _random = Random();
  final List<AnimationController> _barControllers = [];

  @override
  void initState() {
    super.initState();
    
    // Create individual animation controllers for each bar
    for (int i = 0; i < widget.barCount; i++) {
      final controller = AnimationController(
        vsync: this,
        duration: Duration(milliseconds: 300 + _random.nextInt(200)),
      );
      _barControllers.add(controller);
      
      // Create varied wave patterns - center bars tend to be taller
      final centerWeight = 1.0 - (i - widget.barCount / 2).abs() / widget.barCount;
      final minHeight = 0.2 + (centerWeight * 0.1);
      final maxHeight = 0.6 + (centerWeight * 0.4);
      
      final animation = Tween<double>(
        begin: minHeight,
        end: maxHeight,
      ).animate(CurvedAnimation(
        parent: controller,
        curve: Curves.easeInOut,
      ));
      
      _barAnimations.add(animation);
      
      if (widget.isPlaying) {
        // Start each bar with a slight delay for staggered effect
        Future.delayed(Duration(milliseconds: i * 50), () {
          if (mounted && widget.isPlaying) {
            controller.repeat(reverse: true);
          }
        });
      }
    }
  }

  @override
  void didUpdateWidget(AudioWaveform oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isPlaying != oldWidget.isPlaying) {
      if (widget.isPlaying) {
        for (var controller in _barControllers) {
          controller.repeat(reverse: true);
        }
      } else {
        for (var controller in _barControllers) {
          controller.stop();
          controller.value = 0.2;
        }
      }
    }
  }

  @override
  void dispose() {
    for (var controller in _barControllers) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? Theme.of(context).colorScheme.primary;

    return SizedBox(
      height: widget.height,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: List.generate(widget.barCount, (index) {
          return Padding(
            padding: EdgeInsets.symmetric(horizontal: widget.spacing / 2),
            child: AnimatedBuilder(
              animation: _barAnimations[index],
              builder: (context, child) {
                final barHeight = widget.isPlaying 
                    ? _barAnimations[index].value * widget.height 
                    : widget.height * 0.2;
                
                return Container(
                  width: 3,
                  height: barHeight,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(2),
                  ),
                );
              },
            ),
          );
        }),
      ),
    );
  }
}

/// Compact version for mini player - 3 bars, smaller size
class MiniAudioWaveform extends StatelessWidget {
  const MiniAudioWaveform({
    super.key,
    required this.isPlaying,
    this.color,
  });

  final bool isPlaying;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return AudioWaveform(
      isPlaying: isPlaying,
      barCount: 3,
      height: 16,
      spacing: 2.5,
      color: color,
      animationSpeed: const Duration(milliseconds: 250),
    );
  }
}

