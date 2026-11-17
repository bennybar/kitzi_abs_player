package com.bennybar.kitzi.wear

import org.junit.Assert.assertEquals
import org.junit.Test

class PositionRulesTest {
    private fun start(local: Pair<Double, Long>?, server: Pair<Double, Long>?, shelf: Pair<Double, Long>) =
        WearPlayer.newestPosition(local, server, shelf)

    @Test fun newerServerWins() = assertEquals(500.0, start(100.0 to 1_000, 500.0 to 2_000, 0.0 to 0), 0.0)

    @Test fun newerWatchWins() = assertEquals(100.0, start(100.0 to 3_000, 500.0 to 2_000, 0.0 to 0), 0.0)

    // The server didn't answer (slow LTE): the shelf's newer position from the
    // phone beats an old one saved on the watch.
    @Test fun shelfBeatsOldWatchWhenServerSilent() = assertEquals(18_000.0, start(3_600.0 to 1_000, null, 18_000.0 to 5_000), 0.0)

    @Test fun watchBeatsOlderShelf() = assertEquals(3_600.0, start(3_600.0 to 9_000, null, 18_000.0 to 5_000), 0.0)

    @Test fun nothingKnownUsesShelf() = assertEquals(42.0, start(null, null, 42.0 to 0), 0.0)

    @Test fun locateAcrossTracks() {
        val tracks = listOf(TrackFile(0, "a", "audio/mpeg", 100.0), TrackFile(1, "b", "audio/mpeg", 50.0))
        assertEquals(1 to 20.0, WearPlayer.locate(120.0, tracks))
        assertEquals(1 to 60.0, WearPlayer.locate(160.0, tracks)) // past the end: the last track
    }
}
