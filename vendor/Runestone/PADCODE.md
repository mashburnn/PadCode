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
