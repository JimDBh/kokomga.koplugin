# Browser & Catalog User Interface

`kokomga` features a native, responsive e-ink friendly catalog browser. It maps directly onto KOReader's widget systems and adapts dynamically to your preferences.

---

## Accessing the Browser

To open the catalog browser:
1. Tap the top menu of KOReader and select the **Search Tab** (magnifying glass icon).
2. Tap **`kokomga`** -> **Komga Browser**.
3. Once loaded, you will see your primary Komga entry points:
   * **Libraries**: Explore items organized by your Komga libraries.
   * **Recently Added**: Check books and series that were recently indexed on the server.
   * **On Deck**: Instantly view the next unread books in the series you are currently reading.

---

## Layout Presentation Modes

The browser can toggle between two primary visual layout modes: **List View** and **Grid View**.

### 1. List View
* Displays items as sequential rows with title, series details, reading progress information, and a thumbnail cover.
* **Layout parameters**: Spacing is designed for readability with elegant horizontal padding on the left and right, and clear, distinct row separator lines (`COLOR_GRAY`) that scale with your device's DPI.
* **Items per page**: Managed by the `list_rows` setting (default: 5 rows per page).

### 2. Grid View
* Displays items in a clean multi-column grid of book covers, showing text overlays at the bottom of each cover cell.
* **Items per page**: Calculated dynamically as `grid_columns` × `grid_rows` (default: 3 × 3 = 9 items per page).

### Switching Layouts
You can toggle between List and Grid view at any time from the catalog:
1. Tap the **Menu Button** (three horizontal lines icon) on the top-left of the browser title bar.
2. Select **Switch to List View** or **Switch to Grid View**.
3. The layout and pagination size will recalculate immediately.

---

## Reading Progress & Status Indicators

The browser renders visual indicators directly on the cover thumbnails to help you keep track of your library status at a glance without making unnecessary clicks:

1. **Local Download Status (`↓`)**: 
   * A small down-arrow overlay appears on the cover if the book file has already been downloaded to your device, signaling that it can be opened instantly offline.
2. **Reading Status Labels**:
   * **`New`**: Overlay indicating the book has 0% progress on the server.
   * **`Done`**: Overlay indicating the book is fully read (100%).
   * **Page Tracker** (e.g., `45 / 120` or `Page 50`): Shows your current page and total pages as recorded by the server.

---

## Filtering and Pagination

* **Read Status Filter**: Under the browser options, you can filter your lists by reading status:
  * Show All
  * Show Unread
  * Show In Progress
  * Show Read
* **Pagination**: Interactive pagination buttons (Previous Page / Next Page) are present at the bottom of the screen. Page-size calculation guarantees that no item is cut off:
  ```lua
  -- The pagination size is determined by the current display mode's capacity:
  local page_size = self:getPageSize(args.cover_type ~= nil)
  ```
