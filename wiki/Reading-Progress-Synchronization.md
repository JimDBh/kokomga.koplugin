# Reading Progress Synchronization & Next Chapter Flow

Keeping your reading progress in sync between your portable reader and your Komga home server is a primary feature of `kokomga`. The plugin implements high-performance matching, intercepts KOReader’s native sync systems, caches offline changes, and handles end-of-book transitions.

---

## 1. Book Matching Engine

To synchronize progress, local files must be linked to their counterparts on your Komga server. 
* **Automatic Matching**: When you open any book, the plugin retrieves its filename and immediate parent directory name. It strips typical reader extensions (`.epub`, `.pdf`, `.cbz`, etc.) and queries Komga’s API.
* **Hierarchical Match**: It attempts to match both the book name and series title against your parent folder structure (hierarchical matching) to prevent mismatches in files with generic titles (e.g., "Volume 1").
* **Settings Cache**: Successful matches are written directly to `matched_books_cache` in your global settings and saved inside the book's `.sdr` directory (`komga_book_id = "[ID]"`) so that matching is a one-time operation.
* **Manual Match**: If a book does not link automatically, you can trigger a manual lookup by clicking **Manual Match** inside the `kokomga` settings menu.

---

## 2. KOReader `kosync` Interception

If KOReader’s native progress synchronization plugin (`kosync`) is active, `kokomga` automatically hooks into it to provide native integration:
* **getProgress Interception**: When a book is opened, the plugin intercepts the `kosync:getProgress` call. If your device is online and the book is linked to Komga, it fetches the server progress. If the server is ahead or behind, it prompts you to jump or updates silently based on your configuration.
* **updateProgress Interception**: On suspending, page-marking, or closing, it intercepts the `kosync:updateProgress` call and transmits your updated page count directly to Komga first.
* **Fallback Safety**: If you are offline, if a book has not been matched, or if a network request fails, the hooks immediately hand control back to KOReader's native `kosync` server, ensuring your progress is still safely queued or synced with your primary KOReader progress server.

---

## 3. Periodic Background Sync & Offline Caching

* **Page Interval Sync**: To prevent constant battery-draining network requests on every page turn, the plugin implements a configurable interval:
  * **`sync_interval_pages`** (default: 5 pages).
  * As you turn pages, progress is only pushed to the server when you have read `N` pages since the last sync.
* **Offline State Handling**: If you are reading offline (e.g., traveling without Wi-Fi):
  * The plugin flags your local progress as **dirty**.
  * When you reconnect to Wi-Fi, the next network event triggers a silent, automatic progress sync (`onNetworkConnected`), updating your Komga server instantly.

---

## 4. End-of-Book "Next Chapter" Flow

When you reach the final page of a book or comic, `kokomga` replaces standard reader alerts with a seamless series transition:
1. It requests the next book in the series directly from Komga's `/api/v1/books/{id}/next` endpoint.
2. **If found and already downloaded**: It pops up a responsive dialog offering to **Open Next Chapter** instantly.
3. **If found but not downloaded**: It offers to **Download & Open** the next chapter. If you accept, it downloads the file in the background, applies document metadata, and loads the new document directly.
4. **Auto-Mark Completed**: The flow fully respects KOReader's native `end_document_auto_mark` setting. If enabled, the plugin automatically marks the completed book's progress as 100% read on your Komga server.

---

## 5. Auto Right-To-Left (RTL) Direction

For manga and some comic formats, opening a book with the wrong pagination swipe direction can be annoying. 
* If **`auto_rtl_direction`** is enabled in the settings, the plugin checks if the opened book belongs to your Komga server.
* If matched, it automatically forces the reader's reading order to **Right-To-Left (RTL)** and updates your local document settings so you can begin reading immediately in the correct layout.
