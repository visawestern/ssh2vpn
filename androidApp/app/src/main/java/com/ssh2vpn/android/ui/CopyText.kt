package com.ssh2vpn.android.ui

import android.content.Context
import androidx.annotation.StringRes

/**
 * Подстановка цены как AppCopy.text(key, price:) в iOS:
 * сначала токен {price}, потом любой legacy $-ценник; без цены — как есть («…», не выдумка).
 */
fun priceText(ctx: Context, @StringRes id: Int, price: String?): String {
    val base = ctx.getString(id)
    if (price.isNullOrEmpty()) return base
    return base.replace("{price}", price)
        .replace(Regex("""\$[0-9]+(?:\.[0-9]{1,2})?"""), price)
}

/** %1$s-подстановка (iOS text(key, substitute:)). */
fun subText(ctx: Context, @StringRes id: Int, arg: String): String {
    return try {
        ctx.getString(id, arg)
    } catch (_: Exception) {
        ctx.getString(id).replace("%1\$s", arg).replace("%@", arg).replace("%d", arg).replace("%s", arg)
    }
}
