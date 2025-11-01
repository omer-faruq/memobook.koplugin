# MemoBook Plugin 
Your personal in-book memo and self-dictionary.

## Purpose
MemoBook lets you capture bite-sized notes tied to words or phrases while reading. Every memo is stored in a local SQLite database and scoped to the document you were reading, but you can also browse everything from a global view. Use it to build glossaries, track recurring terms across series, or collect study notes without leaving KOReader.

## Access Points & Controls
MemoBook surfaces a "Memo" button in several places so you can jot things down from whichever workflow feels natural:

### Dictionary popup
- **Tap `Memo`** to save the current lookup term or highlighted selection as a memo. If both are available you will be prompted to keep the dictionary term as an alias.
- **Hold `Memo`** to open the Memo list dialog for the active document without closing your lookup flow.

### Highlight popup
- **Tap `Memo`** after selecting text in the reader. The highlight popup closes, the selection is cleared, and the Memo editor opens with the selected text ready to annotate.

### Reader top menu (while a document is open)
- **`Memo Book` entry** opens the memo list filtered to the current document. From here you can:
  - Browse memo groups (one group per primary tag).
  - Tap a memo to reopen or edit its notes.
  - Hold a memo to view details, open it directly, or delete the group.
  - Use the sticky controls at the top to search tags/aliases, clear filters, export all memos for the book to JSON, or close the dialog.

### Main menu (outside any document)
- The same **`Memo Book`** entry opens a global view across every document. Each row shows the primary tag plus its document display name, so you can review or edit notes without loading a book first.

## Working with Alias names
An *alias* is an alternate tag that points to the same memo group. Aliases are useful when:
- A dictionary lookup returns a canonical headword that differs from the text you highlighted.
- You want different spellings, declensions, or translations to share a single memo history.

From the Memo pop-up you can add or remove aliases using the dedicated buttons. When adding a memo from the dictionary pop-up, MemoBook automatically suggests the lookup word as an initial alias whenever it differs from your selection.

## Understanding `document_map.json`
MemoBook identifies documents by their file paths. If you keep multiple versions of the same work (for example, EPUB vs. PDF, different language editions, or related titles in a series), you can tell MemoBook to treat them as the same identity:

1. Create or edit `document_map.json`.
2. Place it either in the plugin folder (`plugins/memobook.koplugin/`) or in the user data folder (`<data>/memobook/`). The data copy overrides the bundled one.
3. List related paths together. You can find the **full path** of a book by using the top menu > Memo Book > long-press an item > details pop-up. The example below shows two separate groups that have two related books in them:
   ```json
   {
     "groups": [
       ["/mnt/onboard/books/Foo.epub", "/mnt/onboard/books/Foo2.epub"],
       ["/mnt/onboard/books/Bar.epub", "/mnt/onboard/books/Bar2.epub"]
     ]
   }
   ```
With this map in place, memos created in any listed file appear together regardless of which version you open.

## Data location & export
- Memos live in `memobook.sqlite` inside the KOReader data directory, managed automatically by the plugin.
- Use the **`Export JSON`** control in the Memo list dialog to save all memos for the current document (or the global view) to a portable JSON file. MemoBook creates the destination folders for you when possible.

## Tips
1. Use aliases to keep pronunciation, translation, and headword variations together.
2. Filter the list dialog with partial words to quickly locate a memo in longer collections.

## Credits
MemoBook was created with help from Windsurf (AI).
