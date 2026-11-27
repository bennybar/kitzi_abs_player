package com.bennybar.kitzi.ui.settings

import androidx.test.core.app.ApplicationProvider
import com.bennybar.kitzi.data.legacy.FlutterPrefs
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner

@RunWith(RobolectricTestRunner::class)
class SettingsBackupTest {

    private val prefs = FlutterPrefs(ApplicationProvider.getApplicationContext())

    @Test
    fun `followed narrators travel with the backup`() {
        prefs.putStringSet("radar_narrators", setOf("Steven Pacey", "Ray Porter"))
        prefs.putBoolean("notify_new_releases", true)
        val text = SettingsBackup.export(prefs)

        prefs.putStringSet("radar_narrators", emptySet())
        prefs.putBoolean("notify_new_releases", false)
        assertTrue(SettingsBackup.import(prefs, text))

        assertEquals(setOf("Steven Pacey", "Ray Porter"), prefs.getStringSet("radar_narrators"))
        assertTrue(prefs.getBoolean("notify_new_releases", false))
    }

    @Test
    fun `a narrators value that isn't a list is ignored`() {
        prefs.putStringSet("radar_narrators", setOf("Ray Porter"))
        assertTrue(SettingsBackup.import(prefs, """{"radar_narrators": "Ray Porter"}"""))
        assertEquals(setOf("Ray Porter"), prefs.getStringSet("radar_narrators"))
    }
}
