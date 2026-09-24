package com.bennybar.kitzi.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextDirection
import com.bennybar.kitzi.R

val GoogleSans = FontFamily(
    Font(R.font.google_sans_regular, FontWeight.Normal),
    Font(R.font.google_sans_italic, FontWeight.Normal, FontStyle.Italic),
    Font(R.font.google_sans_medium, FontWeight.Medium),
    Font(R.font.google_sans_medium_italic, FontWeight.Medium, FontStyle.Italic),
    Font(R.font.google_sans_semibold, FontWeight.SemiBold),
    Font(R.font.google_sans_semibold_italic, FontWeight.SemiBold, FontStyle.Italic),
    Font(R.font.google_sans_bold, FontWeight.Bold),
    Font(R.font.google_sans_bold_italic, FontWeight.Bold, FontStyle.Italic),
)

/**
 * Material 3 defaults, restated over Google Sans (the Flutter app sets `fontFamily: 'GoogleSans'`).
 *
 * `TextDirection.Content`: with the direction left unspecified, Compose lays every
 * paragraph out in the LAYOUT direction rather than detecting it from the text. In
 * a Hebrew (RTL) layout that turned "1 day" into "day 1" and "15h 49m" into
 * "49m 15h". Content direction keeps English strings left-to-right while Hebrew
 * titles still read right-to-left.
 */
val KitziTypography: Typography = Typography().run {
    fun TextStyle.kitzi() = copy(fontFamily = GoogleSans, textDirection = TextDirection.Content)
    copy(
        displayLarge = displayLarge.kitzi(),
        displayMedium = displayMedium.kitzi(),
        displaySmall = displaySmall.kitzi(),
        headlineLarge = headlineLarge.kitzi(),
        headlineMedium = headlineMedium.kitzi(),
        headlineSmall = headlineSmall.kitzi(),
        titleLarge = titleLarge.kitzi(),
        titleMedium = titleMedium.kitzi(),
        titleSmall = titleSmall.kitzi(),
        bodyLarge = bodyLarge.kitzi(),
        bodyMedium = bodyMedium.kitzi(),
        bodySmall = bodySmall.kitzi(),
        labelLarge = labelLarge.kitzi(),
        labelMedium = labelMedium.kitzi(),
        labelSmall = labelSmall.kitzi(),
    )
}
