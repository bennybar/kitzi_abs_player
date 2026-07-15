package com.bennybar.kitzi.playback

/**
 * The book<->track coordinate math. Pure functions, no player, so it can be
 * tested exhaustively — this is the subtlest code in the app.
 *
 * The problem: an audiobook is a list of audio files, but chapters are defined
 * against the *book*, and a chapter freely straddles a file boundary. So the
 * player's position (track-local) is not the book position, and every chapter,
 * bookmark, progress report and seek is expressed in book coordinates.
 *
 * `durationSec == null` means "not known yet" and is load-bearing: local files
 * have no duration until they are opened, and a wrong guess here silently
 * corrupts the user's progress on the server.
 */
data class Track(
    val index: Int,
    val url: String,
    val mimeType: String,
    val durationSec: Double?,
    val isLocal: Boolean,
)

/** A chapter's end is implicit: the next chapter's start, or the end of the book. */
data class Chapter(val title: String, val startSec: Double)

data class TrackPosition(val trackIndex: Int, val offsetSec: Double)

data class ChapterMetrics(
    val index: Int,
    val title: String,
    val startSec: Double,
    val endSec: Double,
    val elapsedSec: Double,
) {
    val durationSec: Double get() = endSec - startSec
    val fraction: Double get() = if (durationSec <= 0) 0.0 else (elapsedSec / durationSec).coerceIn(0.0, 1.0)
}

object PlaybackMath {

    /**
     * Book position -> which track, and how far into it.
     *
     * An unknown duration short-circuits: we assume the target lies inside that
     * track. That is the only safe assumption — treating unknown as 0 would skip
     * the track entirely and land the user in the wrong place.
     */
    fun mapGlobalToTrack(globalSec: Double, tracks: List<Track>): TrackPosition {
        if (tracks.isEmpty()) return TrackPosition(0, 0.0)

        var remaining = globalSec.coerceAtLeast(0.0)
        for (i in tracks.indices) {
            val d = tracks[i].durationSec
            if (d == null || d <= 0) return TrackPosition(i, remaining)
            if (remaining < d) return TrackPosition(i, remaining)
            remaining -= d
        }

        // Past the end of the book: clamp to the end of the last track, not to
        // the leftover remainder.
        val last = tracks.lastIndex
        return TrackPosition(last, tracks[last].durationSec ?: 0.0)
    }

    /**
     * (track, offset) -> book position.
     *
     * Returns null when ANY earlier track's duration is unknown, because the
     * prefix sum would be wrong. Callers must treat null as "don't report
     * progress" — reporting a track-local position as if it were a book position
     * overwrites the server with a much smaller number and loses the user's place.
     */
    fun computeGlobal(trackIndex: Int, offsetSec: Double, tracks: List<Track>): Double? {
        if (trackIndex !in tracks.indices) return null
        var prefix = 0.0
        for (i in 0 until trackIndex) {
            val d = tracks[i].durationSec ?: return null
            if (d <= 0) return null
            prefix += d
        }
        return prefix + offsetSec
    }

    /**
     * Lenient variant for the explicit-seek path only, where the caller already
     * knows the target and unknown prefixes count as zero.
     */
    fun computeGlobalLenient(trackIndex: Int, offsetSec: Double, tracks: List<Track>): Double {
        var prefix = 0.0
        for (i in 0 until trackIndex.coerceAtMost(tracks.size)) {
            prefix += tracks[i].durationSec?.takeIf { it > 0 } ?: 0.0
        }
        return prefix + offsetSec
    }

    /** Cumulative start offset of each track; unknown durations contribute 0. */
    fun startOffsets(tracks: List<Track>): DoubleArray {
        val offsets = DoubleArray(tracks.size)
        var acc = 0.0
        for (i in tracks.indices) {
            offsets[i] = acc
            acc += tracks[i].durationSec?.takeIf { it > 0 } ?: 0.0
        }
        return offsets
    }

    /**
     * Whole-book duration. Prefers the server's figure whenever any track
     * duration is unknown — summing a partially-known track list understates the
     * total, which would make the last chapter's end (and so the progress bar)
     * wrong.
     */
    fun totalDuration(tracks: List<Track>, serverDurationSec: Double?): Double? {
        val allKnown = tracks.isNotEmpty() && tracks.all { (it.durationSec ?: 0.0) > 0 }
        if (allKnown) return tracks.sumOf { it.durationSec!! }
        serverDurationSec?.takeIf { it > 0 }?.let { return it }
        val partial = tracks.mapNotNull { it.durationSec }.filter { it > 0 }.sum()
        return partial.takeIf { it > 0 }
    }

    /**
     * Which chapter a book position falls in. A chapter's end is the next
     * chapter's start; the last one ends at the end of the book.
     */
    fun currentChapter(
        globalSec: Double,
        chapters: List<Chapter>,
        totalSec: Double?,
    ): ChapterMetrics? {
        if (chapters.isEmpty() || totalSec == null || totalSec <= 0) return null

        var idx = 0
        for (i in chapters.indices) {
            if (globalSec >= chapters[i].startSec) idx = i else break
        }

        val start = chapters[idx].startSec
        val end = if (idx + 1 < chapters.size) chapters[idx + 1].startSec else totalSec
        if (end <= start) return null

        return ChapterMetrics(
            index = idx,
            title = chapters[idx].title,
            startSec = start,
            endSec = end,
            elapsedSec = (globalSec - start).coerceIn(0.0, end - start),
        )
    }

    /**
     * "Previous chapter" means the previous chapter's start, not the current
     * chapter's start — matching the Flutter app's behaviour.
     */
    fun previousChapterStart(globalSec: Double, chapters: List<Chapter>, totalSec: Double?): Double? {
        val current = currentChapter(globalSec, chapters, totalSec) ?: return null
        return chapters.getOrNull(current.index - 1)?.startSec
    }

    fun nextChapterStart(globalSec: Double, chapters: List<Chapter>, totalSec: Double?): Double? {
        val current = currentChapter(globalSec, chapters, totalSec) ?: return null
        return chapters.getOrNull(current.index + 1)?.startSec
    }

    /**
     * One chapter per track, for books the server gives no chapters for.
     * Requires known durations: with unknown ones every chapter would start at
     * the same place.
     */
    fun chaptersFromTracks(tracks: List<Track>): List<Chapter> {
        if (tracks.any { (it.durationSec ?: 0.0) <= 0 }) return emptyList()
        val offsets = startOffsets(tracks)
        return tracks.mapIndexed { i, t ->
            val name = t.url.substringAfterLast('/').substringBeforeLast('.')
            Chapter(title = name.ifBlank { "Track ${i + 1}" }, startSec = offsets[i])
        }
    }
}
