# Komga Plugin TODO

## Authentication & Network
- [x] Prompt if server url / apikey is not set
- [x] Auto generate API key and save in settings
- [x] Prompt for Wi-Fi connection for komga browser

## Menu & Navigation
- [x] Remove non-browser menu
- [x] Move menu to the search menu
- [x] Increase the size of the hamburger icon

## Browser & UI Features
- [ ] Bulk download directly in the browser
- [ ] Sort/Select what content to include in the browser
- [x] Filter options should be checkboxes (e.g., allow selecting both 'unread' + 'in progress')
- [x] No-cover list mode: customize row height. Try to use list height, but prioritize fitting everything on one page.

## Reading & Sync Behavior
- [x] Auto-set reading direction to "Right to Left" when opening a file
- [x] Inhibit regular KOReader progress sync for Komga books
- [ ] Add functionality to match existing side-loaded files to Komga IDs

## Plugin Infrastructure
- [x] Create `_meta.lua` file for plugin metadata
- [ ] Implement i18n (Internationalization) support

## API & Data
- [ ] `match_book` falls back to `content[1]` on no match — can return wrong book (false positive)
- [x] Remove hardcoded `size=` caps on all list endpoints (was 50–100)
- [x] Implement server-side lazy pagination for browser views (fetch on next-page tap)
