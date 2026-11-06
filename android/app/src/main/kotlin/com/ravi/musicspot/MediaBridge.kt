package com.ravi.musicspot

import android.content.Context
import android.provider.MediaStore

/**
 * Device music library for the Dart LocalSource, over the `upze/media`
 * channel. This replaces the unmaintained on_audio_query plugin (its
 * android library has no AGP-8 namespace, which fails modern builds)
 * with a direct MediaStore query — exactly what the Kotlin app's
 * LocalSource.kt did: IS_MUSIC != 0, sorted by title COLLATE NOCASE.
 *
 * Method `songs` returns a List of maps with keys:
 * id (Long), title, artist, album, albumId (Long), duration (Long, ms),
 * mime (String), year (Int). The caller must already hold the audio
 * permission; without it the query throws and Dart treats it as empty.
 */
object MediaBridge {

    fun songs(context: Context): List<Map<String, Any?>> {
        val uri = MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.TITLE,
            MediaStore.Audio.Media.ARTIST,
            MediaStore.Audio.Media.ALBUM,
            MediaStore.Audio.Media.ALBUM_ID,
            MediaStore.Audio.Media.DURATION,
            MediaStore.Audio.Media.MIME_TYPE,
            MediaStore.Audio.Media.YEAR,
        )
        val out = ArrayList<Map<String, Any?>>()
        context.contentResolver.query(
            uri,
            projection,
            "${MediaStore.Audio.Media.IS_MUSIC} != 0",
            null,
            "${MediaStore.Audio.Media.TITLE} COLLATE NOCASE ASC",
        )?.use { c ->
            val idI = c.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val titleI = c.getColumnIndexOrThrow(MediaStore.Audio.Media.TITLE)
            val artistI = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ARTIST)
            val albumI = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM)
            val albumIdI = c.getColumnIndexOrThrow(MediaStore.Audio.Media.ALBUM_ID)
            val durI = c.getColumnIndexOrThrow(MediaStore.Audio.Media.DURATION)
            val mimeI = c.getColumnIndexOrThrow(MediaStore.Audio.Media.MIME_TYPE)
            val yearI = c.getColumnIndexOrThrow(MediaStore.Audio.Media.YEAR)
            while (c.moveToNext()) {
                out.add(
                    mapOf(
                        "id" to c.getLong(idI),
                        "title" to (c.getString(titleI) ?: ""),
                        "artist" to c.getString(artistI),
                        "album" to c.getString(albumI),
                        "albumId" to c.getLong(albumIdI),
                        "duration" to c.getLong(durI),
                        "mime" to c.getString(mimeI),
                        "year" to c.getInt(yearI),
                    )
                )
            }
        }
        return out
    }
}
