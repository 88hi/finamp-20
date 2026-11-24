package com.unicornsonlsd.finamp

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest

object MediaBackupHelper {
    private data class FolderAcc(
        val bucketId: String,
        val name: String,
        var photoCount: Int = 0,
        var videoCount: Int = 0,
        var totalBytes: Long = 0L,
    )

    /**
     * Triggers Android MediaScanner on common media directories so brand-new
     * photos/videos appear in MediaStore immediately.
     */
    fun triggerMediaScan(context: Context) {
        try {
            val dirs = listOf(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES),
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MOVIES),
            )
            val paths = ArrayList<String>()
            for (dir in dirs) {
                if (dir != null && dir.exists() && dir.isDirectory) {
                    paths.add(dir.absolutePath)
                    dir.listFiles()?.filter { it.isDirectory }?.forEach { sub ->
                        paths.add(sub.absolutePath)
                    }
                }
            }
            if (paths.isNotEmpty()) {
                MediaScannerConnection.scanFile(context, paths.toTypedArray(), null, null)
            }
        } catch (_: Exception) {
            // Non-fatal on restricted scoped-storage devices.
        }
    }

    fun listMediaFolders(
        context: Context,
        includePhotos: Boolean,
        includeVideos: Boolean,
    ): List<Map<String, Any>> {
        triggerMediaScan(context)
        val resolver = context.contentResolver
        val map = LinkedHashMap<String, FolderAcc>()

        if (includePhotos) {
            queryFolderStats(resolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, isVideo = false, map)
        }
        if (includeVideos) {
            queryFolderStats(resolver, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, isVideo = true, map)
        }

        return map.values
            .sortedWith(
                compareByDescending<FolderAcc> { it.name.equals("Camera", ignoreCase = true) }
                    .thenByDescending { it.photoCount + it.videoCount }
                    .thenBy { it.name.lowercase() },
            )
            .map { acc ->
                mapOf(
                    "bucketId" to acc.bucketId,
                    "name" to acc.name,
                    "photoCount" to acc.photoCount,
                    "videoCount" to acc.videoCount,
                    "totalBytes" to acc.totalBytes,
                )
            }
    }

    private fun queryFolderStats(
        resolver: ContentResolver,
        uri: Uri,
        isVideo: Boolean,
        map: MutableMap<String, FolderAcc>,
    ) {
        val projection = arrayOf(
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
        )
        resolver.query(uri, projection, null, null, null)?.use { cursor ->
            val bucketIdIdx = cursor.getColumnIndex(MediaStore.MediaColumns.BUCKET_ID)
            val bucketNameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val sizeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)

            while (cursor.moveToNext()) {
                val bucketId = if (bucketIdIdx >= 0) cursor.getString(bucketIdIdx) ?: "default" else "default"
                val bucketName = if (bucketNameIdx >= 0) cursor.getString(bucketNameIdx) ?: "Unknown" else "Unknown"
                val size = if (sizeIdx >= 0) cursor.getLong(sizeIdx).coerceAtLeast(0L) else 0L

                val acc = map.getOrPut(bucketId) { FolderAcc(bucketId = bucketId, name = bucketName) }
                if (isVideo) {
                    acc.videoCount++
                } else {
                    acc.photoCount++
                }
                acc.totalBytes += size
            }
        }
    }

    fun listMediaItems(
        context: Context,
        bucketIds: List<String>,
        includePhotos: Boolean,
        includeVideos: Boolean,
    ): List<Map<String, Any>> {
        if (bucketIds.isEmpty()) return emptyList()
        triggerMediaScan(context)
        val resolver = context.contentResolver
        val items = ArrayList<Map<String, Any>>()
        val bucketSet = bucketIds.toHashSet()

        if (includePhotos) {
            queryItems(resolver, MediaStore.Images.Media.EXTERNAL_CONTENT_URI, isVideo = false, bucketSet, items)
        }
        if (includeVideos) {
            queryItems(resolver, MediaStore.Video.Media.EXTERNAL_CONTENT_URI, isVideo = true, bucketSet, items)
        }

        // Sort newest first so newly captured photos/videos are backed up first.
        items.sortByDescending { (it["dateModifiedMs"] as? Long) ?: 0L }
        return items
    }

    private fun queryItems(
        resolver: ContentResolver,
        collectionUri: Uri,
        isVideo: Boolean,
        bucketSet: Set<String>,
        out: MutableList<Map<String, Any>>,
    ) {
        val projection = arrayOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.BUCKET_ID,
            MediaStore.MediaColumns.BUCKET_DISPLAY_NAME,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.MediaColumns.DATE_ADDED,
            MediaStore.MediaColumns.MIME_TYPE,
        )
        val sortOrder = "${MediaStore.MediaColumns.DATE_ADDED} DESC"

        resolver.query(collectionUri, projection, null, null, sortOrder)?.use { cursor ->
            val idIdx = cursor.getColumnIndex(MediaStore.MediaColumns._ID)
            val bucketIdIdx = cursor.getColumnIndex(MediaStore.MediaColumns.BUCKET_ID)
            val bucketNameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val nameIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DISPLAY_NAME)
            val sizeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
            val dateModIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_MODIFIED)
            val dateAddIdx = cursor.getColumnIndex(MediaStore.MediaColumns.DATE_ADDED)
            val mimeIdx = cursor.getColumnIndex(MediaStore.MediaColumns.MIME_TYPE)

            while (cursor.moveToNext()) {
                val bucketId = if (bucketIdIdx >= 0) cursor.getString(bucketIdIdx) ?: "default" else "default"
                if (!bucketSet.contains(bucketId)) continue

                val id = if (idIdx >= 0) cursor.getLong(idIdx) else continue
                val fileName = if (nameIdx >= 0) cursor.getString(nameIdx) else null
                if (fileName.isNullOrBlank()) continue

                val itemUri = ContentUris.withAppendedId(collectionUri, id)
                var size = if (sizeIdx >= 0) cursor.getLong(sizeIdx) else 0L
                // Newly captured files may temporarily report SIZE=0 in MediaStore;
                // fall back to the actual FileDescriptor statSize so they are never skipped.
                if (size <= 0L) {
                    size = try {
                        resolver.openFileDescriptor(itemUri, "r")?.use { it.statSize } ?: 0L
                    } catch (_: Exception) {
                        0L
                    }
                }
                if (size <= 0L) continue

                val bucketName = if (bucketNameIdx >= 0) cursor.getString(bucketNameIdx) ?: "Unknown" else "Unknown"
                val dateModSec = if (dateModIdx >= 0) cursor.getLong(dateModIdx) else 0L
                val dateAddSec = if (dateAddIdx >= 0) cursor.getLong(dateAddIdx) else 0L
                val bestDateSec = maxOf(dateModSec, dateAddSec)
                val mimeType = if (mimeIdx >= 0) cursor.getString(mimeIdx) ?: "application/octet-stream" else "application/octet-stream"

                out.add(
                    mapOf(
                        "id" to "${if (isVideo) "v" else "i"}_$id",
                        "contentUri" to itemUri.toString(),
                        "bucketId" to bucketId,
                        "bucketName" to bucketName,
                        "fileName" to fileName,
                        "size" to size,
                        "dateModifiedMs" to (bestDateSec * 1000L),
                        "mimeType" to mimeType,
                        "isVideo" to isVideo,
                    ),
                )
            }
        }
    }

    fun readFileChunk(context: Context, contentUriStr: String, offset: Long, length: Int): ByteArray {
        val uri = Uri.parse(contentUriStr)
        context.contentResolver.openFileDescriptor(uri, "r")?.use { pfd ->
            FileInputStream(pfd.fileDescriptor).use { fis ->
                if (offset > 0) {
                    fis.channel.position(offset)
                }
                val buffer = ByteArray(length)
                var totalRead = 0
                while (totalRead < length) {
                    val read = fis.read(buffer, totalRead, length - totalRead)
                    if (read <= 0) break
                    totalRead += read
                }
                return if (totalRead == length) buffer else buffer.copyOf(totalRead)
            }
        }
        throw IllegalStateException("Cannot open content URI: $contentUriStr")
    }

    fun computeSha256(context: Context, contentUriStr: String): String {
        val uri = Uri.parse(contentUriStr)
        val digest = MessageDigest.getInstance("SHA-256")
        context.contentResolver.openInputStream(uri)?.use { input ->
            val buffer = ByteArray(65536)
            var read: Int
            while (input.read(buffer).also { read = it } > 0) {
                digest.update(buffer, 0, read)
            }
        } ?: throw IllegalStateException("Cannot open content URI: $contentUriStr")

        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
