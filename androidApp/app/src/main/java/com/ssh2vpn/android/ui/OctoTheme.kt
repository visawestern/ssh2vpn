package com.ssh2vpn.android.ui

import androidx.compose.material3.Typography
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.Font
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import com.ssh2vpn.android.R

/** Дизайн-система Octohide — порт OctohideColors + RootView (светлая тема, OpenSans). */
object Octo {
    val Bg = Color(0xFFF6F7FA)
    val Card = Color.White
    val Divider = Color(0xFFEFF0F3)
    val Gray40 = Color(0xFFBEC1C5)
    val Gray60 = Color(0xFF838991)
    val Gray80 = Color(0xFF50565E)
    val Gray100 = Color(0xFF132946)
    val Prim50 = Color(0xFF4BDB98)
    val Prim100 = Color(0xFF3CC083)
    val Sec50 = Color(0xFF172946)
    val Sec20 = Color(0xFF4575A0)
    val ShieldOff = Color(0xFF596680)
}

private val OpenSans = FontFamily(
    Font(R.font.opensans_light, FontWeight.Light),
    Font(R.font.opensans_regular, FontWeight.Normal),
    Font(R.font.opensans_medium, FontWeight.Medium),
    Font(R.font.opensans_semibold, FontWeight.SemiBold),
    Font(R.font.opensans_bold, FontWeight.Bold)
)

private val Scheme = lightColorScheme(
    primary = Octo.Prim100,
    onPrimary = Color.White,
    primaryContainer = Octo.Prim50,
    secondary = Octo.Sec50,
    onSecondary = Color.White,
    tertiary = Octo.Sec20,
    background = Octo.Bg,
    onBackground = Octo.Gray100,
    surface = Octo.Card,
    onSurface = Octo.Gray100,
    surfaceVariant = Octo.Divider,
    onSurfaceVariant = Octo.Gray80,
    outline = Octo.Gray40,
    error = Color(0xFFB3261E)
)

@Composable
fun OctoTheme(content: @Composable () -> Unit) {
    val base = Typography()
    fun androidx.compose.ui.text.TextStyle.withFont() = copy(fontFamily = OpenSans)
    val typo = Typography(
        displayLarge = base.displayLarge.withFont(),
        displayMedium = base.displayMedium.withFont(),
        displaySmall = base.displaySmall.withFont(),
        headlineLarge = base.headlineLarge.withFont(),
        headlineMedium = base.headlineMedium.withFont(),
        headlineSmall = base.headlineSmall.withFont(),
        titleLarge = base.titleLarge.withFont(),
        titleMedium = base.titleMedium.withFont(),
        titleSmall = base.titleSmall.withFont(),
        bodyLarge = base.bodyLarge.withFont(),
        bodyMedium = base.bodyMedium.withFont(),
        bodySmall = base.bodySmall.withFont(),
        labelLarge = base.labelLarge.withFont(),
        labelMedium = base.labelMedium.withFont(),
        labelSmall = base.labelSmall.withFont()
    )
    androidx.compose.material3.MaterialTheme(
        colorScheme = Scheme,
        typography = typo,
        content = content
    )
}
