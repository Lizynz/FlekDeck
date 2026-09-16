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
//  handed across, and the host floats the window instead.
//
//  The app is then told its PiP started, which is both true enough and necessary:
//  its video layer really is floating, and an app left believing its request
//  failed tears the session down seconds later, taking with it the playback
//  delegate the host needs to drive play, pause and skip. Its inline UI shows a
//  "playing in picture in picture" placeholder, exactly as it would under a real
//  PiP, and that costs nothing here because what floats is the video layer rather
//  than a picture of the app's window.
//
//  Installed during bootstrap, before the app binary is dlopened, and only for a
//  LiveProcess guest: an app running in single mode is a real app process, its
//  own PiP works properly, and none of this applies to it.
//
@import Foundation;
@import ObjectiveC;
@import CoreGraphics;

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <os/log.h>

#import "Tweaks.h"

// AVKit is deliberately not imported: importing the module would autolink it
// into LiveContainer, dragging the framework into every guest including the ones
// that never play a video. The class is looked up by name once it arrives, so a
// process without AVKit simply gets no hooks.
#pragma clang diagnostic ignored "-Wundeclared-selector"

// CoreMedia's layout, spelled out rather than imported: importing the module
// would autolink CoreMedia into every guest, including the ones that never play
// anything. Only the shape matters here, to read a time range back out of the
// app's own playback delegate.
typedef struct { int64_t value; int32_t timescale; uint32_t flags; int64_t epoch; } LCTime;
typedef struct { LCTime start; LCTime duration; } LCTimeRange;

static double lcSeconds(LCTime time) {
    if(time.timescale == 0 || (time.flags & 1) == 0) return 0; // not a valid time
    return (double)time.value / (double)time.timescale;
}

static LCTime lcMakeTime(double seconds) {
    LCTime time = { (int64_t)(seconds * 600.0), 600, 1, 0 };
    return time;
}

static NSString *gStartName;
static NSString *gStopName;
static NSString *gEndedName;
static NSString *gStateName;
static NSString *gPlayName;
static NSString *gSkipName;
static NSString *gVideoRectName;
/// The app's own PiP controller and the playback delegate it gave AVKit. Every
/// command the host's PiP window sends is answered by handing it to these, so the
/// app drives its own player and nothing here has to understand playback.
///
/// The delegate is held strongly and on purpose. `sampleBufferPlaybackDelegate`
/// is a weak property, and the app lets go of its own reference once it decides
/// its PiP is over — which, since its request was swallowed and it was never told
/// PiP began, is a few seconds after it asked. The delegate then vanishes
/// mid-session: pause works if pressed early enough and play does nothing at all,
/// which is exactly how this failed.
static id gAppController;
static id gPlaybackDelegate;
static bool gControllerHooksInstalled = false;
static bool gProxyHooksInstalled = false;

static void lcPostToHost(NSString *name) {
    if(!name) return;
    notify_post(name.UTF8String);
}

/// Asks the host to float this guest, and tells it where the video is.
///
/// A notification name carries no payload, so the context id travels as the
/// name's own 64-bit state — the same way LCAudioMute carries a volume level. The
/// token is registered once and kept, because the state belongs to the name only
/// for as long as somebody holds a registration on it.
static int gStartToken = NOTIFY_TOKEN_INVALID;
static void lcRequestFloat(uint64_t payload) {
    if(gStartToken == NOTIFY_TOKEN_INVALID) {
        int token = 0;
        if(notify_register_check(gStartName.UTF8String, &token) == NOTIFY_STATUS_OK) {
            gStartToken = token;
        }
    }
    if(gStartToken != NOTIFY_TOKEN_INVALID) {
        uint32_t status = notify_set_state(gStartToken, payload);
        if(status != NOTIFY_STATUS_OK) {
            // Said out loud because the host would otherwise see a request to
            // float with no video in it and have no way to tell why.
            NSLog(@"[LCGuestPiP] could not set context state (%u)", status);
        }
    }
    lcPostToHost(gStartName);
}

#pragma mark - Finding the guest's video

// An AVSampleBufferDisplayLayer does not hold pixels. Its video is decoded out of
// process and reaches the layer as a CALayerHost onto the decoder's CAContext,
// which is how AVKit moves video into a PiP window without copying a single
// frame: -[AVPictureInPictureSampleBufferDisplayLayerView _updateSourceLayerHost]
// searches the source layer for the first CALayerHost and hands its contextId to
// the PiP window's host view.
//
// The host can do the same, since a context id is just a number: give it the
// guest's, and SpringBoard renders the guest's video in a PiP window that the
// host owns. This walks the layer tree the way AVKit's own search does — first
// layer host found, depth first, sublayers in reverse — so that whatever is
// reported here is what AVKit would have used.
static id lcFindFirstLayerHost(id layer) {
    if(!layer) return nil;
    Class hostClass = NSClassFromString(@"CALayerHost");
    if(hostClass && [layer isKindOfClass:hostClass]) return layer;
    NSArray *sublayers = [layer valueForKey:@"sublayers"];
    for(id sublayer in sublayers.reverseObjectEnumerator) {
        id found = lcFindFirstLayerHost(sublayer);
        if(found) return found;
    }
    return nil;
}

/// The names and sizes of the layers from the source layer down, for working out
/// where the video actually lives inside it.
///
/// Logged through os_log with an explicitly public C string. NSLog redacts a `%@`
/// argument, which is how two rounds of this came back as a column of `<private>`
/// saying nothing at all, and its `%{public}` annotations do not survive either.
static NSString *lcLayerTreeDescription(id layer, int depth) {
    if(!layer || depth > 6) return @"";
    CGRect (*getBounds)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
    CGRect bounds = getBounds(layer, @selector(bounds));
    NSArray *sublayers = [layer valueForKey:@"sublayers"];
    NSMutableString *description = [NSMutableString stringWithFormat:@"%*s%@ %dx%d (%lu sub)\n",
                                    depth * 2, "", NSStringFromClass([layer class]),
                                    (int)bounds.size.width, (int)bounds.size.height,
                                    (unsigned long)sublayers.count];
    for(id sublayer in sublayers) {
        [description appendString:lcLayerTreeDescription(sublayer, depth + 1)];
    }
    return description;
}

/// Sends the video's rect inside the published context, packed a field to a
/// quarter of the state. Set before the request to float is posted, so the host
/// finds it already there when it reads it.
static int gVideoRectToken = NOTIFY_TOKEN_INVALID;
static void lcPublishVideoRect(CGRect rect) {
    if(!gVideoRectName) return;
    if(gVideoRectToken == NOTIFY_TOKEN_INVALID) {
        int token = 0;
        if(notify_register_check(gVideoRectName.UTF8String, &token) != NOTIFY_STATUS_OK) return;
        gVideoRectToken = token;
    }
    uint64_t x = (uint64_t)MIN(MAX((int)rect.origin.x, 0), 0xFFFF);
    uint64_t y = (uint64_t)MIN(MAX((int)rect.origin.y, 0), 0xFFFF);
    uint64_t w = (uint64_t)MIN(MAX((int)rect.size.width, 0), 0xFFFF);
    uint64_t h = (uint64_t)MIN(MAX((int)rect.size.height, 0), 0xFFFF);
    notify_set_state(gVideoRectToken, x | (y << 16) | (w << 32) | (h << 48));
}

#pragma mark - Publishing the video on its own

// The context the video is published in, and everything needed to put the app's
// layer back exactly as it was found.
static id gVideoContext;
static id gBorrowedLayer;
static id gBorrowedSuperlayer;
static unsigned gBorrowedIndex;
static CGPoint gBorrowedAnchorPoint;
static CGPoint gBorrowedPosition;
/// CATransform3D's shape, spelled out for the same reason as the time structs.
typedef struct { CGFloat m[16]; } LCTransform3D;
static LCTransform3D gBorrowedTransform;
static CGRect gBorrowedBounds;
/// The app's own layer, while its video is published. Its control timebase is
/// where the playback position lives.
static id gTimebaseLayer;

/// Publishes the guest's video as a CAContext of its own and returns its id, with
/// the video's size, packed for the trip across.
///
/// The video cannot simply be borrowed where it is. A sample buffer layer holds
/// no CALayerHost to point the host at — that was checked on a real guest and
/// there is none — because for an ordinary app AVKit never moves video anywhere:
/// the PiP window's content is a scene in the app's *own* process, so the app's
/// existing layer is simply placed in it. That is also why a guest's own PiP is
/// black, its scene having no client.
///
/// So a context is made rather than found, and the app's video layer is moved
/// into it for as long as the host is showing it.
///
/// Moved rather than mirrored. A CAPortalLayer was tried first, since it leaves
/// the app's own tree untouched, and it showed nothing: a portal mirrors within a
/// render tree, and the whole point here is that the portal and its source end up
/// in different contexts. Moving the layer has no such problem — it genuinely is
/// in the context being published — and costs the app nothing visible, because a
/// window that is floating is a window the host has already hidden. It goes back
/// where it came from, at the index it came from, when PiP ends.
///
/// The app's layer becomes the context's root layer directly, with nothing
/// wrapped around it. A container was tried and showed through as a border: the
/// app goes on laying its own layer out after the move, so a container sized once
/// at publish time stops agreeing with it almost immediately. As the root there
/// is nothing to disagree with — the context is the layer, whatever size the app
/// decides it should be.
///
/// A root layer draws from its own anchor point, so that is pinned to the corner
/// for the duration and put back afterwards along with everything else.
static uint32_t lcPublishVideoContext(id sourceLayer, CGSize *sizeOut) {
    Class contextClass = NSClassFromString(@"CAContext");
    if(!contextClass) {
        NSLog(@"[LCGuestPiP] video: no CAContext class, cannot publish");
        return 0;
    }

    CGRect (*getBounds)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
    CGRect bounds = getBounds(sourceLayer, @selector(bounds));
    if(bounds.size.width < 1 || bounds.size.height < 1) {
        NSLog(@"[LCGuestPiP] video: source layer has no size yet");
        return 0;
    }
    if(sizeOut) *sizeOut = bounds.size;

    // A remote context is the hostable kind — the same thing UIKit publishes a
    // scene into, and what the host already hosts to show this guest at all.
    id context = [contextClass performSelector:@selector(remoteContextWithOptions:) withObject:nil];
    if(!context) {
        NSLog(@"[LCGuestPiP] video: could not make a remote context");
        return 0;
    }

    // Remembered before anything is touched, so it can all be undone exactly.
    CGPoint (*getPoint)(id, SEL) = (CGPoint (*)(id, SEL))objc_msgSend;
    gBorrowedAnchorPoint = getPoint(sourceLayer, @selector(anchorPoint));
    gBorrowedPosition = getPoint(sourceLayer, @selector(position));
    gBorrowedSuperlayer = [sourceLayer valueForKey:@"superlayer"];
    gBorrowedIndex = 0;
    if(gBorrowedSuperlayer) {
        NSArray *siblings = [gBorrowedSuperlayer valueForKey:@"sublayers"];
        NSUInteger index = [siblings indexOfObject:sourceLayer];
        gBorrowedIndex = (index == NSNotFound) ? 0 : (unsigned)index;
    }
    gBorrowedLayer = sourceLayer;

    LCTransform3D (*getTransform)(id, SEL) = (LCTransform3D (*)(id, SEL))objc_msgSend;
    void (*setTransform)(id, SEL, LCTransform3D) = (void (*)(id, SEL, LCTransform3D))objc_msgSend;
    gBorrowedTransform = getTransform(sourceLayer, @selector(transform));

    void (*setPoint)(id, SEL, CGPoint) = (void (*)(id, SEL, CGPoint))objc_msgSend;
    [sourceLayer performSelector:@selector(removeFromSuperlayer)];
    setPoint(sourceLayer, @selector(setAnchorPoint:), CGPointMake(0, 0));
    setPoint(sourceLayer, @selector(setPosition:), CGPointMake(0, 0));

    // Identity for the duration. A context renders its root layer *through* that
    // layer's own transform, and this one carries the scale the app was using to
    // fit an 816-wide layer into a 402-wide window — so the context came out at
    // half the size its bounds claim, and the picture landed in a quarter of the
    // window with everything measured against the wrong scale. Flat here, and the
    // context is exactly its bounds.
    LCTransform3D identity = {{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}};
    setTransform(sourceLayer, @selector(setTransform:), identity);

    // Bounds are left alone. The layer being published is the picture already, at
    // the natural size AVKit expects to host, so there is nothing to crop to and
    // nothing to resize. Cropping and resizing were both tried while the app's
    // outer layer was the one being published, and neither could work: the size
    // was wrong by a factor no amount of framing on either side could correct.
    gBorrowedBounds = bounds;

    [context setValue:sourceLayer forKey:@"layer"];

    gTimebaseLayer = sourceLayer;
    gVideoContext = context;

    uint32_t (*getContextId)(id, SEL) = (uint32_t (*)(id, SEL))objc_msgSend;
    uint32_t contextId = getContextId(context, @selector(contextId));
    NSLog(@"[LCGuestPiP] video: published context %u, %dx%d, taken from %@ at %u",
          contextId, (int)bounds.size.width, (int)bounds.size.height,
          NSStringFromClass([gBorrowedSuperlayer class]), gBorrowedIndex);
    return contextId;
}

static void lcStopPublishingPlaybackState(void);
static void lcTellAppNotFloating(void);
static BOOL gAppBelievesItIsFloating;
/// Whether the user wants playback running, which only the PiP window's play and
/// pause buttons change. Deliberately not the app's own momentary state: a player
/// reports itself paused while it seeks, so a skip arriving on the heels of
/// another one read "it was paused already" and left it that way — which is why
/// skipping worked about half the time.
static BOOL gIntendedPlaying = YES;
/// When a skip last arrived. AVKit pauses on either side of every skip press, and
/// those pauses are its own business rather than the user's.
static CFAbsoluteTime gLastSkipTime = 0;

static void lcUnpublishVideoContext(void) {
    lcStopPublishingPlaybackState();
    lcTellAppNotFloating();
    if(!gBorrowedLayer) return;
    // Back where it came from first: the context is what is holding the layer,
    // and clearing that before it has somewhere else to be would drop it.
    void (*setPoint)(id, SEL, CGPoint) = (void (*)(id, SEL, CGPoint))objc_msgSend;
    void (*setTransform)(id, SEL, LCTransform3D) = (void (*)(id, SEL, LCTransform3D))objc_msgSend;
    setPoint(gBorrowedLayer, @selector(setAnchorPoint:), gBorrowedAnchorPoint);
    setPoint(gBorrowedLayer, @selector(setPosition:), gBorrowedPosition);
    setTransform(gBorrowedLayer, @selector(setTransform:), gBorrowedTransform);
    void (*setBounds)(id, SEL, CGRect) = (void (*)(id, SEL, CGRect))objc_msgSend;
    setBounds(gBorrowedLayer, @selector(setBounds:), gBorrowedBounds);
    gTimebaseLayer = nil;
    gPlaybackDelegate = nil;
    if(gBorrowedSuperlayer) {
        void (*insertSublayer)(id, SEL, id, unsigned) = (void (*)(id, SEL, id, unsigned))objc_msgSend;
        [gBorrowedLayer performSelector:@selector(removeFromSuperlayer)];
        insertSublayer(gBorrowedSuperlayer, @selector(insertSublayer:atIndex:), gBorrowedLayer, gBorrowedIndex);
        NSLog(@"[LCGuestPiP] video: returned the app's layer to %@ at %u",
              NSStringFromClass([gBorrowedSuperlayer class]), gBorrowedIndex);
    }
    if(gVideoContext) {
        [gVideoContext setValue:nil forKey:@"layer"];
    }
    gBorrowedLayer = nil;
    gBorrowedSuperlayer = nil;
    gVideoContext = nil;
}

/// The layer inside `layer` that is actually the video, or nil.
///
/// What AVKit is handed as the "source" is a container — the video sits somewhere
/// below it, at whatever size and offset the app's own layout gave it, which is
/// why publishing the container puts a small picture in the corner of a large
/// empty context. A layer whose class names itself video is the one wanted;
/// CoreMedia's own are called FigVideoLayer and the like.
/// Deepest first, and containers are not it. A real tree looks like
///
///     HAMSBDL 816x816
///       AVSampleBufferDisplayLayerVideoContainerLayer 816x816
///         FigVideoLayer 1600x900
///
/// where the picture is the bottom one at the video's own dimensions, scaled down
/// to fit the square above it — and the middle one calls itself video as well. So
/// searching top down and taking the first match finds the container, which is
/// the same square as the source and no use at all.
static id lcFindVideoLayer(id layer) {
    if(!layer) return nil;
    for(id sublayer in [layer valueForKey:@"sublayers"]) {
        id found = lcFindVideoLayer(sublayer);
        if(found) return found;
    }
    NSString *name = NSStringFromClass([layer class]);
    if([name containsString:@"Video"] && ![name containsString:@"Container"]) return layer;
    return nil;
}

/// The deepest single-child descendant with a size, for when nothing names itself
/// video. A player's layer tree is a chain rather than a fan, and the bottom of
/// the chain is the picture.
static id lcDeepestSingleChild(id layer) {
    id deepest = layer;
    while(true) {
        NSArray *sublayers = [deepest valueForKey:@"sublayers"];
        if(sublayers.count != 1) return deepest;
        CGRect (*getBounds)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
        CGRect bounds = getBounds(sublayers.firstObject, @selector(bounds));
        if(bounds.size.width < 1 || bounds.size.height < 1) return deepest;
        deepest = sublayers.firstObject;
    }
}

/// Where the video sits inside the published context, in the source layer's own
/// coordinates. The host clips the context to this, which is what makes the PiP
/// window the shape of the video rather than the shape of the app's container.
static CGRect lcVideoRectInLayer(id sourceLayer) {
    CGRect (*getBounds)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
    id videoLayer = lcFindVideoLayer(sourceLayer) ?: lcDeepestSingleChild(sourceLayer);
    CGRect bounds = getBounds(videoLayer, @selector(bounds));
    if(videoLayer == sourceLayer || bounds.size.width < 1 || bounds.size.height < 1) {
        return getBounds(sourceLayer, @selector(bounds));
    }
    CGRect (*convertRect)(id, SEL, CGRect, id) = (CGRect (*)(id, SEL, CGRect, id))objc_msgSend;
    CGRect rect = convertRect(videoLayer, @selector(convertRect:toLayer:), bounds, sourceLayer);
    os_log(OS_LOG_DEFAULT, "[LCGuestPiP] video: %{public}s is the picture, %dx%d shown at %d,%d %dx%d inside the source",
           NSStringFromClass([videoLayer class]).UTF8String,
           (int)bounds.size.width, (int)bounds.size.height,
           (int)rect.origin.x, (int)rect.origin.y,
           (int)rect.size.width, (int)rect.size.height);
    return rect;
}

/// The context id of the guest's video, or 0 if it cannot be found.
///
/// Wrapped whole: this walks private layer internals off the back of whatever the
/// app handed AVKit, and a guest that is merely unable to float must not be a
/// guest that crashes on its PiP button.
/// What the host needs to show this guest's video by itself: the context id in
/// the low 32 bits, the video's width and height in the two 16-bit fields above
/// it. One notification state is 64 bits and this is all of it.
///
/// Wrapped whole: this walks private layer internals off the back of whatever the
/// app handed AVKit, and a guest that is merely unable to float must not be a
/// guest that crashes on its PiP button.
static uint64_t lcVideoPayload(id controller) {
    @try {
        id contentSource = [controller valueForKey:@"contentSource"];
        if(!contentSource) {
            NSLog(@"[LCGuestPiP] video: controller has no contentSource");
            return 0;
        }
        id sourceLayer = [contentSource valueForKey:@"sampleBufferDisplayLayer"];
        if(!sourceLayer) {
            // A player-layer source instead, which reaches the screen by another
            // route entirely and would need its own answer.
            NSLog(@"[LCGuestPiP] video: not a sample buffer source (%@)",
                  NSStringFromClass([contentSource class]));
            return 0;
        }
        os_log(OS_LOG_DEFAULT, "[LCGuestPiP] video: source layer tree:\n%{public}s",
               lcLayerTreeDescription(sourceLayer, 0).UTF8String);

        // The video layer itself is what gets published, at its own natural size,
        // and that size is not a matter of taste — AVKit dictates it. The view it
        // hosts our context in does:
        //
        //     fitted = AVMakeRectWithAspectRatioInsideRect(contentDimensions,
        //                                                  {0, 0, 1600, 1600});
        //     hostView.frame = fitted;
        //     hostView.transform = scale to fill its bounds;
        //
        // so the context is expected to be the video fitted into a 1600x1600
        // canvas — 1600x900 for anything 16:9, which is exactly the size
        // CoreMedia's own FigVideoLayer has. Publishing the app's outer layer
        // instead, at its 816 points, put a context half the expected width into
        // a frame sized for the full one, which is why the picture kept arriving
        // small in a corner however it was cropped, offset or resized.
        CGRect (*getBounds)(id, SEL) = (CGRect (*)(id, SEL))objc_msgSend;
        id videoLayer = lcFindVideoLayer(sourceLayer) ?: sourceLayer;
        CGSize size = getBounds(videoLayer, @selector(bounds)).size;
        if(size.width < 1 || size.height < 1) {
            NSLog(@"[LCGuestPiP] video: the picture layer has no size yet");
            return 0;
        }
        NSLog(@"[LCGuestPiP] video: publishing %@ at its own %dx%d",
              NSStringFromClass([videoLayer class]), (int)size.width, (int)size.height);

        // Whole of the context, so the host has nothing to offset or clip.
        lcPublishVideoRect(CGRectMake(0, 0, size.width, size.height));

        uint32_t contextId = lcPublishVideoContext(videoLayer, &size);
        if(contextId == 0) return 0;

        uint64_t width = (uint64_t)MIN(MAX((int)size.width, 0), 0xFFFF);
        uint64_t height = (uint64_t)MIN(MAX((int)size.height, 0), 0xFFFF);
        return (uint64_t)contextId | (width << 32) | (height << 48);
    } @catch(NSException *exception) {
        NSLog(@"[LCGuestPiP] video: giving up, %@ — %@", exception.name, exception.reason);
        return 0;
    }
}

#pragma mark - Playback, proxied

/// The app's playback delegate, if it gave AVKit one. Taken once and kept, for
/// the reason above.
static id lcPlaybackDelegate(void) {
    if(gPlaybackDelegate) return gPlaybackDelegate;
    if(!gAppController) return nil;
    @try {
        id contentSource = [gAppController valueForKey:@"contentSource"];
        gPlaybackDelegate = [contentSource valueForKey:@"sampleBufferPlaybackDelegate"];
    } @catch(NSException *exception) {
        return nil;
    }
    return gPlaybackDelegate;
}

/// Seconds into the video, read from the source layer's control timebase.
///
/// Not from the delegate's time range: that answers what is *seekable*, which for
/// a video on demand starts at zero and stays there. A sample buffer PiP takes
/// its position from the layer's timebase, and so does this.
static double lcElapsedSeconds(BOOL *pausedOut) {
    static LCTime (*timebaseGetTime)(void *);
    static double (*timebaseGetRate)(void *);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        timebaseGetTime = dlsym(RTLD_DEFAULT, "CMTimebaseGetTime");
        timebaseGetRate = dlsym(RTLD_DEFAULT, "CMTimebaseGetRate");
    });
    if(!gTimebaseLayer || !timebaseGetTime) return -1;
    void *timebase = NULL;
    @try {
        // The renderer's timebase, not the layer's controlTimebase. AVKit reads
        // the same one — -[AVSampleBufferDisplayLayerPlayerController
        // _startObservation] goes sampleBufferDisplayLayer -> sampleBufferRenderer
        // -> timebase — and this player sets no controlTimebase at all, which is
        // why the position sat at zero while the duration read correctly.
        id (*getRenderer)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
        void *(*getTimebase)(id, SEL) = (void *(*)(id, SEL))objc_msgSend;
        id renderer = getRenderer(gTimebaseLayer, @selector(sampleBufferRenderer));
        if(renderer) timebase = getTimebase(renderer, @selector(timebase));
        if(!timebase) timebase = getTimebase(gTimebaseLayer, @selector(controlTimebase));
    } @catch(NSException *exception) {
        return -1;
    }
    if(!timebase) return -1;
    if(pausedOut && timebaseGetRate) *pausedOut = timebaseGetRate(timebase) == 0.0;
    return lcSeconds(timebaseGetTime(timebase));
}

/// Publishes what the PiP window's controls need to draw themselves: whether
/// playback is paused, how far in it is, and how long it runs.
///
/// Packed into one notification state rather than pushed as it changes, so the
/// host can read it straight from inside the delegate calls AVKit makes of it,
/// which are synchronous and expect an answer on the spot.
static int gStateToken = NOTIFY_TOKEN_INVALID;
static void lcPublishPlaybackState(void) {
    id delegate = lcPlaybackDelegate();
    if(!delegate || !gStateName) {
        // Said once. Without a delegate there is no playback state to report and
        // the host's window falls back to showing an unscrubbable live stream,
        // which is a silent and very confusing way to fail.
        static BOOL complained = NO;
        if(!complained) {
            complained = YES;
            NSLog(@"[LCGuestPiP] state: no playback delegate to ask (controller %d, name %d)",
                  gAppController != nil, gStateName != nil);
        }
        return;
    }

    BOOL (*isPaused)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;
    LCTimeRange (*timeRange)(id, SEL, id) = (LCTimeRange (*)(id, SEL, id))objc_msgSend;

    BOOL paused = NO;
    LCTimeRange range = {0};
    @try {
        paused = isPaused(delegate, @selector(pictureInPictureControllerIsPlaybackPaused:), gAppController);
        range = timeRange(delegate, @selector(pictureInPictureControllerTimeRangeForPlayback:), gAppController);
    } @catch(NSException *exception) {
        return;
    }

    // The position comes from the layer's timebase; the range only says how long
    // the thing is. Where there is no timebase to read, the range's start is the
    // best that can be done.
    BOOL timebasePaused = paused;
    double elapsed = lcElapsedSeconds(&timebasePaused);
    if(elapsed < 0) {
        elapsed = lcSeconds(range.start);
    } else {
        paused = timebasePaused;
    }

    // Deciseconds in 24 bits each: a little over forty-six hours, which is longer
    // than anything anyone is watching in a window this size.
    uint64_t start = (uint64_t)MIN(MAX(elapsed * 10.0, 0.0), (double)0xFFFFFF);
    uint64_t duration = (uint64_t)MIN(MAX(lcSeconds(range.duration) * 10.0, 0.0), (double)0xFFFFFF);
    // Bit 63 says the guest answered at all, so the host can tell "playing, at
    // zero, of unknown length" from "nothing has arrived yet" — which look
    // identical otherwise and mean quite different things.
    uint64_t state = (1ULL << 63) | (paused ? 1 : 0) | (start << 1) | (duration << 25);

    if(gStateToken == NOTIFY_TOKEN_INVALID) {
        int token = 0;
        if(notify_register_check(gStateName.UTF8String, &token) == NOTIFY_STATUS_OK) {
            gStateToken = token;
        }
    }
    if(gStateToken == NOTIFY_TOKEN_INVALID) return;
    uint32_t status = notify_set_state(gStateToken, state);
    static BOOL reported = NO;
    if(!reported) {
        reported = YES;
        NSLog(@"[LCGuestPiP] state: first publish, paused=%d elapsed=%.1f duration=%.1f (set %u)",
              paused, lcSeconds(range.start), lcSeconds(range.duration), status);
    }

    // Announced, not merely left there. AVKit caches what a sample buffer source
    // last said about playback and re-reads only when the source says it has
    // changed, so a state nobody announces leaves the PiP window's play button
    // showing the opposite of what the player is doing — and pressing it again
    // sends the command it had already sent.
    //
    // Only on a change, since this runs several times a second and the host
    // invalidates AVKit's state each time it hears one.
    static uint64_t lastAnnounced = ~0ULL;
    if(state != lastAnnounced) {
        lastAnnounced = state;
        notify_post(gStateName.UTF8String);
    }
}

static NSTimer *gStateTimer;
static void lcStartPublishingPlaybackState(void) {
    if(gStateTimer) return;
    lcPublishPlaybackState();
    // Often enough for a scrubber to look live, rarely enough to be free. The app
    // is asked for its own numbers each time, so this never drifts from the truth
    // for longer than one tick.
    gStateTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        lcPublishPlaybackState();
    }];
}

static void lcStopPublishingPlaybackState(void) {
    [gStateTimer invalidate];
    gStateTimer = nil;
}

/// Hands a command from the host's PiP window to the app's own playback delegate.
static void lcHandlePlay(BOOL playing) {
    id delegate = lcPlaybackDelegate();
    NSLog(@"[LCGuestPiP] play=%d arrived (delegate %d)", playing, delegate != nil);
    if(!delegate) return;

    if(playing) {
        gIntendedPlaying = YES;
    } else {
        // A pause is forwarded at once, so the button stays responsive, but it
        // only counts as the user's intent if no skip turns up around it. AVKit
        // sends setPlaying:NO both before and after every skip — its native path
        // seeks the player controller with a shouldResumePlayback flag that the
        // public delegate method has no room for, so it pauses, seeks, and expects
        // the player to restart itself. Treated as intent, that pause made every
        // skip decline to resume, which is why skipping stopped the video.
        CFAbsoluteTime pauseTime = CFAbsoluteTimeGetCurrent();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if(gLastSkipTime >= pauseTime - 0.3) return;
            gIntendedPlaying = NO;
        });
    }

    @try {
        void (*setPlaying)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))objc_msgSend;
        setPlaying(delegate, @selector(pictureInPictureController:setPlaying:), gAppController, playing);
    } @catch(NSException *exception) {
        NSLog(@"[LCGuestPiP] play failed: %@", exception.name);
    }
    lcPublishPlaybackState();
}

static void lcHandleSkip(int64_t deciseconds) {
    id delegate = lcPlaybackDelegate();
    NSLog(@"[LCGuestPiP] skip %.1fs arrived (delegate %d, wants playing %d)",
          (double)deciseconds / 10.0, delegate != nil, gIntendedPlaying);
    if(!delegate) return;
    gLastSkipTime = CFAbsoluteTimeGetCurrent();

    @try {
        void (*setPlaying)(id, SEL, id, BOOL) = (void (*)(id, SEL, id, BOOL))objc_msgSend;
        BOOL (*isPaused)(id, SEL, id) = (BOOL (*)(id, SEL, id))objc_msgSend;

        // Seeking stops playback and nothing starts it again: AVKit's own path
        // seeks the player controller directly, with a shouldResumePlayback flag
        // the public delegate method has no room for, and this app does not resume
        // on its own. Nor does it reliably call the completion handler, so the
        // state is checked again over the next few seconds and playing re-asserted
        // while it is still wrong. Bounded, so it cannot fight the end of the
        // video or a buffering stall.
        //
        // Driven by what the PiP window's buttons last asked for rather than by
        // what the player says right now — a player reports itself paused while it
        // seeks, so reading its state made a second skip decline to resume.
        void (^resumeIfNeeded)(void) = ^{
            if(!gIntendedPlaying || !gAppBelievesItIsFloating) return;
            if(!isPaused(delegate, @selector(pictureInPictureControllerIsPlaybackPaused:), gAppController)) return;
            NSLog(@"[LCGuestPiP] resuming after skip");
            setPlaying(delegate, @selector(pictureInPictureController:setPlaying:), gAppController, YES);
            lcPublishPlaybackState();
        };

        void (*skip)(id, SEL, id, LCTime, void (^)(void)) =
            (void (*)(id, SEL, id, LCTime, void (^)(void)))objc_msgSend;
        skip(delegate, @selector(pictureInPictureController:skipByInterval:completionHandler:),
             gAppController, lcMakeTime((double)deciseconds / 10.0), ^{ resumeIfNeeded(); });

        static const double retries[] = {0.4, 1.0, 1.8, 3.0};
        for(size_t i = 0; i < sizeof(retries) / sizeof(retries[0]); i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retries[i] * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ resumeIfNeeded(); });
        }
    } @catch(NSException *exception) {
        NSLog(@"[LCGuestPiP] skip failed: %@", exception.name);
    }
    lcPublishPlaybackState();
}

#pragma mark - Telling the app it is floating

/// Whether the app has been told its PiP is running. Declared above.

/// Tells the app its Picture in Picture started, or stopped.
///
/// This was deliberately not done at first, on the reasoning that an app told PiP
/// has begun replaces its inline video with a "playing in picture in picture"
/// placeholder — which was right while the host floated a mirror of the app's
/// whole window, since the placeholder was then what the user would see.
///
/// It is wrong now. What floats is the video layer itself, so the app's own UI is
/// not on display and its placeholder costs nothing — and in a real sample buffer
/// PiP the app goes on feeding that same layer throughout, which is precisely
/// what is wanted. Leaving the app believing its request failed is what made it
/// tear the session down a few seconds later, taking the playback delegate with
/// it: `sampleBufferPlaybackDelegate` is weak, so pause worked if pressed quickly
/// and nothing worked after that.
static void lcTellApp(SEL willSelector, SEL didSelector, BOOL floating) {
    if(!gAppController || gAppBelievesItIsFloating == floating) return;
    gAppBelievesItIsFloating = floating;
    @try {
        id delegate = [gAppController valueForKey:@"delegate"];
        if(!delegate) return;
        void (*tell)(id, SEL, id) = (void (*)(id, SEL, id))objc_msgSend;
        if([delegate respondsToSelector:willSelector]) tell(delegate, willSelector, gAppController);
        if([delegate respondsToSelector:didSelector]) tell(delegate, didSelector, gAppController);
        NSLog(@"[LCGuestPiP] told the app its PiP %s", floating ? "started" : "stopped");
    } @catch(NSException *exception) {
        NSLog(@"[LCGuestPiP] could not tell the app: %@", exception.name);
    }
}

static void lcTellAppFloating(void) {
    lcTellApp(@selector(pictureInPictureControllerWillStartPictureInPicture:),
              @selector(pictureInPictureControllerDidStartPictureInPicture:), YES);
}

static void lcTellAppNotFloating(void) {
    lcTellApp(@selector(pictureInPictureControllerWillStopPictureInPicture:),
              @selector(pictureInPictureControllerDidStopPictureInPicture:), NO);
}

#pragma mark - Hooks

static void (*orig_startPictureInPicture)(id, SEL);
static void lc_startPictureInPicture(id self, SEL _cmd) {
    // Not forwarded. Calling through is what produces the empty window.
    gAppController = self;
    uint64_t payload = lcVideoPayload(self);
    NSLog(@"[LCGuestPiP] start requested, handing to host (context %u, %ux%u)",
          (uint32_t)payload, (uint32_t)((payload >> 32) & 0xFFFF), (uint32_t)((payload >> 48) & 0xFFFF));
    gIntendedPlaying = YES;
    if(payload != 0) lcStartPublishingPlaybackState();
    lcRequestFloat(payload);
    // After the request, so the app's placeholder appears as its video leaves,
    // and its player and playback delegate stay alive for the host to drive.
    if(payload != 0) lcTellAppFloating();
}

/// The app's own answer is no — it never started one — but as far as it is
/// concerned its PiP is running, and code that checks this before offering to
/// stop or restore has to agree with the delegate calls it was just given.
static BOOL (*orig_isPictureInPictureActive)(id, SEL);
static BOOL lc_isPictureInPictureActive(id self, SEL _cmd) {
    if(self == gAppController && gAppBelievesItIsFloating) return YES;
    return orig_isPictureInPictureActive ? orig_isPictureInPictureActive(self, _cmd) : NO;
}

static void (*orig_stopPictureInPicture)(id, SEL);
static void lc_stopPictureInPicture(id self, SEL _cmd) {
    // Ignored while the window is floating, and that is not a corner case: the
    // app ends its own PiP a second or two after being told it began, every time.
    // Its scene is pinned foreground so that it keeps drawing the video the host
    // is showing, and an app whose scene is foreground concludes that the user has
    // come back to it — and coming back to an app is exactly when a player is
    // supposed to leave PiP. It is reasoning correctly from a foreground state
    // that was arranged for other purposes.
    //
    // So the app does not get to end this. What ends it is the PiP window's own
    // close or restore button, which arrives from the host as `.ended`.
    if(gAppBelievesItIsFloating) {
        NSLog(@"[LCGuestPiP] app asked to stop while floating; ignored");
        return;
    }
    NSLog(@"[LCGuestPiP] stop requested, handing to host");
    lcUnpublishVideoContext();
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
    bool active = lcHookMethod(controllerClass, @selector(isPictureInPictureActive),
                               (IMP)lc_isPictureInPictureActive, &orig_isPictureInPictureActive);

    NSLog(@"[LCGuestPiP] controller hooks installed (start=%d stop=%d automatic=%d active=%d)",
          start, stop, automatic, active);
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
    gEndedName = [base stringByAppendingString:@".ended"];
    gStateName = [base stringByAppendingString:@".state"];
    // One name each. Sharing a single name lost a skip whenever AVKit sent it
    // alongside a play, which it does in the same millisecond.
    gPlayName = [base stringByAppendingString:@".command.play"];
    gSkipName = [base stringByAppendingString:@".command.skip"];
    gVideoRectName = [base stringByAppendingString:@".videorect"];

    lcInstallHooks();
    _dyld_register_func_for_add_image(lcPiPImageAdded);

    // The only way back. While a window is floating the app's video layer is not
    // in the app's own tree, and PiP usually ends by a route the app never hears
    // about — the PiP window's own close or restore button — so without this the
    // layer would stay moved and the app would come back with no video in it.
    // On the main queue because it puts a layer back.
    static int endedToken;
    uint32_t status = notify_register_dispatch(gEndedName.UTF8String, &endedToken,
                                               dispatch_get_main_queue(), ^(int token) {
        lcUnpublishVideoContext();
    });

    // Play, pause and skip, arriving from the PiP window's own controls, on the
    // main queue because they end up inside the app's player.
    static int playToken, skipToken;
    uint32_t commandStatus = notify_register_dispatch(gPlayName.UTF8String, &playToken,
                                                      dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        lcHandlePlay((state & 1) != 0);
    });
    commandStatus |= notify_register_dispatch(gSkipName.UTF8String, &skipToken,
                                              dispatch_get_main_queue(), ^(int token) {
        uint64_t state = 0;
        notify_get_state(token, &state);
        int64_t deciseconds = (int64_t)(state & 0xFFFFFFFFFFFFULL);
        if(deciseconds & 0x800000000000ULL) deciseconds |= ~0xFFFFFFFFFFFFULL;
        lcHandleSkip(deciseconds);
    });

    NSLog(@"[LCGuestPiP] armed on %@ (ended %u, command %u)", base, status, commandStatus);
}
