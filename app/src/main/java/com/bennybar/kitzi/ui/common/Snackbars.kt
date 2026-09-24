package com.bennybar.kitzi.ui.common

import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow

/**
 * App-wide snackbars. Any screen (or a callback outside composition) can post one;
 * the single host at the root of the app shows it just above the floating bar.
 * Actions without visible feedback — add to queue, mark finished, bookmark — and
 * the ones that deserve an undo go through here.
 */
object Snackbars {
    data class Message(val text: String, val actionLabel: String? = null, val onAction: (() -> Unit)? = null)

    private val _messages = MutableSharedFlow<Message>(extraBufferCapacity = 8)
    val messages: SharedFlow<Message> = _messages.asSharedFlow()

    fun show(text: String, actionLabel: String? = null, onAction: (() -> Unit)? = null) {
        _messages.tryEmit(Message(text, actionLabel, onAction))
    }
}
