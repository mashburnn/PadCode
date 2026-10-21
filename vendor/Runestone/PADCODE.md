Runestone 0.5.2 (MIT), from
https://github.com/simonbs/Runestone/tree/592434a103a4d1ab83e14f87ac6eef569dd7a99d
without the docs, tests and example app.

Only change: TextInputView.layoutSubviews clears
`notifyInputDelegateAboutSelectionChangeInLayoutSubviews` after notifying
(line marked "padcode"). Upstream never clears it, so after any selection
change every layout pass (scrolling, resizing a pane, typing) re-ran UIKit's
keyboard selection bookkeeping, which is most of a frame's work.

Also: `TextView.extraEditMenuItems` (lines marked "padcode"), so PadCode
can put Go to Definition, Rename and the like into the edit menu, which is
also the trackpad right-click menu.

Also: bracket pair colorization (`Theme.bracketPairColors`, `colorBrackets` in TreeSitterSyntaxHighlighter, lines marked "padcode"). It colors (), [] and {} tokens of the syntax tree by how many bracketed nodes enclose them, so brackets in strings and comments are skipped; lines over 20,000 characters are left alone.

Also: indent guides (`Theme.indentGuideColor`, `LayoutManager.indentGuides(for:)`, drawn by LineFragmentRenderer; lines marked "padcode"). One line per indent level on a line's first fragment; blank lines take the smaller indent of their nearest non-blank neighbors.
Also: `TextView.contentOffset` is `open` (PadCode's sticky scroll follows it).
Also: a `HighlightedRange` with a negative `cornerRadius` is drawn as a squiggly underline (`drawSquiggle`, for diagnostics).
Active indent guide: `LayoutManager.updateActiveIndentGuide` (on selection change) brightens the guide of the block holding the caret (`Theme.activeIndentGuideColor`).
A `cornerRadius` of -2 or less draws a plain underline instead (⌘-hover links).

- `TextInputView` turns off inline predictions, Writing Tools and math
  completion (marked "padcode"): none fit a code editor, and each adds
  keyboard work on focus changes and keystrokes.
