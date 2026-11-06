package com.ravi.musicspot

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.widget.RemoteViews
import es.antonborri.home_widget.HomeWidgetProvider

/**
 * Home-screen widget (home_widget package pattern): a simple text-only
 * now-playing card — the app name, the last track's title and artist as
 * saved by the Dart side via HomeWidget.saveWidgetData under the keys
 * "title" and "artist", then HomeWidget.updateWidget(name: 'NowPlayingWidget').
 *
 * HONEST SCOPE: there are NO working play/pause/next buttons on this
 * widget. Real transport control would need a bridge into the
 * just_audio_background / audio_service foreground service, which is out
 * of scope here. Tapping the widget just opens the app.
 */
class NowPlayingWidget : HomeWidgetProvider() {

    override fun onUpdate(
        context: Context,
        appWidgetManager: AppWidgetManager,
        appWidgetIds: IntArray,
        widgetData: SharedPreferences,
    ) {
        val title = widgetData.getString("title", null)
            ?.takeIf { it.isNotBlank() } ?: "Nothing playing"
        val artist = widgetData.getString("artist", null) ?: ""

        val openApp = PendingIntent.getActivity(
            context,
            0,
            Intent(context, MainActivity::class.java)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

        for (id in appWidgetIds) {
            val views = RemoteViews(context.packageName, R.layout.now_playing_widget)
            views.setTextViewText(R.id.widget_title, title)
            views.setTextViewText(R.id.widget_artist, artist)
            views.setOnClickPendingIntent(R.id.widget_root, openApp)
            appWidgetManager.updateAppWidget(id, views)
        }
    }
}
