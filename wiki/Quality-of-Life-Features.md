# Quality of Life Features

`kokomga` goes beyond basic synchronization by providing dedicated configuration options designed to enhance e-ink reading ergonomics, optimize network/battery usage, and keep the user interface running smoothly.

---

## 1. Auto Right-To-Left (RTL) Direction

For manga and other right-to-left comic layouts, starting a book with the standard left-to-right swipe/tap direction can be disruptive.

### How it works:
* When **`auto_rtl_direction`** is enabled in the settings menu, `kokomga` monitors every document open event.
* If the opened book is linked to a book on your Komga server, the plugin automatically toggles the reading direction:
  ```lua
  ui.view:onToggleReadingOrder(true)
  ```
* To prevent you from having to set it again on subsequent opens, it saves this layout preference straight into KOReader's local document sidecar file (`.sdr` settings):
  ```lua
  ui.doc_settings:saveSetting("inverse_reading_order", true)
  ```
  Now you can start reading right-to-left instantly.

---

## 2. Image Caching and "Clean Cache"

To preserve battery and render the catalog browser quickly over E-Ink displays, `kokomga` caches downloaded cover thumbnails locally in your device's data directory (specifically inside a folder named `komga_covers/`).

### Cache Modification Tracking:
The plugin tracks whether cached covers on your device match the server using the `lastModified` timestamp from the Komga API. 
```lua
if self.plugin.settings.never_update_covers or cache.covers[cache_key] == lastModifiedString then
    return local_path -- Use cached version instantly!
end
```

### The "Clean Cache" Option:
If you have updated series cover art on your server and want to force KOReader to reload them, you can use the **Clean Cache** option found in the `kokomga` Settings menu.

* **What it does**: It wipes all recorded cover timestamp/modification metadata stamps in the plugin settings (`self.plugin.settings.library_metadata_cache = {}`) and saves the fresh structure.
* **Result**: On your next catalog browse, the plugin detects that all cached cover images are untracked, prompting it to download the latest cover thumbnails from the server, cleanly updating your local display.

---

## 3. Bandwidth Optimization Settings

* **Cache Covers**: Toggle whether covers are downloaded in the browser at all. Disabling this displays a lightweight text-only list browser, saving bandwidth and rendering pages near-instantly on extremely slow connections.
* **Never Update Cached Covers**: When active, the plugin bypasses checking the server's modification timestamps. It will always reuse the locally stored cover image if it exists on disk, significantly speeding up list loading and eliminating redundant server requests.
