# Changelog

## 0.2.0 to 0.2.5 - 2026-10-11
### New
- A new full-screen look. The bars hide by themselves and come back when you move the pointer to the edge. The bottom bar has 11 buttons.
- Pins on the panels. A pinned panel stays open. The Unpin All Panels command lets them all go at once.
- Toolbar buttons for Full Screen, Show in Browser and Histogram.
- RAW and JPEG switch: when a RAW file and its JPEG show as one photo, press Option+R to see the other one.
- Filmstrip hover: the photo under the pointer gets a white ring, a hand cursor and its file name.
- The Browser has a Filmstrip view with a big preview. Grid, Filmstrip or List: Shrike remembers your choice.
- The histogram can be turned on or off in every window. It shows the share of clipped pixels at both ends.
- The Browser follows the photo you select in the viewer, also when you select a range with Shift+arrow.
- A disabled tool on the edit bar now says why in its tooltip.
- The photo number badge hides by itself after 2 seconds. It comes back when you move the pointer.
- Toolbar buttons now light up clearly when you point at them, in the viewer and in the Browser (macOS 26). A group such as Previous / Next lights one button at a time.
### Changed
- The mouse wheel moves one photo per click in the viewer. In the Browser grid the wheel scrolls a third of a row per click.
- In a Browser window that is too small, the viewer opens at 1200 by 800 points.
- The Recent list skips folders that no longer exist.
### Fixed
- The edit tool buttons act on the tool you picked.
- In edit mode, Done and Apply now use the same blue as the toolbar.
- The arrow keys work right after you open a folder. The first photo is selected there, also when the folder is sorted by date taken: it is the first one you see, not the first one by name.
- After you used Share, its button no longer stays lit.
- The default button of a sheet or panel (Rename, Go to Folder, Slideshow, Contact Sheet, Apply) has a dark label when your accent colour is a light one, such as Yellow.
- In full screen the bars come back when you move the mouse.
- The photo counter was cut off when the folder was short or the window was narrow.
- A grey band showed under the title bar after it hid.
- The info panel was empty when it opened a certain way. It follows the RAW or JPEG you see.
- Photos you deleted stayed in the filmstrip and in the Browser.
- The preview and the info panel blinked when you moved from one photo to the next.
- A toast message could sit on top of the zoom label.
- The Browser window changed size when you switched the view or when photos loaded.
- A click in the grid or the filmstrip now selects only that photo.
- The filmstrip keeps the selected photo in the middle when the panel opens or closes, and the strip no longer cuts file names.
- Shift+click and Shift+arrow ranges keep the moving end in view.
- The histogram close button no longer steals the keyboard focus from the photo.

## 0.1 - 2026-10-10
### New
- First public release.
- Move through photos with Space or the arrow keys. Shrike prepares the next photos before you ask.
- Zoom with a pinch, pan by dragging, hold Z for a loupe, press A for 100 % and B to fit the window.
- Browse a whole folder as a grid, a list or a filmstrip. Names sort naturally, so IMG_2 comes before IMG_10.
- Rate with 1 to 5, flag with Q and add Finder tags. Copy, move, rename or trash from the keyboard, with undo.
- A RAW file and its JPEG show as one photo.
- An info panel with EXIF and a histogram. Open the photo's place in Apple Maps when it has GPS.
- Compare up to 4 photos side by side, with zoom and pan in sync.
- Light edits: crop, rotate, resize, colour and levels. Shrike keeps a copy of the original.
- Batch convert, resize and rename with templates. Print a photo or make a contact sheet.
- A slideshow with timing, fade or dissolve, random order and loop.
- A FastStone-style shortcut preset for people who come from Windows.
