package com.bennybar.kitzi.ui.common

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.interaction.collectIsPressedAsState
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material3.Icon
import androidx.compose.material3.LoadingIndicator
import androidx.compose.material3.LoadingIndicatorDefaults
import androidx.compose.material3.MaterialShapes
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.toPath
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Matrix
import androidx.compose.ui.graphics.Outline
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.unit.Density
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.LayoutDirection
import androidx.graphics.shapes.Morph
import com.bennybar.kitzi.ui.UiPrefsState

/** The Material 3 Expressive loading indicator (morphing shapes), in place of a spinner. */
@Composable
fun KitziLoading(modifier: Modifier = Modifier, color: Color = LoadingIndicatorDefaults.indicatorColor) {
    LoadingIndicator(modifier = modifier, color = color)
}

/**
 * The play / pause button. With the Expressive setting on (the default) it morphs
 * between Material shapes — a rounded square while paused, a scalloped "cookie"
 * while playing — on a spring, and squishes a little while pressed. Off, it keeps
 * [plainShape]. While a book is starting it shows the loading indicator instead.
 */
@Composable
fun PlayPauseButton(
    isPlaying: Boolean,
    preparing: Boolean,
    size: Dp,
    iconSize: Dp,
    background: Brush,
    contentColor: Color,
    plainShape: Shape,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val expressive by UiPrefsState.expressivePlayButton
    val interaction = remember { MutableInteractionSource() }
    val pressed by interaction.collectIsPressedAsState()
    val morph = remember { Morph(MaterialShapes.Square, MaterialShapes.Cookie9Sided) }
    val progress by animateFloatAsState(
        if (isPlaying) 1f else 0f,
        MaterialTheme.motionScheme.defaultSpatialSpec(),
        label = "playMorph",
    )
    val squish by animateFloatAsState(
        if (pressed && expressive) 0.9f else 1f,
        MaterialTheme.motionScheme.fastSpatialSpec(),
        label = "playPress",
    )
    val shape = if (expressive) remember(progress) { MorphShape(morph, progress) } else plainShape
    Box(
        modifier
            .size(size)
            .graphicsLayer {
                scaleX = squish
                scaleY = squish
            }
            .clip(shape)
            .background(background)
            .clickable(interactionSource = interaction, indication = androidx.compose.material3.ripple(), onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        if (preparing) {
            KitziLoading(Modifier.size(size * 0.62f), color = contentColor)
        } else {
            Icon(
                if (isPlaying) Icons.Default.Pause else Icons.Default.PlayArrow,
                if (isPlaying) "Pause" else "Play",
                tint = contentColor,
                modifier = Modifier.size(iconSize),
            )
        }
    }
}

/** A [Morph] at a given progress, scaled to the component (Material shapes are unit-sized). */
private class MorphShape(private val morph: Morph, private val progress: Float) : Shape {
    override fun createOutline(size: Size, layoutDirection: LayoutDirection, density: Density): Outline {
        val path = morph.toPath(progress)
        path.transform(Matrix().apply { scale(size.width, size.height) })
        return Outline.Generic(path)
    }
}
