package com.bennybar.kitzi.ui.theme

import androidx.compose.material3.Typography
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
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

/** Material 3 defaults, restated over Google Sans (the Flutter app sets `fontFamily: 'GoogleSans'`). */
val KitziTypography: Typography = Typography().run {
    copy(
        displayLarge = displayLarge.copy(fontFamily = GoogleSans),
        displayMedium = displayMedium.copy(fontFamily = GoogleSans),
        displaySmall = displaySmall.copy(fontFamily = GoogleSans),
        headlineLarge = headlineLarge.copy(fontFamily = GoogleSans),
        headlineMedium = headlineMedium.copy(fontFamily = GoogleSans),
        headlineSmall = headlineSmall.copy(fontFamily = GoogleSans),
        titleLarge = titleLarge.copy(fontFamily = GoogleSans),
        titleMedium = titleMedium.copy(fontFamily = GoogleSans),
        titleSmall = titleSmall.copy(fontFamily = GoogleSans),
        bodyLarge = bodyLarge.copy(fontFamily = GoogleSans),
        bodyMedium = bodyMedium.copy(fontFamily = GoogleSans),
        bodySmall = bodySmall.copy(fontFamily = GoogleSans),
        labelLarge = labelLarge.copy(fontFamily = GoogleSans),
        labelMedium = labelMedium.copy(fontFamily = GoogleSans),
        labelSmall = labelSmall.copy(fontFamily = GoogleSans),
    )
}
