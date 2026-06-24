# Downloads & Bulk Actions

`kokomga` lets you download your books and comics directly from your Komga server. It automates file naming, folder layouts, metadata injection, and directory synchronization inside KOReader.

---

## Download Destination & Directory Structure

When downloading a book, the plugin structures the files beautifully to match typical library formats:

1. **Base Directory**: By default, downloads go to your KOReader **Home Directory**. You can override this under `kokomga` Settings -> **Custom Download Directory** to choose a specific folder (e.g., `/sdcard/Books/Komga/`).
2. **Subfolder Organization**: If the **Download to Subfolder** setting is enabled (default: true), the plugin automatically creates a subfolder named after the book's series:
   ```text
   Download Directory/
   └── [Series Title]/
       ├── Book 1.cbz
       └── Book 2.cbz
   ```
3. **File Naming & Extension Mapping**: Filenames are cleaned of restricted symbols (like `/ \ : * ? " < > |`) to ensure system compatibility. The file extension is dynamically mapped based on the server media MIME-type (e.g., `application/epub+zip` maps to `.epub`, `application/pdf` to `.pdf`, zip formats to `.cbz`, rar formats to `.cbr`).

---

## Series Cover Art Download

To enrich KOReader's native cover browser experiences, the plugin includes a built-in cover saver:
* When a book is downloaded to a series subfolder, the plugin checks if a folder cover image is already present in that directory.
* If no cover exists (e.g., no `.cover.jpg` or `.cover.png`), it requests the raw series thumbnail from Komga (`/api/v1/series/{id}/thumbnail`).
* It automatically detects the image format from the stream headers (`PNG`, `JPEG`, `WEBP`, or `GIF`) and saves the image to the folder as a hidden file (e.g., `.cover.jpg`).
* This enables KOReader's **CoverBrowser** plugin to automatically render the folder cover preview when browsing your local file manager.

---

## Auto-Populating Document Metadata

Immediately upon successful download, `kokomga` extracts the complete book and series metadata from Komga and injects it directly into KOReader's local document sidecar file (`.sdr`). 
This populates:
* **Title & Summary/Description**
* **Series Title & Series Index (Volume/Number)**
* **Authors (Writers, Pencillers, Editors, etc.)**

This ensures that when you open the file locally, KOReader is already aware of its rich metadata without needing to read embedded file tags.

---

## Bulk Download Actions

By **long-pressing (holding)** any book item in the browser catalog, or using selection overlays, you can activate the **Bulk Download Menu**:

1. **Download Selected**: If you have manually selected multiple books, you can download only your selected queue.
2. **Download Remaining Books on this Page**:
   * Instead of downloading the entire server catalog or all previously fetched records, this option computes your exact pagination coordinates:
     ```lua
     local start_idx = math.max(1, (page_num - 1) * p.page_size + 1)
     local end_idx = math.min(#self.item_table, page_num * p.page_size)
     ```
   * It scans only the books within this index range.
   * **Duplication Filtering**: The plugin automatically skips any books that have already been fully downloaded, showing a contextual menu label (e.g., "Download remaining 3 books on this page") and downloading them sequentially in the background.
