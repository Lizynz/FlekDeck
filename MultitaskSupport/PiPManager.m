//
//  PiPManager.m
//  LiveContainer
//
//  Created by s s on 2025/6/3.
//
#include "PiPManager.h"
#include "AppSceneViewController.h"
#include "DecoratedAppSceneViewController.h"
#include "../LiveContainer/utils.h"

static void *kPiPBoundsObservationContext = &kPiPBoundsObservationContext;

API_AVAILABLE(ios(16.0))
@interface PiPManager()
@property(nonatomic, strong) UIView *pipVideoCallContentView;
@property(nonatomic, strong) AVPictureInPictureVideoCallViewController *pipVideoCallViewController;
@property(nonatomic, strong) AVPictureInPictureController *pipController;
@property(nonatomic) AppSceneViewController* displayingVC;
/// The PiP window's layer, for as long as its bounds are being watched. Held
/// strongly on purpose: an observed object must not go away while the
/// observation stands, and the view controller that owns this layer is let go
/// of in more than one place.
@property(nonatomic, strong) CALayer *observedLayer;
/// Set from the moment PiP has been asked to start until it has finished
/// stopping, which is a window `isPictureInPictureActive` does not cover: it is
/// still NO throughout the start, including inside -willStart.
///
/// That gap matters because -willStart minimizes the window, which tells the dock
/// a window has left the stage, which changes what is frontmost — and arming
/// listens to exactly that. Without this the disarm that follows would release
/// the controller AVKit is in the middle of starting, and PiP would go Active and
/// stop again a few milliseconds later.
@property(nonatomic) BOOL isStartingPiP;
@end


@implementation PiPManager
API_AVAILABLE(ios(16.0))
static PiPManager* sharedInstance = nil;

+ (instancetype)shared {
    if(!sharedInstance)
        sharedInstance = [[self alloc] init];
    return sharedInstance;
}

+ (BOOL)hasShared {
    return sharedInstance != nil;
}

- (DecoratedAppSceneViewController *)displayingDecoratedVC {
    return (id)self.displayingVC.delegate;
}

- (BOOL)isPiP {
    return self.pipController.isPictureInPictureActive;
}

- (BOOL)isPiPWithVC:(AppSceneViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingVC == vc;
}

- (BOOL)isPiPWithDecoratedVC:(UIViewController*)vc {
    return self.pipController.isPictureInPictureActive && self.displayingDecoratedVC == vc;
}

/// Builds a controller bound to `vc`, ready to start but not started.
- (void)prepareControllerForVC:(AppSceneViewController*)vc {
    self.displayingVC = vc;
    self.pipVideoCallViewController = [AVPictureInPictureVideoCallViewController new];
    self.pipVideoCallViewController.preferredContentSize = vc.view.bounds.size;
    if(vc.usesHostingControllerAPI) {
        self.pipVideoCallContentView = [[UIView alloc] initWithFrame:self.pipVideoCallViewController.view.bounds];
        self.pipVideoCallContentView.layer.anchorPoint = CGPointMake(0, 0);
        self.pipVideoCallContentView.layer.position = CGPointMake(0, 0);
        [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
    } else {
        self.pipVideoCallContentView = vc.contentView;
    }
    AVPictureInPictureControllerContentSource* contentSource = [[AVPictureInPictureControllerContentSource alloc] initWithActiveVideoCallSourceView:vc.view contentViewController:self.pipVideoCallViewController];
    self.pipController = [[AVPictureInPictureController alloc] initWithContentSource:contentSource];
    self.pipController.canStartPictureInPictureAutomaticallyFromInline = YES;
    self.pipController.delegate = self;
    [self.pipController setValue:@1 forKey:@"controlsStyle"];
}

/// Readies `vc` to float without floating it.
///
/// `canStartPictureInPictureAutomaticallyFromInline` is what makes a window float
/// when LiveContainer is backgrounded, and AVKit can only act on it through a
/// controller that already exists. Building one only when PiP is chosen from a
/// menu meant that by the time there was anything to act on, the user was already
/// looking at the home screen. So the window in front keeps a controller ready at
/// all times, and leaving LiveContainer is enough.
///
/// Only ever one: the system allows a single PiP window, and a controller armed
/// on a window the user is not looking at would race the one they are.
- (void)armForVC:(AppSceneViewController*)vc {
    if(!vc) return;
    // A live PiP window — or one on its way to being live — outranks whatever is
    // now in front behind it. It was put there deliberately and re-arming would
    // tear it down.
    if(self.isPiP || self.isStartingPiP) return;
    if(self.pipController && self.displayingVC == vc) return;
    // On stage, but its guest has not presented a scene yet — a window is brought
    // to the front the moment it is created, which is well before there is
    // anything in it to float. Binding a controller to that would capture a
    // content view that does not exist. `appSceneVCDidPresentScene:` asks again
    // once it does.
    if(!vc.contentView) return;
    [self prepareControllerForVC:vc];
}

/// Drops the armed controller, unless PiP is running on it or starting.
- (void)disarmIfInactive {
    if(self.isPiP || self.isStartingPiP) return;
    self.pipController = nil;
    self.pipVideoCallViewController = nil;
    self.pipVideoCallContentView = nil;
    self.displayingVC = nil;
}

- (void)disarmIfInactiveForVC:(AppSceneViewController*)vc {
    // Someone else's turn to be armed; leaving it alone is the point of asking.
    if(self.displayingVC != vc) return;
    [self disarmIfInactive];
}

- (void)startPiPWithVC:(AppSceneViewController*)vc {
    // Already armed for this window, which is now the ordinary case: the window
    // in front keeps a controller ready. Nothing to tear down and nothing to wait
    // for, so it starts at once rather than after the two delays below.
    if(self.pipController && self.displayingVC == vc && !self.isPiP) {
        self.isStartingPiP = YES;
        [self.pipController startPictureInPicture];
        return;
    }
    BOOL wasActive = self.isPiP;
    [self.pipController stopPictureInPicture];
    // Only a window that was really floating has to be brought back. An armed one
    // was never minimized, and telling the dock a window has left a PiP it never
    // entered leaves the switcher believing something that is not so.
    if(self.displayingVC && wasActive) {
        [self.displayingDecoratedVC unminimizeWindowPiP];
        [self pictureInPictureControllerDidStopPictureInPicture:self.pipController];
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wasActive * 0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self prepareControllerForVC:vc];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            self.isStartingPiP = YES;
            [self.pipController startPictureInPicture];
        });
    });

}

- (void)stopPiP {
    [self.pipController stopPictureInPicture];
}

// PIP delegate
- (void)pictureInPictureControllerWillStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // The one place both routes into PiP meet — chosen from a window's menu, or
    // started by AVKit because LiveContainer was backgrounded with a window
    // armed — and where a start AVKit began on its own is first heard about.
    //
    // Set before minimizing, which is what sets off the chain that would
    // otherwise disarm this controller mid-start.
    //
    // No audio session is taken here. LiveContainer used to claim one — playback,
    // not mixable, activated — on the reasoning that PiP had to keep running once
    // the app was backgrounded and a mixable session would not survive that. What
    // actually keeps it running is the assertion SpringBoard takes on this
    // process for the duration:
    //
    //     PGProcessAssertion … PIP Visible Assertion target: <our pid>
    //         domain:"com.apple.pictureinpicture" name:"PIPVisible"
    //
    // The host never plays anything, so its session only ever did one thing:
    // interrupt the guest whose window was about to float, stopping the playback
    // the user floated it to keep watching. If a PiP window is ever found dying
    // on backgrounding again, take a *mixable* session rather than this one —
    // secondary audio costs the guest nothing.
    self.isStartingPiP = YES;
    [self.displayingDecoratedVC minimizeWindowPiP];
    if(self.displayingVC.usesHostingControllerAPI) {
        self.pipVideoCallContentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
        self.pipVideoCallViewController.additionalSafeAreaInsets = self.displayingVC.view.safeAreaInsets;
        [self.pipVideoCallContentView addSubview:self.displayingVC.contentView];
    } else {
        self.displayingVC.contentView.frame = CGRectMake(0, 0, self.displayingVC.view.bounds.size.width, self.displayingVC.view.bounds.size.height);
    }
    [self.pipVideoCallViewController.view addSubview:self.pipVideoCallContentView];
    [self observeBoundsOfLayer:self.pipVideoCallViewController.view.layer];
    self.pipVideoCallViewController.preferredContentSize = self.displayingVC.view.bounds.size;
    [self.displayingVC setBackgroundNotificationEnabled:false];
    self.displayingVC.shouldIgnoreSceneUpdates = YES;
}



- (void)pictureInPictureControllerDidStartPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    
}

- (void)pictureInPictureControllerWillStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    self.displayingVC.shouldIgnoreSceneUpdates = NO;
    [self.displayingDecoratedVC unminimizeWindowPiP];
}

- (void)pictureInPictureControllerDidStopPictureInPicture:(AVPictureInPictureController *)pictureInPictureController {
    // A controller already replaced — PiP handed from one window to another
    // before its stop came back — has nothing here that is still its own: the
    // window, the content view and the layer under observation all belong to
    // its successor now.
    if(pictureInPictureController != self.pipController) return;
    self.isStartingPiP = NO;
    [self.displayingVC.view insertSubview:self.displayingVC.contentView atIndex:0];
    [self.displayingVC setBackgroundNotificationEnabled:true];
    // resize if needed (eg orientation differs)
    [self.displayingDecoratedVC updateVerticalConstraints];
    
    self.pipVideoCallContentView.transform = CGAffineTransformIdentity;
    // Before the view controller can be released below with the observation
    // still registered on its layer, which is a crash — and just the same when
    // it is kept: the next start watches a fresh layer, and this one is done.
    [self observeBoundsOfLayer:nil];
    if([NSUserDefaults.lcSharedDefaults boolForKey:@"LCAutoEndPiP"]) {
        self.pipController = nil;
        self.pipVideoCallViewController = nil;
    }
    // FIXME: HostingController path causes a tiny flicker during transition to and from PiP.
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController restoreUserInterfaceForPictureInPictureStopWithCompletionHandler:(void (^)(BOOL))completionHandler {
    // The PiP window's own restore button, and the system's cue to put the
    // interface back for the content that was floating — with LiveContainer
    // brought to the foreground for it if it was in the background. AVKit waits
    // on the answer before it finishes the PiP window's exit, so the answer
    // waits on the window's fade: there is then something on stage where the
    // PiP window is headed. -willStop brings the window back as well, and both
    // run for a press of this button; the return is harmless to repeat.
    DecoratedAppSceneViewController *decoratedVC = self.displayingDecoratedVC;
    if(!decoratedVC) {
        completionHandler(YES);
        return;
    }
    [decoratedVC unminimizeWindowPiPWithCompletion:^{
        completionHandler(YES);
    }];
}

- (void)pictureInPictureController:(AVPictureInPictureController *)pictureInPictureController failedToStartPictureInPictureWithError:(NSError *)error {
    // A start that never became one: nothing is holding this controller now, and
    // leaving the flag set would keep the window armed on it forever.
    self.isStartingPiP = NO;
    NSLog(@"%@", error.description);
}

/// Watches `layer`'s bounds, and stops watching whichever layer was being
/// watched before — nil to only stop. Every start and stop goes through here,
/// so the observation is registered exactly once per layer however the AVKit
/// callbacks arrive: -willStart can run without a -didStop (a start that
/// fails), and -didStop can run twice for one stop (once called directly when
/// PiP is handed from one window to another, once from AVKit).
- (void)observeBoundsOfLayer:(CALayer *)layer {
    if(self.observedLayer == layer) return;
    [self.observedLayer removeObserver:self forKeyPath:@"bounds" context:kPiPBoundsObservationContext];
    self.observedLayer = layer;
    [layer addObserver:self forKeyPath:@"bounds" options:NSKeyValueObservingOptionNew context:kPiPBoundsObservationContext];
}

- (void)observeValueForKeyPath:(NSString*)keyPath ofObject:(NSObject*)object change:(NSDictionary<NSString *,id> *) change context:(void *) context {
    if(context != kPiPBoundsObservationContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    CGRect rect = [change[@"new"] CGRectValue];
    CGFloat scale = self.displayingVC.usesHostingControllerAPI ? self.displayingVC.scaleRatio : 1;
    CGAffineTransform transform1 = CGAffineTransformScale(CGAffineTransformIdentity, rect.size.width / self.displayingVC.contentView.bounds.size.width/scale,rect.size.height /self.displayingVC.contentView.bounds.size.height/scale);
    self.pipVideoCallContentView.transform = transform1;
}

@end
