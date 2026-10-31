// ClaudeTouchBar: puts a small Claude character in the Touch Bar's Control Strip,
// tinted by the most urgent state of all running Claude Code sessions.
// State comes from ~/.claude/touchbar/sessions/<session_id>.json, written by the hook CLI.
//
// Objective-C rather than Swift because this Mac's Command Line Tools ship a Swift
// compiler that does not match its SDK; clang builds this with no Xcode needed.

#import <AppKit/AppKit.h>
#include <dlfcn.h>
#include <signal.h>
#include <sys/sysctl.h>

// Private AppKit Touch Bar API (same calls MTMR / Pock use).
@interface NSTouchBarItem (ClaudeTBPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end
@interface NSTouchBar (ClaudeTBPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar placement:(long long)placement systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

// Private DFRFoundation C functions, loaded at runtime.
static void (*DFRSetPresence)(CFStringRef, Boolean);
static void (*DFRShowsCloseBox)(Boolean);

static NSString *const kTrayID = @"com.claude.touchbar.doll";
static NSString *const kListID = @"com.claude.touchbar.list";

// Done for this long turns into idle (blue).
static const NSTimeInterval kDoneToIdle = 10 * 60;
// Working with no hook activity for this long is probably an interrupted turn.
static const NSTimeInterval kWorkingStale = 20 * 60;
// Files untouched for this long are dropped.
static const NSTimeInterval kForget = 12 * 3600;

static NSString *StateDir(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@".claude/touchbar/sessions"];
}

// MARK: - State

typedef NS_ENUM(NSInteger, TBState) { TBIdle = 0, TBDone = 1, TBWorking = 2, TBAttention = 3 };

static TBState StateFromString(NSString *s) {
    if ([s isEqual:@"attention"]) return TBAttention;
    if ([s isEqual:@"working"]) return TBWorking;
    if ([s isEqual:@"done"]) return TBDone;
    if ([s isEqual:@"idle"]) return TBIdle;
    return -1;
}
static NSString *StateName(TBState s) {
    return @[@"idle", @"done", @"working", @"attention"][s];
}
static NSColor *StateColor(TBState s) {
    switch (s) {
        case TBAttention: return [NSColor colorWithSRGBRed:1.00 green:0.82 blue:0.10 alpha:1];
        case TBWorking: return [NSColor colorWithSRGBRed:0.96 green:0.50 blue:0.20 alpha:1];
        case TBDone: return [NSColor colorWithSRGBRed:0.25 green:0.80 blue:0.40 alpha:1];
        case TBIdle: return [NSColor colorWithSRGBRed:0.30 green:0.60 blue:1.00 alpha:1];
    }
}

@interface TBSession : NSObject
@property NSString *name;
@property TBState state;
@property NSDate *since;
@property pid_t pid;
@property NSString *hostSession;   // Claude desktop app's own id (local_…), if it runs there
@end
@implementation TBSession
@end

// Brings the session to the front: the exact session in the Claude desktop app, otherwise
// the app the session runs in (Terminal, iTerm, VS Code…), found by walking up its processes.
static void ShowSession(TBSession *s) {
    if (s.hostSession.length) {
        NSString *url = [NSString stringWithFormat:@"claude://code/continue?session=%@&source=touchbar", s.hostSession];
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:url]];
        return;
    }
    pid_t pid = s.pid;
    for (int i = 0; i < 20 && pid > 1; i++) {
        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        if (app && app.activationPolicy == NSApplicationActivationPolicyRegular) {
            [app activateWithOptions:NSApplicationActivateAllWindows];
            return;
        }
        struct kinfo_proc info;
        size_t size = sizeof(info);
        int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, pid};
        if (sysctl(mib, 4, &info, &size, NULL, 0) != 0 || size == 0) break;
        pid = info.kp_eproc.e_ppid;
    }
}

// The doll already says "Claude", so drop it from names: "claude-touchbar" -> "touchbar".
static NSString *DisplayName(NSString *name) {
    NSString *s = [name stringByReplacingOccurrencesOfString:@"[-_ .]*claude[-_ .]*" withString:@" "
                                                      options:NSRegularExpressionSearch | NSCaseInsensitiveSearch
                                                        range:NSMakeRange(0, name.length)];
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
}

static NSArray<TBSession *> *LoadSessions(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDate *now = [NSDate date];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *f in [fm contentsOfDirectoryAtPath:StateDir() error:nil]) {
        if (![f.pathExtension isEqual:@"json"]) continue;
        NSString *path = [StateDir() stringByAppendingPathComponent:f];
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *obj = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![obj isKindOfClass:NSDictionary.class]) continue;
        TBState state = StateFromString(obj[@"state"]);
        if ((NSInteger)state < 0) continue;
        NSDate *updated = [NSDate dateWithTimeIntervalSince1970:[obj[@"updated"] doubleValue]];
        NSDate *since = [NSDate dateWithTimeIntervalSince1970:[obj[@"since"] doubleValue]];
        pid_t pid = [obj[@"pid"] intValue];
        // Session's Claude process is gone, or the file is ancient: clean it up.
        if ((pid > 0 && kill(pid, 0) != 0 && errno == ESRCH) || [now timeIntervalSinceDate:updated] > kForget) {
            [fm removeItemAtPath:path error:nil];
            continue;
        }
        if (state == TBDone && [now timeIntervalSinceDate:since] > kDoneToIdle) {
            state = TBIdle;
            since = [since dateByAddingTimeInterval:kDoneToIdle];
        } else if (state == TBWorking && [now timeIntervalSinceDate:updated] > kWorkingStale) {
            state = TBIdle;
            since = updated;
        }
        TBSession *s = [TBSession new];
        s.name = DisplayName([obj[@"name"] isKindOfClass:NSString.class] ? obj[@"name"] : @"");
        s.state = state;
        s.since = since;
        s.pid = pid;
        s.hostSession = [obj[@"host_session"] isKindOfClass:NSString.class] ? obj[@"host_session"] : nil;
        [out addObject:s];
    }
    // Most urgent first; within a state, the one waiting longest first.
    [out sortUsingComparator:^NSComparisonResult(TBSession *a, TBSession *b) {
        if (a.state != b.state) return a.state > b.state ? NSOrderedAscending : NSOrderedDescending;
        return [a.since compare:b.since];
    }];
    return out;
}

static NSString *Elapsed(NSDate *since) {
    long s = MAX(0, (long)-[since timeIntervalSinceNow]);
    if (s < 60) return [NSString stringWithFormat:@"%lds", s];
    if (s < 3600) return [NSString stringWithFormat:@"%ldm", s / 60];
    return [NSString stringWithFormat:@"%ldh%ldm", s / 3600, s / 60 % 60];
}

// MARK: - Claude doll (pixel art)

// X = body, e = eye. Two frames so the legs can walk while working.
static NSArray<NSArray<NSString *> *> *DollFrames(void) {
    return @[
        @[@"..XXXXXXX..",
          @"..XeXXXeX..",
          @"..XeXXXeX..",
          @"XXXXXXXXXXX",
          @"XXXXXXXXXXX",
          @"..XXXXXXX..",
          @"..X.X.X.X..",
          @"..X.X.X.X.."],
        @[@"..XXXXXXX..",
          @"..XeXXXeX..",
          @"..XeXXXeX..",
          @"XXXXXXXXXXX",
          @"XXXXXXXXXXX",
          @"..XXXXXXX..",
          @"...X.X.X.X.",
          @"..X.X.X.X.."],
    ];
}

static NSImage *DollImage(NSColor *color, NSInteger frame) {
    NSArray<NSString *> *rows = DollFrames()[frame % 2];
    const CGFloat px = 2.5;
    NSSize size = NSMakeSize(rows[0].length * px, rows.count * px);
    return [NSImage imageWithSize:size flipped:YES drawingHandler:^BOOL(NSRect r) {
        for (NSUInteger y = 0; y < rows.count; y++) {
            for (NSUInteger x = 0; x < rows[y].length; x++) {
                unichar ch = [rows[y] characterAtIndex:x];
                if (ch == '.') continue;
                [(ch == 'e' ? NSColor.blackColor : color) setFill];
                NSRectFill(NSMakeRect(x * px, y * px, px, px));
            }
        }
        return YES;
    }];
}

// MARK: - App

@interface AppDelegate : NSObject <NSApplicationDelegate, NSTouchBarDelegate>
@property NSCustomTouchBarItem *trayItem;
@property NSButton *trayButton;
@property NSTouchBar *modalBar;
@property NSStackView *listStack;
@property NSArray<TBSession *> *sessions;
@property NSArray<TBSession *> *listSessions;   // what the list buttons currently show
@property NSInteger tick;
@property NSDate *modalShownAt;
@property NSDate *quietSince;   // when the last working / needs-you session finished
@property BOOL wasActive;       // something was working or waiting on you last tick
@property BOOL userClosed;      // you closed the list during the current burst of work
@property BOOL userOpened;      // you opened the list by tapping, so only you close it
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    [NSFileManager.defaultManager createDirectoryAtPath:StateDir() withIntermediateDirectories:YES attributes:nil error:nil];
    void *dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_NOW);
    DFRSetPresence = dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier");
    DFRShowsCloseBox = dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost");
    if (!DFRSetPresence || ![NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) {
        NSLog(@"ClaudeTouchBar: private Touch Bar API not available on this macOS");
        exit(1);
    }
    if (DFRShowsCloseBox) DFRShowsCloseBox(YES);

    self.sessions = @[];
    self.listStack = [NSStackView new];
    self.listStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    self.listStack.spacing = 8;

    self.trayButton = [NSButton buttonWithTitle:@"" image:DollImage(NSColor.grayColor, 0) target:self action:@selector(tapped)];
    self.trayButton.imagePosition = NSImageLeft;
    self.trayItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:kTrayID];
    self.trayItem.view = self.trayButton;
    [NSTouchBarItem addSystemTrayItem:self.trayItem];
    DFRSetPresence((__bridge CFStringRef)kTrayID, YES);

    // Re-assert the Control Strip item after sleep; the system sometimes drops it.
    [NSWorkspace.sharedWorkspace.notificationCenter addObserverForName:NSWorkspaceDidWakeNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            DFRSetPresence((__bridge CFStringRef)kTrayID, YES);
        }];
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [self refresh]; }];
    [self refresh];
}

- (void)refresh {
    self.tick++;
    if (self.tick % 2 == 1) self.sessions = LoadSessions();
    [self writeStatus];

    TBSession *top = self.sessions.firstObject;
    if (!top) {
        self.trayButton.image = DollImage([NSColor colorWithWhite:0.55 alpha:1], 0);
        self.trayButton.title = @"";
    } else {
        NSColor *color = StateColor(top.state);
        if (top.state == TBAttention && self.tick % 2 == 0) color = [color blendedColorWithFraction:0.55 ofColor:NSColor.blackColor];
        self.trayButton.image = DollImage(color, top.state == TBWorking ? self.tick : 0);
        NSString *others = self.sessions.count > 1 ? [NSString stringWithFormat:@" +%lu", self.sessions.count - 1] : @"";
        self.trayButton.title = [Elapsed(top.since) stringByAppendingString:others];
    }
    [self updateModal:top];
}

// The session list opens by itself when work starts, stays open while anything is working or
// waiting on you, and closes a few seconds after everything is done. Closing it yourself keeps
// it closed until the next round of work starts; opening it yourself keeps it open until you
// close it.
- (void)updateModal:(TBSession *)top {
    BOOL active = top && (top.state == TBWorking || top.state == TBAttention);
    NSDate *now = [NSDate date];

    // Closed with the ✕ (the system hid it without telling us).
    if (self.modalBar && !self.modalBar.visible && [now timeIntervalSinceDate:self.modalShownAt] > 1.5) {
        self.modalBar = nil;
        if (active) self.userClosed = YES;
    }
    if (active && !self.wasActive) self.userClosed = NO;
    self.wasActive = active;

    if (active) {
        self.quietSince = nil;
        if (!self.modalBar && !self.userClosed) [self openModal];
    } else if (!self.quietSince) {
        self.quietSince = now;
    }

    if (!self.modalBar) return;
    [self refreshList];
    if (!active && !self.userOpened && [now timeIntervalSinceDate:self.quietSince] > 5
        && [now timeIntervalSinceDate:self.modalShownAt] > 5) {
        [self closeModal];
    }
}

// Lets the test script check what the Touch Bar is showing.
- (void)writeStatus {
    TBSession *top = self.sessions.firstObject;
    NSString *s = top ? [NSString stringWithFormat:@"%@ %lu\n", StateName(top.state), self.sessions.count] : @"none 0\n";
    NSString *path = [StateDir().stringByDeletingLastPathComponent stringByAppendingPathComponent:@"status"];
    [s writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

- (void)tapped {
    if (self.modalBar) {
        if (self.wasActive) self.userClosed = YES;
        [self closeModal];
        return;
    }
    [self openModal];
    self.userOpened = YES;
}

- (void)openModal {
    self.userOpened = NO;
    NSTouchBar *bar = [NSTouchBar new];
    bar.delegate = self;
    bar.defaultItemIdentifiers = @[kListID];
    self.modalBar = bar;
    self.modalShownAt = [NSDate date];
    [self refreshList];
    [NSTouchBar presentSystemModalTouchBar:bar placement:1 systemTrayItemIdentifier:kTrayID];
}

- (void)closeModal {
    if (self.modalBar) [NSTouchBar dismissSystemModalTouchBar:self.modalBar];
    self.modalBar = nil;
    DFRSetPresence((__bridge CFStringRef)kTrayID, YES);
}

- (NSTouchBarItem *)touchBar:(NSTouchBar *)touchBar makeItemForIdentifier:(NSTouchBarItemIdentifier)identifier {
    if (![identifier isEqual:kListID]) return nil;
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = self.listStack;
    item.view = scroll;
    return item;
}

// The ✕ at the start of the list.
- (void)closeTapped {
    if (self.wasActive) self.userClosed = YES;
    [self closeModal];
}

// Tapping a session box opens that session on the main screen. The list stays open.
- (void)sessionTapped:(NSButton *)sender {
    if (sender.tag < (NSInteger)self.listSessions.count) ShowSession(self.listSessions[sender.tag]);
}

// The list bar: a ✕, then one button per session. Buttons are updated in place rather than
// rebuilt every tick, so a tap isn't lost when the list refreshes under your finger.
- (void)refreshList {
    self.listSessions = self.sessions;
    NSUInteger rows = MAX(self.sessions.count, 1);
    if (self.listStack.arrangedSubviews.count != rows + 1) {
        for (NSView *v in self.listStack.arrangedSubviews) [v removeFromSuperview];
        NSButton *close = [NSButton buttonWithTitle:@"✕" target:self action:@selector(closeTapped)];
        [self.listStack addArrangedSubview:close];
        for (NSUInteger i = 0; i < rows; i++) {
            NSButton *b = [NSButton buttonWithTitle:@"" target:self action:@selector(sessionTapped:)];
            b.imagePosition = NSImageLeft;
            b.tag = i;
            [self.listStack addArrangedSubview:b];
        }
    }
    NSArray<NSView *> *buttons = self.listStack.arrangedSubviews;
    if (self.sessions.count == 0) {
        NSButton *b = (NSButton *)buttons[1];
        b.title = @"No Claude sessions";
        b.image = DollImage(NSColor.grayColor, 0);
    }
    for (NSUInteger i = 0; i < self.sessions.count; i++) {
        TBSession *s = self.sessions[i];
        NSButton *b = (NSButton *)buttons[i + 1];
        // The doll's color already shows the state, so the text is just name and time.
        b.title = s.name.length ? [NSString stringWithFormat:@"%@ · %@", s.name, Elapsed(s.since)] : Elapsed(s.since);
        b.image = DollImage(StateColor(s.state), s.state == TBWorking ? self.tick : 0);
    }
    [self.listStack layoutSubtreeIfNeeded];
    [self.listStack setFrameSize:self.listStack.fittingSize];
}

@end

int main(void) {
    @autoreleasepool {
        NSApplication *app = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        app.delegate = delegate;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        [app run];
    }
    return 0;
}
