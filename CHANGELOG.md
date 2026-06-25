# Changelog

All notable changes to the KOReader Komga Client Plugin will be documented in this file.

## [Unreleased]

## [2.0.0] - 2026-06-24

### Added
- **Manual Book Matching & Side-loading**:
  - Added support to manually match side-loaded books to Komga IDs with local fallback metadata support.
- **Bulk Download in Browser**:
  - Selection gesture on book items (tap to toggle selection with checkmark overlays directly on cover images).
  - Contextual menu triggered by holding any book item to view download options (long-press is ignored for non-book entries).
  - Clear, simplified options to download selected books, download all books on the current page, or cancel (excluding duplicate/already downloaded books seamlessly).
- **Aesthetic Cover Indicators**:
  - Added visual indicators for local download status ("↓") on both list and grid item covers.
  - Implemented real-time reading progress indicators ("New", "Done", page/total pages, or raw page count) for list and grid views in the browser catalog.
- **Series Title Omission**:
  - Omitted prepending the series name from book titles when browsing books within a specific series since the series title is already displayed as the main title bar header.
  - Retained the series name prefix in multi-series lists (e.g. "Keep Reading", "On Deck", "Recently Added Books") for proper context.
- **Series Cover Image Download**:
  - Automatically downloads the series cover art (`.cover.<ext>`) to the series subdirectory on successful book download if no series cover is present, enabling folder-level cover previews in KOReader's coverbrowser.
- **Improved List Mode UI Layout**:
  - Made the list-mode separator lines significantly more distinct by changing the color to a darker mid-gray (`COLOR_GRAY`) and dynamically scaling the line height (`delimiter_h`) based on the device's screen scale factor.
  - Added wider, more balanced horizontal padding (left and right) on list view rows to give them elegant margins and breathe better on a wider variety of display devices.
- **Multi-language Localization**:
  - Added complete localization dictionaries for Traditional Chinese (`zh_TW`/`zh_HK`), Japanese (`ja`), and Spanish (`es`).

### Fixed
- **Memory Safety & Mutex Crash Prevention**:
  - Re-architected item layout rendering to avoid calling native `:getSize()` on un-parented `TextWidget` instances, eliminating the intermittent Freetype-related "pthread_mutex_lock called on a destroyed mutex" crash in KOReader.
  - Eliminated custom manual memory/badge tracking and destruction logic in favor of KOReader's native garbage collector and widget parenting lifecycle.
- **Robust Type Checking**:
  - Added defensive type verification (`type(...) == "table"`) on both `book` entries and `readProgress` objects to prevent the runtime error "attempt to index local 'readProgress' (a function value)".
- **Selection State on Coverless Books**:
  - Fixed book selection state checkmark rendering on coverless books in list/grid browser views.
- **File Locks on Download Failure**:
  - Ensured download file handles are always closed to prevent file access locks on Windows when downloads fail.
- **KOSync Settings Integration**:
  - Aligned syncing actions to depend purely on native KOSync configuration state. Removed redundant custom sync interval options, background progress push loops, and offline Wi-Fi connection prompt warnings.
- **Dead Code & Import Cleanup**:
  - Removed multiple unused local variables, duplicate imports, and obsolete helper functions (`sanitize_for_settings`, custom recursive folder creation, etc.) to optimize the plugin's memory footprint.

---

## [1.0.0] - 2026-06-21

### Added
- **Authentication & Network Configuration**:
  - Automatic prompts to configure Server URL and API Key upon first startup.
  - Auto-generation of API keys using temporary Username/Password entry (credentials are not stored).
  - Interactive prompts to enable Wi-Fi connection if inactive when launching the browser.
- **Optimized Menu & Navigation Integration**:
  - Integrated the kokomga entry point into KOReader's search menu under "kokomga".
  - Cleaned up obsolete standalone and non-browser menus.
  - Increased hamburger icon size for better touch targeting on e-ink devices.
- **Enhanced Browser Layouts & Filtering**:
  - Re-implemented search and browse filters as checkboxes, allowing combination filters (e.g., "unread" and "in progress" together).
  - Implemented a coverless list view option with row height optimization to maximize single-page content.
- **Progress Synchronization & Behavior**:
  - Custom intercept of KOReader's native `kosync` to bypass standard synchronization and sync progress directly with the Komga server for matched books.
  - Added a configuration toggle to automatically set the reading direction to Right-to-Left (RTL) when opening books.
- **Performance & API Updates**:
  - Removed hardcoded cap restrictions (size 50-100) on list endpoints.
  - Integrated lazy, server-side paginated loading for browsing libraries and series.
- **Plugin Localization & Standards**:
  - Created standard `_meta.lua` metadata configuration.
  - Implemented system-wide i18n support.
