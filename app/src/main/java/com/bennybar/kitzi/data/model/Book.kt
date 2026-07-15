package com.bennybar.kitzi.data.model

import com.bennybar.kitzi.data.db.BookEntity
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.doubleOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.longOrNull

data class Book(
    val id: String,
    val title: String,
    val author: String?,
    val coverUrl: String,
    val description: String?,
    val durationMs: Long?,
    val sizeBytes: Long?,
    val updatedAt: Long?,
    val addedAt: Long?,
    val series: String?,
    val seriesSequence: Double?,
    val collection: String?,
    val collectionSequence: Double?,
    val isAudioBook: Boolean,
    val mediaKind: String?,
    val libraryId: String?,
    val authors: List<String>,
    val narrators: List<String>,
    val publisher: String?,
    val publishYear: Int?,
    val genres: List<String>,
)

// --- lenient JSON helpers; ABS field names and types vary across versions ---

internal fun JsonElement?.obj(): JsonObject? = this as? JsonObject
internal fun JsonElement?.arr(): JsonArray? = this as? JsonArray
internal fun JsonElement?.str(): String? =
    (this as? JsonPrimitive)?.takeIf { it.isString || it.content.isNotEmpty() }?.content?.takeIf { it.isNotEmpty() && it != "null" }

internal fun JsonElement?.num(): Double? = (this as? JsonPrimitive)?.let {
    it.doubleOrNull ?: it.content.toDoubleOrNull()
}

internal fun JsonElement?.int(): Int? = (this as? JsonPrimitive)?.let {
    it.intOrNull ?: it.content.toDoubleOrNull()?.toInt()
}

internal fun JsonElement?.bool(): Boolean? = (this as? JsonPrimitive)?.booleanOrNull

/** Values below 1e11 are seconds, not millis (book.dart:270 `_parseTimestampFlexible`). */
internal fun JsonElement?.epochMs(): Long? {
    val p = this as? JsonPrimitive ?: return null
    p.longOrNull?.let { return if (it < 100_000_000_000L) it * 1000 else it }
    // ISO-8601
    return runCatching { java.time.Instant.parse(p.content).toEpochMilli() }.getOrNull()
}

/** Names may be plain strings or objects with a `name` field. */
private fun JsonArray?.names(): List<String> =
    this.orEmpty().mapNotNull { el -> el.obj()?.get("name").str() ?: el.str() }

object BookMapper {

    /**
     * Ports Book.fromLibraryItemJson (book.dart:55). Returns null for items with
     * no id or no title — the Dart drops those too (books_repository.dart:225).
     */
    fun fromLibraryItem(json: JsonObject, baseUrl: String, token: String?): Book? {
        val id = json["id"].str() ?: json["_id"].str() ?: return null
        val media = json["media"].obj()
        val meta = media?.get("metadata").obj()

        val title = (json["title"].str() ?: meta?.get("title").str())?.takeIf { it.isNotBlank() }
            ?: return null

        val authors = meta?.get("authors").arr().names()
        val author = json["author"].str()
            ?: meta?.get("authorName").str()
            ?: meta?.get("author").str()
            ?: authors.takeIf { it.isNotEmpty() }?.joinToString(", ")

        val durationSec = media?.get("duration").num()
        val (series, seriesSeq) = parseGrouping(meta, "series", "seriesName", "seriesSequence")
        val (collection, collectionSeq) = parseGrouping(meta, "collection", "collectionName", "collectionSequence")

        return Book(
            id = id,
            title = title,
            author = author,
            // Built, never sent by the server. Stored token-stripped and rebuilt on read.
            coverUrl = coverUrl(id, baseUrl, token),
            description = meta?.get("description").str() ?: json["description"].str(),
            durationMs = durationSec?.takeIf { it > 0 }?.let { (it * 1000).toLong() },
            sizeBytes = media?.get("size").num()?.toLong(),
            updatedAt = json["updatedAt"].epochMs(),
            addedAt = json["addedAt"].epochMs() ?: json["createdAt"].epochMs(),
            series = series,
            seriesSequence = seriesSeq,
            collection = collection,
            collectionSequence = collectionSeq,
            isAudioBook = isAudioBook(media),
            mediaKind = listOf(
                media?.get("type"), media?.get("mediaType"), json["mediaType"], json["type"],
            ).firstNotNullOfOrNull { it.str() }?.lowercase(),
            libraryId = json["libraryId"].str(),
            authors = authors,
            narrators = meta?.get("narrators").arr().names(),
            publisher = meta?.get("publisher").str(),
            publishYear = meta?.get("publishedYear").int()
                ?: meta?.get("publishYear").int()
                ?: meta?.get("year").int()
                ?: meta?.get("publishedDate").str()?.take(4)?.toIntOrNull(),
            genres = meta?.get("genres").arr().orEmpty().mapNotNull { it.str() },
        )
    }

    fun coverUrl(id: String, baseUrl: String, token: String?): String =
        "$baseUrl/api/items/$id/cover" + if (!token.isNullOrEmpty()) "?token=$token" else ""

    /**
     * Strictly: has audio AND is not an ebook (book.dart:234). A book with both
     * is treated as an ebook, and ebooks are dropped from the library entirely.
     */
    private fun isAudioBook(media: JsonObject?): Boolean {
        if (media == null) return false
        val hasAudio = (media["duration"].num() ?: 0.0) > 0 ||
            !media["audioFiles"].arr().isNullOrEmpty() ||
            !media["tracks"].arr().isNullOrEmpty() ||
            (media["audioTrackCount"].int() ?: 0) > 0

        val hasEbook = media["ebook"] != null ||
            media["ebookFile"] != null ||
            media["ebookFormat"] != null

        return hasAudio && !hasEbook
    }

    /**
     * `series`/`collection` arrive as a String, a Map, or a List of Maps depending
     * on the server and the endpoint (book.dart:142).
     */
    private fun parseGrouping(
        meta: JsonObject?,
        key: String,
        altNameKey: String,
        altSeqKey: String,
    ): Pair<String?, Double?> {
        if (meta == null) return null to null

        val raw = meta[key] ?: meta["${key}s"]
        val node: JsonObject? = when (raw) {
            is JsonObject -> raw
            is JsonArray -> raw.firstOrNull().obj()
            else -> null
        }

        val rawName = raw.str()
            ?: node?.let { it["name"].str() ?: it["series"].str() ?: it["title"].str() }
            ?: meta[altNameKey].str()

        val sequence = node?.let {
            it["sequence"].num() ?: it["index"].num() ?: it["number"].num()
                ?: it["bookNumber"].num() ?: it["position"].num()
        } ?: meta[altSeqKey].num()

        // Minified responses hand back the name with the sequence baked into the
        // string ("Bill Hodges Trilogy #1"). Grouping on that verbatim splits one
        // series into a separate entry per book, each with a count of one.
        val trailing = rawName?.let { SEQUENCE_SUFFIX.find(it) }
        return if (trailing != null) {
            trailing.groupValues[1].trim() to (sequence ?: trailing.groupValues[2].toDoubleOrNull())
        } else {
            rawName to sequence
        }
    }

    /** e.g. "Bill Hodges Trilogy #1", "The Expanse #4.5", "Foundation Book 2". */
    private val SEQUENCE_SUFFIX =
        Regex("""^(.*?)\s*(?:#|\b(?:book|volume|vol\.?|part)\s+)([\d.]+)\s*$""", RegexOption.IGNORE_CASE)
}

fun Book.toEntity(coverPath: String? = null): BookEntity = BookEntity(
    id = id,
    title = title,
    author = author,
    // Persist without the token, so a rotated token doesn't invalidate every row.
    coverUrl = coverUrl.substringBefore("?token="),
    coverPath = coverPath,
    coverUpdatedAt = updatedAt,
    description = description,
    durationMs = durationMs,
    sizeBytes = sizeBytes,
    updatedAt = updatedAt,
    addedAt = addedAt ?: updatedAt,
    series = series,
    seriesSequence = seriesSequence,
    collection = collection,
    collectionSequence = collectionSequence,
    isAudioBook = isAudioBook,
    mediaKind = mediaKind,
    libraryId = libraryId,
    authors = authors.takeIf { it.isNotEmpty() }?.let { kotlinx.serialization.json.Json.encodeToString(it) },
    narrators = narrators.takeIf { it.isNotEmpty() }?.let { kotlinx.serialization.json.Json.encodeToString(it) },
    publisher = publisher,
    publishYear = publishYear,
    genres = genres.takeIf { it.isNotEmpty() }?.let { kotlinx.serialization.json.Json.encodeToString(it) },
)

fun BookEntity.toBook(baseUrl: String, token: String?): Book {
    val json = kotlinx.serialization.json.Json
    fun list(raw: String?): List<String> =
        raw?.let { runCatching { json.decodeFromString<List<String>>(it) }.getOrNull() }.orEmpty()

    return Book(
        id = id,
        title = title,
        author = author,
        // Local file wins so covers render offline; otherwise rebuild with the live token.
        coverUrl = coverPath?.takeIf { java.io.File(it).exists() }?.let { "file://$it" }
            ?: BookMapper.coverUrl(id, baseUrl, token),
        description = description,
        durationMs = durationMs,
        sizeBytes = sizeBytes,
        updatedAt = updatedAt,
        addedAt = addedAt,
        series = series,
        seriesSequence = seriesSequence,
        collection = collection,
        collectionSequence = collectionSequence,
        isAudioBook = isAudioBook,
        mediaKind = mediaKind,
        libraryId = libraryId,
        authors = list(authors),
        narrators = list(narrators),
        publisher = publisher,
        publishYear = publishYear,
        genres = list(genres),
    )
}
