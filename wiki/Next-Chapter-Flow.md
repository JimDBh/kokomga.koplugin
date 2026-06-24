# Next Chapter Flow

To make reading series and episodic manga as seamless as possible, `kokomga` implements an automated end-of-book transition known as the **Next Chapter Flow**.

## How It Works

When you reach the last page of a book or comic and attempt to turn the page, KOReader triggers an `onEndOfBook` event. `kokomga` intercepts this event and executes the following sequence:

1. **Check for Next Book**: The plugin makes an asynchronous API call to your Komga server's "next book" endpoint:
   ```text
   GET /api/v1/books/{id}/next
   ```
2. **Evaluate Availability**:
   * **If the next book is already downloaded locally**: The plugin bypasses standard reader exit prompts and shows a responsive dialog asking if you want to **Open Next Chapter** immediately. If accepted, KOReader loads the next file directly without taking you back to the file manager.
   * **If the next book is NOT downloaded**: A dialog pops up offering to **Download & Open** the next chapter.
     * If you select download, the plugin downloads the file in the background, writes the book and series metadata to its sidecar (`.sdr`) file, and automatically launches the newly acquired document when finished.
3. **Handle Series Completion**: If there is no subsequent book (e.g., you are on the latest volume of the series), the plugin simply lets KOReader show its default end-of-document action.

---

## Auto-Marking as Completed

The Next Chapter Flow respects KOReader's native reading settings:
* Under KOReader's settings, you can toggle **Auto mark completed on end of book**.
* If enabled, `kokomga` automatically transmits a request to mark the finished book's status as **Read** (100% progress) on your Komga server.
