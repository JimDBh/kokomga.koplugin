# Komga Plugin TODO

## Authentication & Network
- [ ] Auto generate API key and save in settings
- [ ] Prompt for Wi-Fi connection when using network

## Menu & Navigation
- [x] Remove non-browser menu
- [x] Move menu to the search menu
- [x] Increase the size of the hamburger icon

## Browser & UI Features
- [ ] Bulk download directly in the browser
- [ ] Sort/Select what content to include in the browser
- [ ] Filter options should be checkboxes (e.g., allow selecting both 'unread' + 'in progress')
- [x] No-cover list mode: customize row height. Try to use list height, but prioritize fitting everything on one page.

## Reading & Sync Behavior
- [ ] Auto-set reading direction to "Right to Left" when opening a file
- [ ] Inhibit regular KOReader progress sync for Komga books:
  - On open document: if it has a Komga ID, turn off regular auto-progress sync. Otherwise, respect the user's default setting.
- [ ] Add functionality to match existing side-loaded files to Komga IDs

## Plugin Infrastructure
- [x] Create `_meta.lua` file for plugin metadata
- [ ] Implement i18n (Internationalization) support
