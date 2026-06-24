# Reading Progress Synchronization

Keeping your reading progress in sync between your portable reader and your Komga home server is a primary feature of `kokomga`. The plugin implements efficient progress transmission, intercepts KOReader’s native sync systems, and caches offline updates.

---

## 1. How Book Linking Works

Unlike generic sync plugins that attempt to guess matches in the background (which can trigger network spam and false positives), `kokomga` uses a deliberate and reliable linking model:

* **Automatic Linking on Download**: Any book downloaded directly through the `kokomga` catalog browser has its server Book ID instantly written to KOReader's document sidecar file (`.sdr` settings) as `komga_book_id`. It is also stored in the global settings match cache. This ensures the book is permanently and correctly linked to your Komga server.
* **Manual Match**: For books that you copy to your device manually (e.g., via USB), you can explicitly link them:
  1. Open the book in KOReader.
  2. Open the KOReader menu -> **`kokomga`** -> **Manual Match**.
  3. The plugin will query Komga using the current filename and parent directory name to establish a secure link.
* **No Unsolicited Guessing**: If a book has not been downloaded via the plugin or manually matched, `kokomga` remains dormant for that book. It does not run background searching routines, keeping your device's battery usage to a minimum.

---

## 2. KOReader `kosync` Interception

If KOReader’s native progress synchronization plugin (`kosync`) is active, `kokomga` hooks into it to provide deep, native integration:

* **`getProgress` Interception**: When a book is opened, the plugin intercepts the `kosync:getProgress` call. If your device is online and the book is linked to Komga, it fetches progress directly from the server. If the server has a different progress state, KOReader prompts you to sync or updates silently.
* **`updateProgress` Interception**: On suspending, page-marking, or closing, it intercepts the `kosync:updateProgress` call and transmits your updated page count to Komga first.
* **Fallback Safety**: If you are offline, if a book has not been matched, or if a network request fails, the hooks immediately hand control back to KOReader's native `kosync` server, ensuring your progress is still safely queued or synced with your primary progress server.

---

## 3. Periodic Progress Updates & Offline Caching

* **Page Interval Sync**: To prevent constant battery-draining network requests on every single page turn, progress is sent based on a page count interval:
  * **`sync_interval_pages`** (default: 5 pages).
  * As you read, progress is only pushed to the server when you have read `N` pages since the last sync.
* **Offline Caching**: If you are reading offline (e.g., traveling without Wi-Fi):
  * The plugin flags your local progress as **dirty**.
  * When you reconnect to Wi-Fi, the next network event triggers a silent, automatic progress sync (`onNetworkConnected`), updating your Komga server instantly.
