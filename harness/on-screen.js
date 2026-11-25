// on-screen.js: what of these processes the person at the Mac can see now (README, "Testing with
// no hand"). `osascript -l JavaScript harness/on-screen.js <pid>…` prints one JSON object: `windows`,
// each window of those processes that the window server shows (on screen, alpha above 0, an area)
// with a frame that intersects a display, and `front`, the pid of the active app when it is one of
// them. Frames are the window server's: points, from the top left of the main display.
ObjC.import("AppKit");
ObjC.import("CoreGraphics");

function run(argv) {
  const pids = new Set(argv.map(Number));
  const frames = $.NSScreen.screens.js.map((screen) => screen.frame);
  // AppKit's frames start at the bottom left of the main display, the window server's at its top left
  const top = frames[0]?.size.height ?? 0;
  const displays = frames.map((f) => ({ X: f.origin.x, Y: top - f.origin.y - f.size.height, Width: f.size.width, Height: f.size.height }));
  const meets = (a, b) => a.X < b.X + b.Width && b.X < a.X + a.Width && a.Y < b.Y + b.Height && b.Y < a.Y + a.Height;
  const list = ObjC.deepUnwrap(ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0))) ?? [];
  const windows = list
    .filter((w) => pids.has(w.kCGWindowOwnerPID) && w.kCGWindowAlpha > 0)
    .filter((w) => w.kCGWindowBounds.Width > 0 && w.kCGWindowBounds.Height > 0 && displays.some((d) => meets(w.kCGWindowBounds, d)))
    .map((w) => ({ pid: w.kCGWindowOwnerPID, number: w.kCGWindowNumber, name: w.kCGWindowName ?? "", layer: w.kCGWindowLayer, alpha: w.kCGWindowAlpha, frame: w.kCGWindowBounds }));
  const front = $.NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
  return JSON.stringify({ windows, front: pids.has(front) ? front : null });
}
