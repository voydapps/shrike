# Changelog

## 0.2.10 to 0.2.11 - 2026-10-13
### Changed
- The mouse wheel keeps every notch, also when you spin it fast. Before, a quick spin could skip photos.
- The wheel with Cmd (or Option) zooms in smaller steps: 12 % for each notch. A short two-finger move with Cmd zooms about 25 %. Before, a few turns took the zoom from 25 % to 1600 %.
- The chosen tool in the edit bar is easier to see: a stronger blue with a thin ring. This holds in full screen too.
- In the shortcut list, the Esc line now reads "Exit Full Screen, Return to Browser, or Close". With no Browser open, Esc closes the viewer.
### Fixed
- In the shortcut list, searching no longer loses the Cmd sign. "Zoom In" and "Zoom Out" keep their real keys while you type.
- The search box in the shortcut list takes your typing the moment the window opens, also when you open it again.
- A window that gets narrower while you edit becomes wide enough again, so the tool panel never covers half of the photo.
- The photo is always fitted to the window when you start editing and when you stop, also after a trip through full screen. Before, it could stay zoomed in and run under the tool panel until you pressed Cmd 0.
- A photo that can't be opened no longer shows the photo before it behind the message.
- In a folder where the first photos can't be opened, the mouse wheel moves to the next photo, like the arrow keys.

## 0.2.8 to 0.2.9 - 2026-10-13
### New
- The info panel in the Browser and the one in the viewer follow one design. Section titles are easy to read, and the numbers line up on the right edge. In a narrow info panel a long value wraps instead of being cut, and the size and the date get a shorter form.
- The right-click menu in the viewer has Slideshow, Batch and Compare, in the same order as in the Browser.
- The edited mark on a photo is now a small chip with a pencil. It is easy to see on a bright photo. Point at it to read what it means.
- The Welcome window has one main button: Open Folder. Press Return to use it.
- External Editors in Settings is a clean list. It shows only the editors you added, and a short message when there are none.
- In edit mode the right side looks like a panel. With no tool chosen, a tall card fills it and says what to do. The histogram sits in that column under the tool panel, never on your photo. It hides when the column has no room, or while the Levels tool shows its own.
- Edit mode needs a window at least 648 points wide. If your window is narrower, the info panel steps aside and the window gets wider. When you finish, the window goes back to its old size, unless you changed its size yourself. The edit bar is always shown when you start.
- In the Browser list, you can hide the Rating, Flag, Tags and Dimensions columns. Right-click the header row. The choice is kept. Rating is narrow and shows a star with a number, such as ★3.
- On macOS 26, every item in the Shrike, File, Edit, View and Window menus has an icon, so the names line up. Before, some rows had one and some did not.
- A dark shade appears behind the title and the subtitle when a bright photo runs under them, for example when you zoom in. It goes away at Fit.
### Changed
- Show RAW File and Show JPEG File always stay in the menu. They are grey when they do not apply, so you can find them.
- The name under a photo that has a RAW follows the file you see. Show the RAW and the name ends in the RAW extension.
- In the viewer, Edit and Rotate turn off the moment you switch to the RAW.
- The edit panels each end with one Reset button named for the tool: Reset Crop, Reset Rotation, Reset Resize, Reset Color, Reset Levels. The Resize panel has Width, Height and Scale, and says what the new size will be. All sliders show their numbers the same way.
- Only one histogram shows at a time. When the info panel is open it has the histogram, and the floating one waits.
- A photo that can't be opened shows a larger card with a bigger warning sign, and no histogram.
- The Trash message is flatter and has no wide shadow.
- Esc, Page Up, Page Down, Home and End are written as words in the shortcut list.
- In menus, the plain keys (such as Q or 3) show as small badges in the shortcut column, in the main menus and in the right-click menus. A row with its own Cmd shortcut shows only that shortcut.
- The blue that Shrike draws itself (the selection ring in the filmstrip, the drop zones, the button icons that turn on) is one blue. Controls that the system draws keep the system blue.
- The Reset button is as wide as the panel in Resize and Levels too.
- In the Browser list, the column titles are easier to read, in light and in dark, and the rows use 13 point text. After you sort or filter, the selected photo stays in view. A photo that is already in view does not make the list scroll.
- Settings labels have no colon. The Thumbnails page says the real default size.
- The Mouse and Trackpad note in Settings now tells the whole story about the two-finger scroll.
- The loupe has a thin ring that you can see on light and dark photos.
### Fixed
- The window zoom button is not slowed down any more. The quick resize is only for the edit mode width.
- A window that was made wider for edit mode, where you finished editing in full screen, goes back to its old size when you leave full screen.
- Zoom to Fit (Cmd+0 or the View menu) puts the photo back to Fit, also after you zoomed out and also while a zoom is still moving.
- The Undo button on the Trash message works when you click near it, not only on the exact letters. The message does not move when the zoom label comes or goes.
- A folder with a thousand photos no longer freezes the app when VoiceOver or another tool reads the Browser.
- After you rotate a photo, the small picture in the filmstrip turns too. It also follows Undo, and Done in edit mode.
- The search box in the shortcut list is ready for typing when the window opens.
- VoiceOver reads "edited" for an edited photo in the Browser.

## 0.2.7 - 2026-10-12
### New
- Help > Keyboard Shortcuts (Cmd+/) opens a window you can search. Type a name, a key or a section. It stays open next to your photos.
- Menus now show the plain keys, such as Q for Flag and 1 to 5 for the stars. They sit on the right of the menu item.
- In Compare, Tab and Shift+Tab move from one pane to the next. The active pane has a thicker ring. The window title tells you about the keys.
- The Browser filter has a Flag choice: Any, Flagged or Not flagged. Unrated is now the second line of the Rating choice.
- The right-click menu in the Browser has Copy to Folder, Move to Folder and Rename.
- A photo that can't be opened shows two buttons: Next and Reveal in Finder.
- Slideshow and contact sheet start with your photos when you select two or more.
- Opening a folder that is already open brings its window forward. No second window.
### Changed
- On the Mac keys, only Cmd+Delete moves a photo to the Trash. A plain Delete shows a short hint, once.
- The Trash message with Undo stays 6 seconds.
- Edit mode has one way to finish. Done saves everything. Cancel throws it away. Apply is only on Crop and Resize, and Done also applies a size you typed.
- In edit mode the tool panel is as tall as its content.
- The tools to edit (Crop, Rotate, Resize, Color, Levels) are in the bar at the top, and in full screen in the bar at the bottom. Point at an icon to see its name. The tool strip on the left is gone, with its menu item and its setting. Edit Image is now also in the right-click menu.
- In a window, the filmstrip stays in edit mode. Click another photo to edit it next.
- Long file names keep their number and their end, so IMG_4245_new.jpg and IMG_4245.jpg look different. This holds in the position pill of the viewer too. Point at a name to see all of it.
- The inspector in full screen has bigger text and the same yellow stars as the Browser. The Clear link next to the stars gets an underline when you point at it.
### Fixed
- After you rotate a photo, the size in the title, the inspector and Actual Size now match the photo you see. The Browser list (Dimensions column and sort) and the Browser inspector show the new size too, also after a save, an undo or a change made outside Shrike.
- In the Browser right-click menu, Rename is off when you select several photos. Use Batch for those.
- A file smaller than 1 KB shows its size in bytes, not 0 KB.
- A damaged photo shows a warning sign in the filmstrip and in the Browser inspector. The error text fits its box.
- VoiceOver reads each thumbnail as one item, such as "IMG_4222.JPG, 3 stars, flagged", in the filmstrip too. The edit fields have names too.
- The text on the "can't open" card wraps onto two lines instead of being cut.
- In edit mode, Return in a size field sets the value. The next Return is Done.
- The viewer inspector no longer shows the stars and flag of the previous photo after you open another one from the Browser.
- Rename shows F2, not Cmd+F2, in the Browser right-click menu, and F2 is shown in the viewer right-click menu. Actual Size and Edit Image show only their Cmd key.
- Share works in the Browser right-click menu.
- The Browser list shows the new size of a file that was changed without a new date.

## 0.2.6 - 2026-10-11
### Faster
- Scrolling fast through a big folder no longer leaves work behind. Thumbnails for photos you scrolled past are not made any more. In a test with 1000 photos, the work after the scroll stopped went from about 3 seconds to under 1 second. The processor load in the next 12 seconds fell from about 17 seconds of work to 5.
- A thumbnail you saw before shows at once when you scroll back, with no blank cell and no fade.
- The viewer uses less memory. A 1200 by 800 window uses 125 to 130 MB when it opens (it was 150 to 165 MB) and 135 MB after 50 photos (it was 165 MB). After 3 seconds on one photo, Shrike lets go of the two photos farther away. It loads them again when you move.
- A Browser with 1000 photos uses about 180 MB after a long scroll (it was about 300 MB).
- Full screen keeps two screen buffers instead of up to three. That is up to 70 MB less on a large display.
### Changed
- Thumbnails in the Browser are sharp on a Retina screen. They were made at half the size and stretched. Thumbnails made by an older version are made again when you look at them.

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
- In edit mode, Done and Apply used the same blue as the toolbar. (From 0.2.7, Apply is a plain grey button and Done is the only blue one.)
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
