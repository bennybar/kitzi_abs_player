import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/playback_repository.dart';
import '../../core/playback_speed_service.dart';
import '../../main.dart';
import '../../widgets/audible_stars.dart';

/// Winamp-style "retro skin" for the full player. Recreates the AudioAmp mockup
/// (gunmetal chassis, LCD-green display + spectrum visualiser, scrolling
/// marquee, striped seek, beveled transport, VOL/SPD sliders and a green-on-black
/// chapter playlist) wired to the real [PlaybackRepository].
class RetroPlayerView extends StatefulWidget {
  const RetroPlayerView({super.key, required this.np});
  final NowPlaying np;

  @override
  State<RetroPlayerView> createState() => _RetroPlayerViewState();
}

// ---- palette (from the design) ----
const _metalHi = Color(0xFF5B5F73);
const _metal = Color(0xFF3C3E4C);
const _metalLo = Color(0xFF272834);
const _metalDeep = Color(0xFF1B1C25);
const _bevelLight = Color(0xFF787C91);
const _bevelDark = Color(0xFF15161D);
const _lcdBg = Color(0xFF0A0F0A);
const _lcd = Color(0xFF27E23F);
const _lcdDim = Color(0xFF157A26);
const _amber = Color(0xFFFFB22E);
const _titleA = Color(0xFF2B3A8C);
const _titleB = Color(0xFF0D1338);
const _mono = 'monospace';

class _RetroPlayerViewState extends State<RetroPlayerView>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ticker;
  final List<double> _bars = List.filled(15, 2);
  final List<double> _peaks = List.filled(15, 0);
  final _rand = math.Random();
  final ScrollController _plController = ScrollController();
  int _lastScrolledChapter = -1;

  PlaybackRepository get _pb => ServicesScope.of(context).services.playback;

  @override
  void initState() {
    super.initState();
    _ticker = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 60),
    )..repeat();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _plController.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final np = widget.np;
    return Container(
      decoration: const BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -1.1),
          radius: 1.1,
          colors: [Color(0xFF2A2740), Color(0xFF15131F), Color(0xFF0A0910)],
          stops: [0, .45, 1],
        ),
      ),
      child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _window(
                    title: 'AudioAmp 2.95',
                    child: _player(np),
                  ),
                  const SizedBox(height: 7),
                  _window(
                    title: 'Chapter List',
                    child: _playlist(np),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    ':: AUDIOAMP — IT REALLY WHIPS THE LLAMA’S ASS ::',
                    style: TextStyle(
                      fontFamily: _mono,
                      fontSize: 11,
                      letterSpacing: 1.5,
                      color: Color(0xFF4A4D63),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ===== generic chassis window =====
  Widget _window({required String title, required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_metalHi, _metal, _metalLo],
          stops: [0, .08, 1],
        ),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(color: _bevelDark),
        boxShadow: const [
          BoxShadow(color: Colors.black54, offset: Offset(0, 2)),
        ],
      ),
      padding: const EdgeInsets.all(5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _titleBar(title),
          const SizedBox(height: 5),
          child,
        ],
      ),
    );
  }

  Widget _titleBar(String title) {
    Widget tbBtn(String g) => Container(
          width: 12,
          height: 12,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF60657A), Color(0xFF2C2E3A)],
            ),
            border: Border.all(color: _bevelDark),
            borderRadius: BorderRadius.circular(1),
          ),
          child: Text(g,
              style: const TextStyle(
                  fontFamily: _mono, fontSize: 8, color: Color(0xFFCDD2E6))),
        );
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xFF3A4AA0), _titleA, _titleB],
          stops: [0, .3, 1],
        ),
        borderRadius: BorderRadius.circular(2),
        border: Border.all(color: _bevelDark),
      ),
      child: Row(
        children: [
          tbBtn('_'),
          const SizedBox(width: 7),
          Expanded(
            child: Text(
              title.toUpperCase(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'Oswald',
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 2.5,
                color: Color(0xFFCFD6FF),
              ),
            ),
          ),
          tbBtn('□'),
          const SizedBox(width: 3),
          tbBtn('×'),
        ],
      ),
    );
  }

  // ===== player window body =====
  Widget _player(NowPlaying np) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _cover(np),
        const SizedBox(height: 6),
        _lcdStrip(np),
        const SizedBox(height: 6),
        _marquee(np),
        const SizedBox(height: 8),
        _seek(),
        const SizedBox(height: 8),
        _transport(),
        const SizedBox(height: 8),
        _knobs(),
      ],
    );
  }

  Widget _cover(NowPlaying np) {
    final url = np.coverUrl;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: _metalDeep,
        borderRadius: BorderRadius.circular(2),
        boxShadow: const [
          BoxShadow(color: Colors.black, blurRadius: 0, offset: Offset(1, 1)),
        ],
      ),
      child: Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: SizedBox(
              height: 172,
              width: double.infinity,
              child: (url != null && url.isNotEmpty)
                  ? Image.network(url, fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _coverFallback())
                  : _coverFallback(),
            ),
          ),
          Positioned(
            top: 8,
            left: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xD9080A08),
                border: Border.all(color: _lcdDim),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                _BlinkDot(ticker: _ticker),
                const SizedBox(width: 5),
                const Text('NOW PLAYING',
                    style: TextStyle(
                        fontFamily: _mono,
                        fontSize: 13,
                        letterSpacing: 1,
                        color: _lcd)),
              ]),
            ),
          ),
          Positioned(
            bottom: 8,
            right: 8,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xD9080A08),
                border: Border.all(color: const Color(0xFF6B5A1E)),
                borderRadius: BorderRadius.circular(2),
              ),
              child: AudibleStars(
                itemId: np.libraryItemId,
                title: np.title,
                author: np.author,
                narrator: np.narrator,
                durationMs: np.durationSec != null
                    ? (np.durationSec! * 1000).round()
                    : null,
                starSize: 13,
                color: _amber,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _coverFallback() => Container(
        color: _metalDeep,
        alignment: Alignment.center,
        child: const Text('NO COVER',
            style: TextStyle(fontFamily: _mono, color: _lcdDim, fontSize: 14)),
      );

  // ===== LCD strip: visualiser + time =====
  Widget _lcdStrip(NowPlaying np) {
    return Container(
      padding: const EdgeInsets.fromLTRB(9, 7, 9, 8),
      decoration: BoxDecoration(
        gradient: const RadialGradient(
          center: Alignment(0, -1),
          radius: 1.4,
          colors: [Color(0xFF0D160D), _lcdBg],
        ),
        border: Border.all(color: Colors.black),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          StreamBuilder<bool>(
            stream: _pb.playingStream,
            initialData: _pb.player.playing,
            builder: (_, snap) {
              final playing = snap.data ?? false;
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    width: 78,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF020602), Color(0xFF0A120A)],
                      ),
                      border: Border.all(color: Colors.black),
                    ),
                    child: AnimatedBuilder(
                      animation: _ticker,
                      builder: (_, __) {
                        _stepBars(playing);
                        return CustomPaint(
                          painter: _VizPainter(_bars, _peaks),
                        );
                      },
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: ValueListenableBuilder<Duration>(
                      valueListenable: _pb.currentPosition,
                      builder: (_, curPos, __) {
                        final pos = _pb.globalBookPosition ?? curPos;
                        final total = _pb.totalBookDuration ??
                            (np.durationSec != null
                                ? Duration(seconds: np.durationSec!.round())
                                : Duration.zero);
                        final remain = total > pos ? total - pos : Duration.zero;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(_fmt(pos),
                                style: const TextStyle(
                                    fontFamily: _mono,
                                    fontSize: 40,
                                    height: .9,
                                    color: _lcd)),
                            Text('- ${_fmt(remain)}',
                                style: const TextStyle(
                                    fontFamily: _mono,
                                    fontSize: 16,
                                    color: _lcdDim)),
                          ],
                        );
                      },
                    ),
                  ),
                ],
              );
            },
          ),
          const SizedBox(height: 7),
          Container(
            padding: const EdgeInsets.only(top: 6),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0x2427E23F))),
            ),
            child: const Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('128 kbps   44 khz',
                    style: TextStyle(
                        fontFamily: _mono, fontSize: 15, color: _lcd)),
                Text('▶ AUDIO BOOK',
                    style: TextStyle(
                        fontFamily: _mono, fontSize: 15, color: _lcdDim)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _stepBars(bool playing) {
    for (var i = 0; i < _bars.length; i++) {
      final target = playing
          ? (8 + _rand.nextDouble() * _rand.nextDouble() * 32)
          : 2.0;
      _bars[i] += (target - _bars[i]) * (playing ? 0.4 : 0.12);
      _peaks[i] = _bars[i] > _peaks[i]
          ? _bars[i]
          : math.max(1, _peaks[i] - 1.1);
    }
  }

  Widget _marquee(NowPlaying np) {
    final narr = (np.narrator != null && np.narrator!.isNotEmpty)
        ? '  ★  NARRATED BY ${np.narrator!.toUpperCase()}'
        : '';
    final txt =
        '${np.title.toUpperCase()}  ★  ${(np.author ?? '').toUpperCase()}$narr';
    return Container(
      height: 26,
      decoration: BoxDecoration(
        color: _lcdBg,
        border: Border.all(color: Colors.black),
        borderRadius: BorderRadius.circular(2),
      ),
      clipBehavior: Clip.hardEdge,
      child: _Marquee(text: txt),
    );
  }

  // ===== seek =====
  Widget _seek() {
    return ValueListenableBuilder<Duration>(
      valueListenable: _pb.currentPosition,
      builder: (_, curPos, __) {
        final pos = _pb.globalBookPosition ?? curPos;
        final total = _pb.totalBookDuration ?? Duration.zero;
        final frac = total.inMilliseconds > 0
            ? (pos.inMilliseconds / total.inMilliseconds).clamp(0.0, 1.0)
            : 0.0;
        return LayoutBuilder(builder: (context, c) {
          void seekTo(double dx) {
            if (total.inMilliseconds <= 0) return;
            final p = (dx / c.maxWidth).clamp(0.0, 1.0);
            _pb.seekGlobal(
                Duration(milliseconds: (total.inMilliseconds * p).round()),
                reportNow: true);
          }

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) => seekTo(d.localPosition.dx),
            onHorizontalDragUpdate: (d) => seekTo(d.localPosition.dx),
            child: SizedBox(
              height: 18,
              child: Center(
                child: Container(
                  height: 14,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Color(0xFF16171F), Color(0xFF26283A)],
                    ),
                    border: Border.all(color: _bevelDark),
                    borderRadius: BorderRadius.circular(2),
                  ),
                  child: Stack(children: [
                    FractionallySizedBox(
                      widthFactor: frac == 0 ? 0.001 : frac,
                      child: Container(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            colors: [_lcd, Color(0xFF159A2A)],
                          ),
                        ),
                      ),
                    ),
                    Align(
                      alignment: Alignment(frac * 2 - 1, 0),
                      child: Container(
                        width: 11,
                        height: 20,
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0xFF7B8096), Color(0xFF34364A)],
                          ),
                          border: Border.all(color: _bevelDark),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                  ]),
                ),
              ),
            ),
          );
        });
      },
    );
  }

  // ===== transport =====
  Widget _transport() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _tBtn(
          icon: Icons.skip_previous,
          onTap: () { if (_pb.hasSmartPrev) _pb.smartPrev(); },
        ),
        const SizedBox(width: 6),
        _tBtn(icon: Icons.replay, label: '30', onTap: () => _pb.nudgeSeconds(-30)),
        const SizedBox(width: 6),
        StreamBuilder<bool>(
          stream: _pb.playingStream,
          initialData: _pb.player.playing,
          builder: (_, snap) {
            final playing = snap.data ?? false;
            return _playBtn(playing);
          },
        ),
        const SizedBox(width: 6),
        _tBtn(icon: Icons.forward_30, label: '30', onTap: () => _pb.nudgeSeconds(30)),
        const SizedBox(width: 6),
        _tBtn(
          icon: Icons.skip_next,
          onTap: () { if (_pb.hasSmartNext) _pb.smartNext(); },
        ),
      ],
    );
  }

  Widget _tBtn({required IconData icon, String? label, required VoidCallback onTap}) {
    return _Beveled(
      width: 50,
      height: 38,
      onTap: onTap,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 18, color: const Color(0xFFDFE2F2)),
          if (label != null)
            Text(label,
                style: const TextStyle(
                    fontFamily: _mono, fontSize: 12, color: _lcd, height: 1)),
        ],
      ),
    );
  }

  Widget _playBtn(bool playing) {
    return _Beveled(
      width: 66,
      height: 46,
      play: true,
      onTap: () async {
        if (playing) {
          await _pb.pause();
        } else {
          await _pb.resume(context: context);
        }
      },
      child: Icon(playing ? Icons.pause : Icons.play_arrow,
          size: 26, color: const Color(0xFFEAF0FF)),
    );
  }

  // ===== VOL / SPD knobs =====
  Widget _knobs() {
    return Row(children: [
      Expanded(
        child: _knob(
          label: 'VOL',
          value: _pb.player.volume.clamp(0.0, 1.0),
          valueLabel: '${(_pb.player.volume.clamp(0.0, 1.0) * 100).round()}',
          onSet: (p) async {
            await _pb.player.setVolume(p);
            setState(() {});
          },
        ),
      ),
      const SizedBox(width: 6),
      Expanded(
        child: ValueListenableBuilder<double>(
          valueListenable: PlaybackSpeedService.instance.speed,
          builder: (_, spd, __) {
            final frac = ((spd - 0.5) / (3.0 - 0.5)).clamp(0.0, 1.0);
            return _knob(
              label: 'SPD',
              value: frac,
              valueLabel: '${spd.toStringAsFixed(spd % 1 == 0 ? 1 : 2)}x',
              onSet: (p) async {
                final raw = 0.5 + p * (3.0 - 0.5);
                // snap to 0.05 steps
                final snapped = (raw * 20).round() / 20;
                await PlaybackSpeedService.instance
                    .setSpeed(snapped.clamp(0.5, 3.0));
              },
            );
          },
        ),
      ),
    ]);
  }

  Widget _knob({
    required String label,
    required double value,
    required String valueLabel,
    required ValueChanged<double> onSet,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      decoration: BoxDecoration(
        color: _metalDeep,
        border: Border.all(color: _bevelDark),
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(children: [
        SizedBox(
          width: 34,
          child: Text(label,
              style: const TextStyle(
                  fontFamily: _mono, fontSize: 14, color: _lcdDim)),
        ),
        Expanded(
          child: LayoutBuilder(builder: (context, c) {
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapDown: (d) => onSet((d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0)),
              onHorizontalDragUpdate: (d) =>
                  onSet((d.localPosition.dx / c.maxWidth).clamp(0.0, 1.0)),
              child: SizedBox(
                height: 16,
                child: Center(
                  child: Container(
                    height: 9,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0xFF0C0D12), Color(0xFF1C1E2A)],
                      ),
                      borderRadius: BorderRadius.circular(5),
                    ),
                    child: Stack(children: [
                      FractionallySizedBox(
                        widthFactor: value == 0 ? 0.001 : value,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                                colors: [Color(0xFF159A2A), _lcd]),
                            borderRadius: BorderRadius.circular(5),
                          ),
                        ),
                      ),
                      Align(
                        alignment: Alignment(value * 2 - 1, 0),
                        child: Container(
                          width: 9,
                          height: 15,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [Color(0xFF7B8096), Color(0xFF34364A)],
                            ),
                            border: Border.all(color: _bevelDark),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ),
              ),
            );
          }),
        ),
        SizedBox(
          width: 40,
          child: Text(valueLabel,
              textAlign: TextAlign.right,
              style: const TextStyle(
                  fontFamily: _mono, fontSize: 14, color: _lcd)),
        ),
      ]),
    );
  }

  // ===== chapter playlist =====
  Widget _playlist(NowPlaying np) {
    final chapters = np.chapters;
    final curIdx = _pb.currentChapterProgress?.index ?? _currentChapterFromPos(np);
    // auto-scroll current into view once it changes
    if (curIdx != _lastScrolledChapter && _plController.hasClients) {
      _lastScrolledChapter = curIdx;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_plController.hasClients) return;
        final target =
            (curIdx * 24.0) - 70; // approx row height, center-ish
        _plController.jumpTo(target.clamp(
            0.0, _plController.position.maxScrollExtent));
      });
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(2, 0, 2, 5),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('DAEMON.M3U — ${chapters.length} TRACKS',
                  style: const TextStyle(
                      fontFamily: _mono, fontSize: 14, color: _lcdDim)),
              Text('${curIdx + 1}/${chapters.length}',
                  style: const TextStyle(
                      fontFamily: _mono, fontSize: 14, color: _lcd)),
            ],
          ),
        ),
        Container(
          height: 200,
          decoration: BoxDecoration(
            color: _lcdBg,
            border: Border.all(color: Colors.black),
            borderRadius: BorderRadius.circular(2),
          ),
          child: chapters.isEmpty
              ? const Center(
                  child: Text('NO CHAPTERS',
                      style: TextStyle(
                          fontFamily: _mono, color: _lcdDim, fontSize: 15)))
              : ListView.builder(
                  controller: _plController,
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  itemCount: chapters.length,
                  itemExtent: 24,
                  itemBuilder: (context, i) {
                    final c = chapters[i];
                    final done = i < curIdx;
                    final cur = i == curIdx;
                    final tag = done
                        ? '✓'
                        : (cur ? '▶' : (i + 1).toString().padLeft(2, '0'));
                    return InkWell(
                      onTap: () => _pb.seekGlobal(c.start, reportNow: true),
                      child: Container(
                        color: cur ? const Color(0x2927E23F) : null,
                        padding: const EdgeInsets.symmetric(horizontal: 9),
                        child: Row(children: [
                          SizedBox(
                            width: 24,
                            child: Text(tag,
                                textAlign: TextAlign.right,
                                style: TextStyle(
                                    fontFamily: _mono,
                                    fontSize: 15,
                                    color: cur || done ? _lcd : const Color(0xFF0F5E1C))),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              c.title.isEmpty ? 'Chapter ${i + 1}' : c.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontFamily: _mono,
                                fontSize: 16,
                                color: cur
                                    ? const Color(0xFFAEFFB9)
                                    : (done ? const Color(0xFF0D4715) : _lcdDim),
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(_fmt(c.start),
                              style: const TextStyle(
                                  fontFamily: _mono,
                                  fontSize: 14,
                                  color: Color(0xFF0F5E1C))),
                        ]),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  int _currentChapterFromPos(NowPlaying np) {
    final pos = _pb.globalBookPosition ?? _pb.currentPosition.value;
    var idx = 0;
    for (var i = np.chapters.length - 1; i >= 0; i--) {
      if (pos >= np.chapters[i].start) {
        idx = i;
        break;
      }
    }
    return idx;
  }
}

// ===== small components =====

class _Beveled extends StatefulWidget {
  const _Beveled({
    required this.child,
    required this.onTap,
    required this.width,
    required this.height,
    this.play = false,
  });
  final Widget child;
  final VoidCallback onTap;
  final double width;
  final double height;
  final bool play;

  @override
  State<_Beveled> createState() => _BeveledState();
}

class _BeveledState extends State<_Beveled> {
  bool _down = false;
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _down = true),
      onTapCancel: () => setState(() => _down = false),
      onTapUp: (_) {
        setState(() => _down = false);
        widget.onTap();
      },
      child: AnimatedScale(
        scale: _down ? 0.96 : 1,
        duration: const Duration(milliseconds: 40),
        child: Container(
          width: widget.width,
          height: widget.height,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: widget.play
                  ? const [Color(0xFF3A4AA8), Color(0xFF1A2150)]
                  : const [_metalHi, Color(0xFF2C2E3B)],
            ),
            border: Border.all(
                color: widget.play ? const Color(0xFF6877D8) : _bevelLight),
            borderRadius: BorderRadius.circular(3),
            boxShadow: widget.play
                ? const [BoxShadow(color: Color(0x803A4AA8), blurRadius: 14)]
                : null,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}

class _BlinkDot extends StatelessWidget {
  const _BlinkDot({required this.ticker});
  final AnimationController ticker;
  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: ticker,
      builder: (_, __) {
        final on = (DateTime.now().millisecondsSinceEpoch ~/ 550) % 2 == 0;
        return Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? _lcd : const Color(0xFF0F3A16),
            boxShadow: on
                ? const [BoxShadow(color: Color(0x8C27E23F), blurRadius: 6)]
                : null,
          ),
        );
      },
    );
  }
}

class _Marquee extends StatefulWidget {
  const _Marquee({required this.text});
  final String text;
  @override
  State<_Marquee> createState() => _MarqueeState();
}

class _MarqueeState extends State<_Marquee>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c =
      AnimationController(vsync: this, duration: const Duration(seconds: 16))
        ..repeat();
  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final t = Text(widget.text,
        maxLines: 1,
        style: const TextStyle(
            fontFamily: _mono, fontSize: 20, letterSpacing: 1, color: _lcd));
    return ClipRect(
      child: LayoutBuilder(builder: (context, c) {
        return AnimatedBuilder(
          animation: _c,
          builder: (_, __) {
            // scroll from right edge to fully off the left
            final dx = c.maxWidth - _c.value * (c.maxWidth + 600);
            return Transform.translate(
              offset: Offset(dx, 0),
              child: Align(alignment: Alignment.centerLeft, child: t),
            );
          },
        );
      }),
    );
  }
}

class _VizPainter extends CustomPainter {
  _VizPainter(this.bars, this.peaks);
  final List<double> bars;
  final List<double> peaks;
  @override
  void paint(Canvas canvas, Size size) {
    const n = 15, gap = 1.0;
    final bw = (size.width - (n - 1) * gap) / n;
    final p = Paint();
    for (var i = 0; i < n; i++) {
      final h = math.max(1.0, bars[i]);
      final x = i * (bw + gap);
      for (var y = 0.0; y < h; y += 2) {
        final f = y / size.height;
        p.color = f > 0.8
            ? const Color(0xFFFF3B2E)
            : (f > 0.55 ? const Color(0xFFFFD02E) : _lcd);
        canvas.drawRect(Rect.fromLTWH(x, size.height - y - 2, bw, 1.4), p);
      }
      p.color = const Color(0xFFBFFFC8);
      canvas.drawRect(
          Rect.fromLTWH(x, size.height - peaks[i] - 2, bw, 1.4), p);
    }
  }

  @override
  bool shouldRepaint(covariant _VizPainter old) => true;
}
