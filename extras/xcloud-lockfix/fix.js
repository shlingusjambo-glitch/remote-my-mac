// Cloud-gaming players pass {unadjustedMovement: true}, which puts Chromium's pointer lock on a
// raw-input path where no injected/synthetic mouse movement is ever reported (movementX stays 0).
// Drop that option so the lock uses the normal, delta-based path.
(() => {
  const proto = Element.prototype;
  const orig = proto.requestPointerLock;
  if (typeof orig !== 'function' || orig.__xcloudFix) return;
  const patched = function (opts) {
    if (opts && opts.unadjustedMovement) {
      try { return orig.call(this, { unadjustedMovement: false }); } catch (e) { return orig.call(this); }
    }
    return orig.call(this, opts);
  };
  patched.__xcloudFix = true;
  proto.requestPointerLock = patched;
})();
