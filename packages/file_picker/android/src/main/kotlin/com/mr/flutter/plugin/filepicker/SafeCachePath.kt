package com.mr.flutter.plugin.filepicker

import java.io.File
import java.util.UUID

/** Provider display names are labels, never filesystem paths. */
internal object SafeCachePath {
    fun create(cacheDirectory: File, displayName: String?): File {
        val extension = displayName?.substringAfterLast('.', "")
            ?.takeIf { it.matches(Regex("[A-Za-z0-9]{1,16}")) }
        val root = cacheDirectory.canonicalFile
        val file = File(root, UUID.randomUUID().toString() +
            (extension?.let { ".$it" } ?: ".bin")).canonicalFile
        require(file.parentFile == root) { "Invalid picker cache destination" }
        return file
    }
}
