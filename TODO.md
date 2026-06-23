# Komga Plugin TODO

## Visuals, Styling and E-Ink Optimizations
- [ ] Add border/boundary to book/comic covers (adaptive black or white border depending on night/dark mode)
- [ ] Improve list mode design: make separators/lines more distinct (the default line is too faint) and add horizontal padding (left and right)
- [ ] Display the active filter status in the top title bar using short indicators, light highlights, icons, or emojis

## Metadata and Status Display in Browser
- [ ] Show more metadata in list view (e.g., authors, etc.) and optionally in grid view
- [ ] Display reading progress / percentage indicator on the cover (grid) and items (list) in the browser
- [ ] Add a visual indicator in the browser to show if a book is already downloaded locally
- [ ] For series, show a completion banner or text status indicating reading progress (e.g., "X/N books read")
- [ ] Omit the series name from chapter/book names in the browser/reader list since it is already shown in the top title

## File Management and Downloading
- [x] Bulk download directly in the browser
- [ ] Add `.cover.jpg` (series cover image) to the downloaded series folder

## Catalog Filtering and Settings
- [ ] Sort/Select what content to include in the browser

## Sync and Core Functionality
- [ ] Add functionality to match existing side-loaded files to Komga IDs
- [ ] `match_book` falls back to `content[1]` on no match — can return wrong book (false positive)
