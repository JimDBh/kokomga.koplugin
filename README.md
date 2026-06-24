# KOReader Komga Client Plugin (kokomga)

A KOReader plugin that connects to your Komga server. It provides a native library browser to check komga catalog and download, and keeps your reading progress synchronized. It also provides useful quality-of-life improvements like auto-next-chapter, auto RTL, etc.

## Highlights

1. **Browse Komga Catalog:** View libraries, series, recently added, and on-deck books with cover thumbnails, layout adjustments (list/grid modes), read status filters, and direct downloads.
2. **Metadata Extraction:** Upon downloading, automatically retrieves comic and book metadata (title, summary, authors, series index) from the Komga server and populates KOReader's document settings.
3. **Next Chapter Flow:** Prompts at the end of a book to check the server for the next chapter. If it is already downloaded, it opens it; if not, it automatically downloads and opens it.
4. **Integrated Progress Sync:** Integrations into the default KOReader sync (`kosync`) to intercept get/update progress events and sync directly with the Komga server for matched books.
5. **Auto RTL:** An option to automatically toggle reading direction to Right-to-Left (RTL) upon opening any book that are from Komga.

---

## Documentation & Wiki

For detailed guides, configuration help, and deep-dives into the plugin's features, check out our **Wiki Pages**:

* [**Wiki Home**](wiki/Home.md) — Comprehensive overview of the plugin's components and architecture.
* [**Installation Guide**](wiki/Installation.md) — Step-by-step instructions to get the plugin up and running on any KOReader device.
* [**Authentication & Server Setup**](wiki/Authentication.md) — How to securely connect KOReader with your Komga server (automatic API Key generation or manual setups).
* [**Browser & Catalog UI**](wiki/Browser-UI.md) — Customizing list/grid views, pagination, and E-Ink status indicators.
* [**Downloads & Bulk Actions**](wiki/Downloads-and-Bulk-Actions.md) — Custom download paths, automatic series cover art retrieval, metadata populating, and page-based bulk downloading.
* [**Reading Progress Sync**](wiki/Reading-Progress-Synchronization.md) — Real-time progress synchronization, `kosync` integration, and offline caching.
* [**Next Chapter Flow**](wiki/Next-Chapter-Flow.md) — Seamless end-of-book transitions and next chapter fetch/download triggers.
* [**Quality of Life Features**](wiki/Quality-of-Life-Features.md) — Auto Right-to-Left (RTL) reading order, cover caching control, and the "Clean Cache" tool.

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


