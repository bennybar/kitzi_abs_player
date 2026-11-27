package com.bennybar.kitzi.ui.settings

import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircleOutline
import androidx.compose.material.icons.filled.ArrowUpward
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FilterList
import androidx.compose.material.icons.filled.Remove
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Tune
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.FilterChip
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bennybar.kitzi.data.Services
import com.bennybar.kitzi.data.SmartShelf
import com.bennybar.kitzi.ui.UiPrefsState
import com.bennybar.kitzi.ui.common.ScreenHeader

/** Settings › Smart Shelves: saved filters shown as Home rows. */
@Composable
fun SmartShelvesScreen(onBack: () -> Unit, onEdit: (String) -> Unit) {
    val shelves by UiPrefsState.smartShelves
    val counts by produceState(emptyMap<String, Int>(), shelves) {
        val downloaded = Services.downloads.downloadedItemIds().toSet()
        value = Services.books.smartShelfBooks(shelves, downloaded).mapValues { it.value.size }
    }
    fun save(list: List<SmartShelf>) = UiPrefsState.setSmartShelves(Services.prefs, list)
    fun addShelf(p: SmartShelf) = save(shelves + p.copy(id = java.util.UUID.randomUUID().toString().uppercase()))

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(icon = Icons.Default.FilterList, title = "Smart Shelves", onBack = onBack)
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)
                .padding(bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current),
            verticalArrangement = Arrangement.spacedBy(10.dp),
        ) {
            shelves.forEachIndexed { i, shelf ->
                Surface(
                    color = MaterialTheme.colorScheme.surfaceContainer,
                    shape = RoundedCornerShape(18.dp),
                    modifier = Modifier.fillMaxWidth().clickable { onEdit(shelf.id) },
                ) {
                    Row(Modifier.padding(start = 16.dp, top = 8.dp, bottom = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Column(Modifier.weight(1f)) {
                            Text(shelf.name, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                            Text(
                                listOfNotNull(counts[shelf.id]?.let { "$it books" }, shelf.summary).joinToString(" · "),
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 2,
                                overflow = TextOverflow.Ellipsis,
                            )
                        }
                        if (i > 0) {
                            IconButton(onClick = { save(shelves.toMutableList().apply { add(i - 1, removeAt(i)) }) }) {
                                Icon(Icons.Default.ArrowUpward, "Move up")
                            }
                        }
                        IconButton(onClick = { save(shelves - shelf) }) { Icon(Icons.Default.Delete, "Remove") }
                    }
                }
            }
            Text(
                "Each one is a row on Home, after the other shelves.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
            Text("Add", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, modifier = Modifier.padding(top = 8.dp))
            SmartShelf.presets.filter { p -> shelves.none { it.name == p.name } }.forEach { p ->
                AddLine(Icons.Default.AddCircleOutline, p.name) { addShelf(p) }
            }
            AddLine(Icons.Default.Tune, "Custom…") { addShelf(SmartShelf(name = "My Shelf")) }
        }
    }
}

@Composable
private fun AddLine(icon: androidx.compose.ui.graphics.vector.ImageVector, title: String, onClick: () -> Unit) {
    Row(Modifier.fillMaxWidth().clickable(onClick = onClick).padding(vertical = 10.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, null, tint = MaterialTheme.colorScheme.primary)
        Text(title, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary, modifier = Modifier.padding(start = 12.dp))
    }
}

/** One smart shelf's rules, with how many books they find, live. */
@Composable
fun SmartShelfEditorScreen(id: String, onBack: () -> Unit) {
    val shelves by UiPrefsState.smartShelves
    val shelf = shelves.firstOrNull { it.id == id } ?: return
    fun update(f: (SmartShelf) -> SmartShelf) =
        UiPrefsState.setSmartShelves(Services.prefs, shelves.map { if (it.id == id) f(it) else it })
    val count by produceState<Int?>(null, shelf) {
        value = Services.books.smartShelfBooks(listOf(shelf), Services.downloads.downloadedItemIds().toSet())[shelf.id]?.size
    }
    val genres by produceState(emptyList<String>()) {
        value = Services.books.allAudiobooks().flatMap { it.genres }.distinct().sorted()
    }

    Column(Modifier.fillMaxSize()) {
        ScreenHeader(icon = Icons.Default.FilterList, title = shelf.name.ifBlank { "Smart Shelf" }, onBack = onBack)
        Column(
            Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp)
                .padding(bottom = 16.dp + com.bennybar.kitzi.LocalMiniPlayerInset.current),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            OutlinedTextField(shelf.name, { v -> update { it.copy(name = v) } }, label = { Text("Name") }, singleLine = true, modifier = Modifier.fillMaxWidth())
            count?.let { Text("$it books right now", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant) }

            Heading("Books")
            Choices(
                listOf("any" to "Any", "notStarted" to "Not Started", "inProgress" to "In Progress", "finished" to "Finished"),
                shelf.status,
            ) { v -> update { it.copy(status = v) } }
            SwitchLine("Shorter Than", shelf.maxHours != null) { on -> update { it.copy(maxHours = if (on) 6.0 else null) } }
            shelf.maxHours?.let { h ->
                Stepper("${h.toInt()} hours", { update { it.copy(maxHours = (h - 1).coerceAtLeast(1.0)) } }) {
                    update { it.copy(maxHours = (h + 1).coerceAtMost(60.0)) }
                }
            }
            SwitchLine("Audible Rating", shelf.minRating != null) { on -> update { it.copy(minRating = if (on) 4.5 else null) } }
            shelf.minRating?.let { r ->
                // In tenths, so 4.5 - 0.1 doesn't drift to 4.3999.
                val tenths = Math.round(r * 10)
                Stepper(String.format(java.util.Locale.US, "%.1f★ or more", r), { update { it.copy(minRating = (tenths - 1).coerceAtLeast(30) / 10.0) } }) {
                    update { it.copy(minRating = (tenths + 1).coerceAtMost(50) / 10.0) }
                }
            }
            SwitchLine("Added Recently", shelf.addedDays != null) { on -> update { it.copy(addedDays = if (on) 30 else null) } }
            shelf.addedDays?.let { d ->
                Stepper("In the last $d days", { update { it.copy(addedDays = (d - 1).coerceAtLeast(1)) } }) {
                    update { it.copy(addedDays = (d + 1).coerceAtMost(365)) }
                }
            }
            if (genres.isNotEmpty()) {
                var open by remember { mutableStateOf(false) }
                Box {
                    Row(Modifier.fillMaxWidth().clickable { open = true }.padding(vertical = 10.dp)) {
                        Text("Genre", style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
                        Text(shelf.genre ?: "Any", style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.primary)
                    }
                    DropdownMenu(open, onDismissRequest = { open = false }) {
                        (listOf<String?>(null) + genres).forEach { g ->
                            DropdownMenuItem(text = { Text(g ?: "Any") }, onClick = { open = false; update { it.copy(genre = g) } })
                        }
                    }
                }
            }
            SwitchLine("Only Series I've Started", shelf.mySeries) { on -> update { it.copy(mySeries = on) } }
            SwitchLine("Only Downloaded", shelf.downloaded) { on -> update { it.copy(downloaded = on) } }

            Heading("Order")
            Choices(
                listOf("added" to "Newest First", "shortest" to "Shortest First", "rating" to "Best Rated First", "title" to "By Title"),
                shelf.sort,
            ) { v -> update { it.copy(sort = v) } }
            Text(
                "Ratings come from Audible, for books it has been asked about (the library's Highest rated sort fills in the rest).",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
private fun Heading(text: String) {
    Text(text, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold, color = MaterialTheme.colorScheme.primary,
        modifier = Modifier.padding(top = 12.dp))
}

@Composable
private fun Choices(options: List<Pair<String, String>>, selected: String, onSelect: (String) -> Unit) {
    Row(Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        options.forEach { (value, label) -> FilterChip(selected = selected == value, onClick = { onSelect(value) }, label = { Text(label) }) }
    }
}

@Composable
private fun SwitchLine(title: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth().clickable { onChange(!checked) }.padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = MaterialTheme.typography.bodyLarge, modifier = Modifier.weight(1f))
        Switch(checked, onChange)
    }
}

@Composable
private fun Stepper(text: String, onMinus: () -> Unit, onPlus: () -> Unit) {
    Row(Modifier.fillMaxWidth().padding(start = 16.dp), verticalAlignment = Alignment.CenterVertically) {
        Text(text, style = MaterialTheme.typography.bodyLarge, color = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.weight(1f))
        IconButton(onClick = onMinus) { Icon(Icons.Default.Remove, "Less") }
        IconButton(onClick = onPlus) { Icon(Icons.Default.Add, "More") }
    }
}
