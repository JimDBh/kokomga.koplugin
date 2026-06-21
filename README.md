# KOReader Komga Client Plugin (kokomga)

A KOReader plugin that connects to your Komga server. It provides a native library browser to check komga catalog and download, and keeps your reading progress synchronized. It also provides useful quality-of-life improvements like auto-next-chapter, auto RTL, etc.

## Highlights

1. **Browse Komga Catalog:** View libraries, series, recently added, and on-deck books with cover thumbnails, layout adjustments (list/grid modes), read status filters, and direct downloads.
2. **Metadata Extraction:** Upon downloading, automatically retrieves comic and book metadata (title, summary, authors, series index) from the Komga server and populates KOReader's document settings.
3. **Next Chapter Flow:** Prompts at the end of a book to check the server for the next chapter. If it is already downloaded, it opens it; if not, it automatically downloads and opens it.
4. **Integrated Progress Sync:** Integrations into the default KOReader sync (`kosync`) to intercept get/update progress events and sync directly with the Komga server for matched books.
5. **Auto RTL:** An option to automatically toggle reading direction to Right-to-Left (RTL) upon opening any book that are from Komga.

---

## Installation
Download and copy the `kokomga.koplugin` folder to the KOReader `plugins/` directory.

---

## Configuration & Usage
1. Open KOReader's top menu.
2. Go to the **Search tab** (magnifying glass icon) -> **kokomga**.
3. Open **Komga Browser**. If you have not configured it, you will be prompted:
   * **Auto-Generate API Key:** Enter your Server URL, Username, and Password to auto generate the API key (credentials are not stored).
   * **Manual Setup:** Manually type in your Server URL and API Key.
4. Once connected, your books will synchronize progress in the background as you read, and you can download files directly from your catalog.

---

## Screenshots

*(Note: The screenshots below are for reference and may not exactly reflect the newest version)*

* **Browser Grid View**

  ![Browser Grid View](screenshots/browser_grid.png)

* **Browser List View**

  ![Browser List View](screenshots/browser_list.png)

* **Setup & Settings**

  ![Options & Setup](screenshots/options_screenshot.png)

* **Auto-Download Next Chapter**

  ![Auto-Download Next Chapter](screenshots/auto_download_next.png)


