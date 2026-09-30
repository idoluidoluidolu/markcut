package com.mr.flutter.plugin.filepicker

import java.io.File
import org.junit.Assert.*
import org.junit.Test

class SafeCachePathTest {
    @Test fun providerNamesCannotEscapeCacheOrChooseExistingFiles() {
        val root = File(System.getProperty("java.io.tmpdir"), "markcut-picker-cache")
        for (name in listOf("../../../files/settings.xml", "/data/data/target", "..\\secret.mp4",
            "clip.mp4\" -i \"other", "照片 你好.mov", "", null)) {
            val file = SafeCachePath.create(root, name)
            assertEquals(root.canonicalFile, file.parentFile)
            assertFalse(file.name.contains('"'))
            assertFalse(file.name.contains('\\'))
            assertNotEquals(file, SafeCachePath.create(root, name))
        }
    }
    @Test fun safeExtensionIsRetainedWithoutUsingTheDisplayBasename() {
        val file = SafeCachePath.create(File("cache"), "../../photo.HEIC")
        assertTrue(file.name.endsWith(".HEIC"))
        assertFalse(file.name.contains("photo"))
    }
}
