package com.bennybar.kitzi.ui.theme

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

/**
 * Seed for the generated scheme (`ColorScheme.fromSeed`, tonalSpot variant).
 *
 * Wallpaper/Material You dynamic colour is deliberately NOT used: the Flutter
 * app calls DynamicColorBuilder but discards `lightDynamic`/`darkDynamic` and
 * always generates from this seed, "for a consistent identity" (lib/main.dart).
 */
val KitziSeed = Color(0xFF5965C8)

/**
 * The dark scheme the Flutter app hand-tunes on top of the generated one: a
 * deep, OLED-friendly base with very tight elevation steps, off-white text and
 * a muted (not neon) indigo accent. Values are copied verbatim from
 * lib/main.dart so the port is pixel-identical. Dark is the default theme.
 */
private val KitziDarkColors = darkColorScheme(
    surface = Color(0xFF0B0C11),
    surfaceDim = Color(0xFF08090D),
    surfaceBright = Color(0xFF15161D),
    surfaceContainerLowest = Color(0xFF070809),
    surfaceContainerLow = Color(0xFF0E0F15),
    surfaceContainer = Color(0xFF111219),
    surfaceContainerHigh = Color(0xFF15171F),
    surfaceContainerHighest = Color(0xFF1A1C26),
    onSurface = Color(0xFFD2D4DD),
    onSurfaceVariant = Color(0xFF989CAC),
    outline = Color(0xFF343745),
    outlineVariant = Color(0xFF20222D),
    primary = Color(0xFF9AA1E2),
    onPrimary = Color(0xFF161B40),
    primaryContainer = Color(0xFF252A5E),
    onPrimaryContainer = Color(0xFFDDE0FB),
    secondary = Color(0xFFA6ABD6),
    surfaceTint = Color.Transparent,
)

// Placeholder until the tonalSpot palette is generated from KitziSeed; the light
// scheme is refined in the theming pass. Dark is what ships by default.
private val KitziLightColors = lightColorScheme(
    primary = KitziSeed,
    surfaceTint = Color.Transparent,
)

@Composable
fun KitziTheme(
    darkTheme: Boolean = true,
    content: @Composable () -> Unit,
) {
    MaterialTheme(
        colorScheme = if (darkTheme) KitziDarkColors else KitziLightColors,
        typography = KitziTypography,
        content = content,
    )
}
