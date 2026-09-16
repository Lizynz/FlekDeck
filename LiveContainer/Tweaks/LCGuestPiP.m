//
//  LCGuestPiP.m
//  LiveContainer
//
//  Sends a multitask guest's Picture in Picture requests to the host, because
//  the guest cannot serve them itself.
//
//  A guest's own AVPictureInPictureController starts happily in multitask — the
//  window appears, with the system's transport controls, and the audio keeps
//  playing — but the video is never anything but black. The content of a PiP
//  window is a FrontBoard scene that SpringBoard creates with the requesting
//  process as its scene client, and a LiveProcess guest cannot be one:
//
//      [com.apple.pegasus.pictureinpicture:…] Failed to resolve a scene client
//      provider: FBProcessManager code 1 ("not-supported") — "RunningBoard does
//      not support directly launching xpcservice<…LiveProcess…>[extension][client]"
//      → Update failed: FBSceneErrorDomain code 1 "No scene client exists"
//
//  Nothing here can change that answer. It is not about entitlements or scene
//  settings: the classification comes from the guest being an app extension
//  spawned through NSExtension, which is the only way the host can start a guest
//  process at all, and the refusal is decided inside SpringBoard. The trick that
//  gives the guest its main window — registering its audit token with
//  FBProcessManager — only registers it in the host's process, and there is no
//  equivalent reach into SpringBoard's.
//
//  The host, being an ordinary installed app, has no such trouble: its own PiP
//  scene resolves and renders. So the guest's request is swallowed here and
//  handed across, and the host floats the window instead. The app is deliberately
//  left believing nothing happened — no delegate callbacks, no change to
//  isPictureInPictureActive — because an app told that PiP has begun tears down
//  its inline player and puts up a "playing in picture in picture" placeholder,
//  and that placeholder is precisely what the host would then be showing.
//
//  Installed during bootstrap, before the app binary is dlopened, and only for a
//  LiveProcess guest: an app running in single mode is a real app process, its
//  own PiP works properly, and none of this applies to it.
//
@import Foundation;
@import ObjectiveC;

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>

#import "Tweaks.h"

// AVKit is deliberately not imported: importing the module would autolink it
// into LiveContainer, dragging the framework into every guest including the ones
// that never play a video. The class is looked up by name once it arrives, so a
// process without AVKit simply gets no hooks.
#pragma clang diagnostic ignored "-Wundeclared-selector"

static NSString *gStartName;
static NSString *gStopName;
static bool gControllerHooksInstalled = false;
static bool gProxyHooksInstalled = false;

static void lcPostToHost(NSString *name) {
    if(!name) return;
    notify_post(name.UTF8String);
}

#pragma mark - Hooks

static void (*orig_startPictureInPicture)(id, SEL);
static void lc_startPictureInPicture(id self, SEL _cmd) {
    // Not forwarded. Calling through is what produces the empty window.
    NSLog(@"[LCGuestPiP] start requested, handing to host");
    lcPostToHost(gStartName);
}

static void (*orig_stopPictureInPicture)(id, SEL);
static void lc_stopPictureInPicture(id self, SEL _cmd) {
    NSLog(@"[LCGuestPiP] stop requested, handing to host");
    lcPostToHost(gStopName);
}

static void (*orig_setCanStartAutomatically)(id, SEL, BOOL);
static void lc_setCanStartAutomatically(id self, SEL _cmd, BOOL value) {
    // Pinned off, whatever the app asks for. Automatic PiP on backgrounding is
    // started by SpringBoard commanding the proxy directly, without ever going
    // through -startPictureInPicture, so leaving this on would let the same
    // black window back in by a route the hook above never sees. The host
    // decides for itself whether a window should float when it is backgrounded;
    // the app's opinion would only be about a window it cannot have.
    if(orig_setCanStartAutomatically) {
        orig_setCanStartAutomatically(self, _cmd, NO);
    }
}

static void (*orig_setShouldStartWhenEnteringBackground)(id, SEL, BOOL);
static void lc_setShouldStartWhenEnteringBackground(id self, SEL _cmd, BOOL value) {
    // The other half of the setter above, and the one that actually decides.
    // AVKit works this flag out from several things at once — the app's request,
    // whether the player is full screen, whether it is playing — and only then
    // tells the proxy. A guest playing full screen reaches
    //
    //     _updatePictureInPictureShouldStartWhenEnteringBackground
    //       canStartAutomaticallyWhenEnteringBackground: YES
    //       alwaysStartsAutomaticallyWhenEnteringBackground - YES  …  YES
    //
    // without the app having asked for anything, so refusing the app's request
    // alone does not close the route. This is where every path arrives.
    if(orig_setShouldStartWhenEnteringBackground) {
        orig_setShouldStartWhenEnteringBackground(self, _cmd, NO);
    }
}

#pragma mark - Installation

static bool lcHookMethod(Class class, SEL selector, IMP replacement, void *originalOut) {
    if(!class) return false;
    Method method = class_getInstanceMethod(class, selector);
    if(!method) return false;
    *(IMP *)originalOut = method_getImplementation(method);
    method_setImplementation(method, replacement);
    return true;
}

static void lcInstallControllerHooks(void) {
    if(gControllerHooksInstalled) return;
    Class controllerClass = NSClassFromString(@"AVPictureInPictureController");
    if(!controllerClass) return;
    gControllerHooksInstalled = true;

    bool start = lcHookMethod(controllerClass, @selector(startPictureInPicture),
                              (IMP)lc_startPictureInPicture, &orig_startPictureInPicture);
    bool stop = lcHookMethod(controllerClass, @selector(stopPictureInPicture),
                             (IMP)lc_stopPictureInPicture, &orig_stopPictureInPicture);
    // Absent on iOS 14 and below, where auto-PiP did not exist. Its absence is
    // not a failure; there is simply nothing to pin off.
    bool automatic = lcHookMethod(controllerClass, @selector(setCanStartPictureInPictureAutomaticallyFromInline:),
                                  (IMP)lc_setCanStartAutomatically, &orig_setCanStartAutomatically);

    NSLog(@"[LCGuestPiP] controller hooks installed (start=%d stop=%d automatic=%d)", start, stop, automatic);
}

// Pegasus arrives with AVKit rather than on its own, but it is a separate image
// and the class can show up on a later pass than the controller's, so it is
// tracked separately. Private, and so allowed to be missing: a version that has
// renamed it loses automatic PiP suppression, which is a black window the user
// has to dismiss, not a crash.
static void lcInstallProxyHooks(void) {
    if(gProxyHooksInstalled) return;
    Class proxyClass = NSClassFromString(@"PGPictureInPictureProxy");
    if(!proxyClass) return;
    gProxyHooksInstalled = true;

    bool background = lcHookMethod(proxyClass, @selector(setPictureInPictureShouldStartWhenEnteringBackground:),
                                   (IMP)lc_setShouldStartWhenEnteringBackground,
                                   &orig_setShouldStartWhenEnteringBackground);

    NSLog(@"[LCGuestPiP] proxy hooks installed (background=%d)", background);
}

static void lcInstallHooks(void) {
    lcInstallControllerHooks();
    lcInstallProxyHooks();
}

// A guest that links AVKit the usual way has none of it loaded yet at bootstrap —
// this runs before the app binary is even dlopened. dyld replays this for every
// image already in the process and then calls it for each new one, so the hooks
// go in the moment AVKit arrives and no later.
static void lcPiPImageAdded(const struct mach_header *header, intptr_t slide) {
    lcInstallHooks();
}

void LCGuestPiPInit(NSString *dataUUID) {
    if(dataUUID.length == 0) return;

    // A fixed literal prefix keyed by container, matching LCAudioMute's channel:
    // the host and the guest are separate processes each deriving the app group
    // id for themselves, and the two only have to disagree once for the names to
    // stop matching and every request to vanish.
    NSString *base = [NSString stringWithFormat:@"com.kdt.livecontainer.pip.%@", dataUUID];
    gStartName = [base stringByAppendingString:@".start"];
    gStopName = [base stringByAppendingString:@".stop"];

    lcInstallHooks();
    _dyld_register_func_for_add_image(lcPiPImageAdded);

    NSLog(@"[LCGuestPiP] armed on %@", base);
}
