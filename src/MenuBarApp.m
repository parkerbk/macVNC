/*
 * macVNC – Menu Bar UI
 *
 * MenuBarApp.m – AppDelegate implementation for the macVNCUI menu-bar wrapper.
 *
 * This application locates the bundled macVNC CLI binary, manages it as an
 * NSTask subprocess, and exposes its configuration through an NSStatusItem
 * menu.  Settings are persisted in NSUserDefaults; the VNC password is stored
 * in the macOS Keychain.
 *
 * Copyright © 2024 The macVNC Contributors.
 * Licensed under the GNU GPL version 2.  See COPYING for details.
 */

#import "MenuBarApp.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Security/Security.h>

/* ── NSUserDefaults keys ─────────────────────────────────────────────────── */
static NSString * const kPrefPort        = @"port";
static NSString * const kPrefViewOnly    = @"viewOnly";
static NSString * const kPrefDisplayIdx  = @"displayIndex";

/* ── Keychain service label ──────────────────────────────────────────────── */
static NSString * const kKeychainService = @"com.github.libvnc.macVNC";
static NSString * const kKeychainAccount = @"vncPassword";

/* ── Default values ──────────────────────────────────────────────────────── */
static const NSInteger kDefaultPort        = 5900;
static const NSInteger kDefaultDisplayIdx  = -1;   /* -1 = primary */

/* ── Keychain helpers ────────────────────────────────────────────────────── */

static NSString *keychainLoadPassword(void)
{
    NSDictionary *query = @{
        (__bridge id)kSecClass:            (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService:      kKeychainService,
        (__bridge id)kSecAttrAccount:      kKeychainAccount,
        (__bridge id)kSecReturnData:       @YES,
        (__bridge id)kSecMatchLimit:       (__bridge id)kSecMatchLimitOne,
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (status == errSecSuccess && result) {
        NSData *data = (__bridge_transfer NSData *)result;
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
    }
    return @"";
}

static void keychainSavePassword(NSString *password)
{
    NSData *data = [password dataUsingEncoding:NSUTF8StringEncoding];

    /* Try updating an existing item first. */
    NSDictionary *query = @{
        (__bridge id)kSecClass:       (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: kKeychainService,
        (__bridge id)kSecAttrAccount: kKeychainAccount,
    };
    NSDictionary *attrs = @{
        (__bridge id)kSecValueData: data,
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query,
                                    (__bridge CFDictionaryRef)attrs);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *newItem = [query mutableCopy];
        newItem[(__bridge id)kSecValueData] = data;
        SecItemAdd((__bridge CFDictionaryRef)newItem, NULL);
    }
}

/* ── Helpers ─────────────────────────────────────────────────────────────── */

/* Returns the path to the bundled macVNC CLI binary, or nil if not found. */
static NSString *macVNCBinaryPath(void)
{
    /* When running inside macVNCUI.app the CLI binary is embedded at
       Contents/MacOS/macVNC next to the macVNCUI executable. */
    NSString *bundleDir = [[[NSBundle mainBundle] executablePath]
                           stringByDeletingLastPathComponent];
    NSString *candidate = [bundleDir stringByAppendingPathComponent:@"macVNC"];
    if ([[NSFileManager defaultManager] isExecutableFileAtPath:candidate])
        return candidate;

    /* Fall back to a Homebrew / PATH install. */
    for (NSString *dir in @[@"/usr/local/bin", @"/opt/homebrew/bin", @"/usr/bin"]) {
        NSString *p = [dir stringByAppendingPathComponent:@"macVNC"];
        if ([[NSFileManager defaultManager] isExecutableFileAtPath:p])
            return p;
    }
    return nil;
}

/* Returns the path to the LaunchAgent plist (mirrors mac.m). */
static NSString *launchAgentPlistPath(void)
{
    return [NSHomeDirectory()
            stringByAppendingPathComponent:
            @"Library/LaunchAgents/com.github.libvnc.macVNC.plist"];
}

/* Run launchctl synchronously and return its exit status. */
static int runLaunchctl(NSArray<NSString *> *args)
{
    NSTask *t = [[NSTask alloc] init];
    t.launchPath = @"/bin/launchctl";
    t.arguments  = args;
    [t launch];
    [t waitUntilExit];
    return t.terminationStatus;
}

/* ── Implementation ──────────────────────────────────────────────────────── */

@implementation MenuBarAppDelegate
{
    NSStatusItem   *_statusItem;
    NSMenu         *_menu;

    /* Server subprocess */
    NSTask         *_serverTask;
    NSPipe         *_logPipe;
    NSMutableString *_logBuffer;

    /* Log window */
    NSWindow       *_logWindow;
    NSTextView     *_logTextView;

    /* Frequently-updated menu items */
    NSMenuItem     *_toggleItem;     /* Start / Stop */
    NSMenuItem     *_statusItem2;    /* "Running" / "Stopped" label */
    NSMenuItem     *_startAtLoginItem;
    NSMenuItem     *_viewOnlyItem;
    NSMenuItem     *_portItem;       /* shows current port */
    NSMenuItem     *_passwordItem;
    NSMenuItem     *_displayMenu;    /* submenu parent */
}

/* ── NSApplicationDelegate ──────────────────────────────────────────────── */

- (void)applicationDidFinishLaunching:(NSNotification *)note
{
    [self registerDefaults];
    [self buildMenu];
    [self buildStatusItem];
    [self updateMenuState];
}

- (void)applicationWillTerminate:(NSNotification *)note
{
    [self stopServer];
}

/* ── Defaults ────────────────────────────────────────────────────────────── */

- (void)registerDefaults
{
    [[NSUserDefaults standardUserDefaults] registerDefaults:@{
        kPrefPort:       @(kDefaultPort),
        kPrefViewOnly:   @NO,
        kPrefDisplayIdx: @(kDefaultDisplayIdx),
    }];
}

/* ── Status item ─────────────────────────────────────────────────────────── */

- (void)buildStatusItem
{
    _statusItem = [[NSStatusBar systemStatusBar]
                   statusItemWithLength:NSVariableStatusItemLength];
    _statusItem.menu = _menu;
    [self refreshStatusIcon:NO];
}

- (void)refreshStatusIcon:(BOOL)running
{
    NSString *name = running ? @"dot.radiowaves.left.and.right"
                              : @"antenna.radiowaves.left.and.right";
    NSImage *img = [NSImage imageWithSystemSymbolName:name
                             accessibilityDescription:running ? @"VNC running"
                                                               : @"VNC stopped"];
    if (!img) {
        /* Fallback text button for older macOS */
        _statusItem.button.title = running ? @"VNC●" : @"VNC○";
        _statusItem.button.image = nil;
    } else {
        img.template = YES;
        _statusItem.button.image = img;
        _statusItem.button.title = @"";
    }
    _statusItem.button.toolTip = running ? @"macVNC – Running" : @"macVNC – Stopped";
}

/* ── Menu construction ───────────────────────────────────────────────────── */

- (void)buildMenu
{
    _menu = [[NSMenu alloc] init];
    _menu.delegate = self;
    _menu.autoenablesItems = NO;

    /* Status label */
    _statusItem2 = [[NSMenuItem alloc] initWithTitle:@"Stopped"
                                              action:nil
                                       keyEquivalent:@""];
    _statusItem2.enabled = NO;
    [_menu addItem:_statusItem2];

    [_menu addItem:[NSMenuItem separatorItem]];

    /* Start / Stop */
    _toggleItem = [[NSMenuItem alloc] initWithTitle:@"Start VNC Server"
                                             action:@selector(toggleServer:)
                                      keyEquivalent:@""];
    _toggleItem.target = self;
    [_menu addItem:_toggleItem];

    [_menu addItem:[NSMenuItem separatorItem]];

    /* ── Settings ── */
    NSMenuItem *settingsHeader = [[NSMenuItem alloc] initWithTitle:@"Settings"
                                                            action:nil
                                                     keyEquivalent:@""];
    settingsHeader.enabled = NO;
    [_menu addItem:settingsHeader];

    /* Port */
    _portItem = [[NSMenuItem alloc] initWithTitle:@"Port: 5900"
                                           action:@selector(changePort:)
                                    keyEquivalent:@""];
    _portItem.target = self;
    [_menu addItem:_portItem];

    /* Password */
    _passwordItem = [[NSMenuItem alloc] initWithTitle:@"Set Password…"
                                               action:@selector(changePassword:)
                                        keyEquivalent:@""];
    _passwordItem.target = self;
    [_menu addItem:_passwordItem];

    /* View Only */
    _viewOnlyItem = [[NSMenuItem alloc] initWithTitle:@"View Only"
                                               action:@selector(toggleViewOnly:)
                                        keyEquivalent:@""];
    _viewOnlyItem.target = self;
    [_menu addItem:_viewOnlyItem];

    /* Display submenu */
    _displayMenu = [[NSMenuItem alloc] initWithTitle:@"Display"
                                              action:nil
                                       keyEquivalent:@""];
    [_menu addItem:_displayMenu];
    [self rebuildDisplaySubmenu];

    [_menu addItem:[NSMenuItem separatorItem]];

    /* ── Autostart ── */
    _startAtLoginItem = [[NSMenuItem alloc] initWithTitle:@"Start at Login"
                                                   action:@selector(toggleStartAtLogin:)
                                            keyEquivalent:@""];
    _startAtLoginItem.target = self;
    [_menu addItem:_startAtLoginItem];

    [_menu addItem:[NSMenuItem separatorItem]];

    /* View Log */
    NSMenuItem *logItem = [[NSMenuItem alloc] initWithTitle:@"View Log…"
                                                     action:@selector(showLog:)
                                              keyEquivalent:@""];
    logItem.target = self;
    [_menu addItem:logItem];

    [_menu addItem:[NSMenuItem separatorItem]];

    /* Quit */
    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit macVNC"
                                                      action:@selector(quitApp:)
                                               keyEquivalent:@"q"];
    quitItem.target = self;
    [_menu addItem:quitItem];
}

/* Rebuild the Display submenu from the live display list. */
- (void)rebuildDisplaySubmenu
{
    NSMenu *sub = [[NSMenu alloc] init];
    NSInteger selectedIdx = [[NSUserDefaults standardUserDefaults]
                             integerForKey:kPrefDisplayIdx];

    /* "Primary (default)" option */
    NSMenuItem *primaryItem = [[NSMenuItem alloc]
                               initWithTitle:@"Primary (default)"
                                      action:@selector(selectDisplay:)
                               keyEquivalent:@""];
    primaryItem.target = self;
    primaryItem.tag    = -1;
    primaryItem.state  = (selectedIdx == -1) ? NSControlStateValueOn
                                             : NSControlStateValueOff;
    [sub addItem:primaryItem];

    CGDisplayCount count = 0;
    CGDirectDisplayID ids[32];
    CGGetActiveDisplayList(32, ids, &count);

    for (NSInteger i = 0; i < (NSInteger)count; i++) {
        CGRect b = CGDisplayBounds(ids[i]);
        NSString *title = [NSString stringWithFormat:@"Display %ld  (%dx%d)",
                           (long)i,
                           (int)b.size.width,
                           (int)b.size.height];
        NSMenuItem *it = [[NSMenuItem alloc] initWithTitle:title
                                                    action:@selector(selectDisplay:)
                                             keyEquivalent:@""];
        it.target = self;
        it.tag    = i;
        it.state  = (selectedIdx == i) ? NSControlStateValueOn
                                       : NSControlStateValueOff;
        [sub addItem:it];
    }

    _displayMenu.submenu = sub;
}

/* ── NSMenuDelegate – refresh dynamic state before menu opens ────────────── */

- (void)menuWillOpen:(NSMenu *)menu
{
    [self updateMenuState];
    [self rebuildDisplaySubmenu];
}

/* Sync all dynamic item titles / checkmarks from current state. */
- (void)updateMenuState
{
    BOOL running = [self isServerRunning];
    [self refreshStatusIcon:running];

    _statusItem2.title = running ? @"● Running" : @"○ Stopped";
    _toggleItem.title  = running ? @"Stop VNC Server" : @"Start VNC Server";

    NSInteger port = [[NSUserDefaults standardUserDefaults]
                      integerForKey:kPrefPort];
    _portItem.title = [NSString stringWithFormat:@"Port: %ld…", (long)port];

    BOOL viewOnly = [[NSUserDefaults standardUserDefaults]
                     boolForKey:kPrefViewOnly];
    _viewOnlyItem.state = viewOnly ? NSControlStateValueOn : NSControlStateValueOff;

    /* Start at Login: plist file presence is the ground truth */
    BOOL hasLaunchAgent = [[NSFileManager defaultManager]
                           fileExistsAtPath:launchAgentPlistPath()];
    _startAtLoginItem.state = hasLaunchAgent ? NSControlStateValueOn
                                             : NSControlStateValueOff;
}

/* ── Server lifecycle ────────────────────────────────────────────────────── */

- (BOOL)isServerRunning
{
    return _serverTask != nil && _serverTask.isRunning;
}

/*
 * Build the argument list for the macVNC CLI binary from the current
 * NSUserDefaults settings.  When withInstallFlag is YES, "-install" is
 * prepended so the same helper can be used for autostart registration.
 *
 * Password handling: to avoid exposing the password in the process table
 * (visible via `ps aux`), we write it to a mode-0600 temporary file and pass
 * "-passwdfile <path>" instead of "-passwd <secret>".  The file is deleted
 * after the task exits (caller's responsibility) – callers receive the temp
 * file path via outPasswordFile (may be nil if no password is set).
 */
- (NSMutableArray<NSString *> *)buildServerArguments:(BOOL)withInstallFlag
                                    passwordTempFile:(NSString *__autoreleasing *)outPasswordFile
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    NSMutableArray<NSString *> *args = [NSMutableArray array];

    if (withInstallFlag)
        [args addObject:@"-install"];

    NSInteger port = [ud integerForKey:kPrefPort];
    [args addObjectsFromArray:@[@"-rfbport", [NSString stringWithFormat:@"%ld", (long)port]]];

    NSString *password = keychainLoadPassword();
    if (password.length > 0) {
        /* Write to a restricted temp file so the secret stays off the process table. */
        NSString *tmpPath = [NSTemporaryDirectory()
                             stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"macvnc_passwd_%d", (int)getpid()]];
        NSError *err = nil;
        if ([password writeToFile:tmpPath
                       atomically:YES
                         encoding:NSUTF8StringEncoding
                            error:&err]) {
            /* chmod 600 so only the current user can read it */
            [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0600)}
                                             ofItemAtPath:tmpPath
                                                    error:nil];
            [args addObjectsFromArray:@[@"-passwdfile", tmpPath]];
            if (outPasswordFile)
                *outPasswordFile = tmpPath;
        } else {
            /* Fall back to the direct argument if the temp file fails */
            [args addObjectsFromArray:@[@"-passwd", password]];
            if (outPasswordFile)
                *outPasswordFile = nil;
        }
    } else {
        if (outPasswordFile)
            *outPasswordFile = nil;
    }

    if ([ud boolForKey:kPrefViewOnly])
        [args addObject:@"-viewonly"];

    NSInteger displayIdx = [ud integerForKey:kPrefDisplayIdx];
    if (displayIdx >= 0)
        [args addObjectsFromArray:@[@"-display", [NSString stringWithFormat:@"%ld", (long)displayIdx]]];

    return args;
}

- (void)startServer
{
    if ([self isServerRunning])
        return;

    NSString *binary = macVNCBinaryPath();
    if (!binary) {
        [self showAlert:@"macVNC binary not found"
            information:@"Could not locate the macVNC binary.\n"
                         "Make sure macVNCUI.app is installed correctly or that macVNC is in /usr/local/bin."];
        return;
    }

    NSString *passwordTmpFile = nil;
    NSMutableArray<NSString *> *args = [self buildServerArguments:NO
                                                 passwordTempFile:&passwordTmpFile];

    _logBuffer = [NSMutableString string];
    _logPipe   = [NSPipe pipe];

    _serverTask = [[NSTask alloc] init];
    _serverTask.launchPath      = binary;
    _serverTask.arguments       = args;
    _serverTask.standardOutput  = _logPipe;
    _serverTask.standardError   = _logPipe;

    /* Clean up the password temp file once the task exits. */
    NSString *tmpFileToDelete = [passwordTmpFile copy];
    _serverTask.terminationHandler = ^(NSTask *task) {
        if (tmpFileToDelete)
            [[NSFileManager defaultManager] removeItemAtPath:tmpFileToDelete error:nil];
    };

    /* Observe task termination so we can update the menu. */
    [[NSNotificationCenter defaultCenter]
     addObserver:self
        selector:@selector(serverTaskDidTerminate:)
            name:NSTaskDidTerminateNotification
          object:_serverTask];

    /* Stream log output asynchronously. */
    [_logPipe.fileHandleForReading
     readInBackgroundAndNotify];
    [[NSNotificationCenter defaultCenter]
     addObserver:self
        selector:@selector(logDataAvailable:)
            name:NSFileHandleReadCompletionNotification
          object:_logPipe.fileHandleForReading];

    [_serverTask launch];
    [self updateMenuState];
}

- (void)stopServer
{
    if (![self isServerRunning])
        return;

    [[NSNotificationCenter defaultCenter]
     removeObserver:self
                name:NSTaskDidTerminateNotification
              object:_serverTask];

    [_serverTask terminate];
    [_serverTask waitUntilExit];
    _serverTask = nil;
    [self updateMenuState];
}

- (void)serverTaskDidTerminate:(NSNotification *)note
{
    _serverTask = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateMenuState];
    });
}

/* ── Log handling ────────────────────────────────────────────────────────── */

- (void)logDataAvailable:(NSNotification *)note
{
    NSData *data = note.userInfo[NSFileHandleNotificationDataItem];
    if (data.length) {
        NSString *s = [[NSString alloc] initWithData:data
                                            encoding:NSUTF8StringEncoding];
        if (s) {
            /* Dispatch both the buffer append and the view update to the main
               queue so _logBuffer is only ever accessed on one thread. */
            dispatch_async(dispatch_get_main_queue(), ^{
                [_logBuffer appendString:s];
                [self appendToLogView:s];
            });
        }
        /* Keep reading. */
        [note.object readInBackgroundAndNotify];
    }
}

- (void)appendToLogView:(NSString *)text
{
    if (!_logTextView)
        return;
    NSTextStorage *ts = _logTextView.textStorage;
    [ts appendAttributedString:[[NSAttributedString alloc]
                                initWithString:text
                                    attributes:@{NSFontAttributeName:
                                                 [NSFont userFixedPitchFontOfSize:11]}]];
    [_logTextView scrollToEndOfDocument:nil];
}

/* ── Menu actions ────────────────────────────────────────────────────────── */

- (IBAction)toggleServer:(id)sender
{
    if ([self isServerRunning])
        [self stopServer];
    else
        [self startServer];
}

- (IBAction)changePort:(id)sender
{
    NSUserDefaults *ud   = [NSUserDefaults standardUserDefaults];
    NSInteger currentPort = [ud integerForKey:kPrefPort];

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"VNC Port";
    alert.informativeText = @"Enter the TCP port for the VNC server (1–65535):";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    field.stringValue = [NSString stringWithFormat:@"%ld", (long)currentPort];
    alert.accessoryView = field;
    [field selectText:nil];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        NSInteger newPort = [field.stringValue integerValue];
        if (newPort < 1 || newPort > 65535) {
            [self showAlert:@"Invalid port" information:@"Please enter a number between 1 and 65535."];
            return;
        }
        [ud setInteger:newPort forKey:kPrefPort];
        [self updateMenuState];
        if ([self isServerRunning]) {
            [self stopServer];
            [self startServer];
        }
    }
}

- (IBAction)changePassword:(id)sender
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = @"VNC Password";
    alert.informativeText = @"Enter a password for VNC connections (leave blank for none):";
    [alert addButtonWithTitle:@"OK"];
    [alert addButtonWithTitle:@"Cancel"];

    NSSecureTextField *field = [[NSSecureTextField alloc] initWithFrame:NSMakeRect(0, 0, 200, 24)];
    field.stringValue = keychainLoadPassword();
    alert.accessoryView = field;
    [field selectText:nil];

    if ([alert runModal] == NSAlertFirstButtonReturn) {
        keychainSavePassword(field.stringValue);
        if ([self isServerRunning]) {
            [self stopServer];
            [self startServer];
        }
    }
}

- (IBAction)toggleViewOnly:(id)sender
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    BOOL current = [ud boolForKey:kPrefViewOnly];
    [ud setBool:!current forKey:kPrefViewOnly];
    [self updateMenuState];
    if ([self isServerRunning]) {
        [self stopServer];
        [self startServer];
    }
}

- (IBAction)selectDisplay:(NSMenuItem *)sender
{
    NSInteger idx = sender.tag;   /* -1 = primary */
    [[NSUserDefaults standardUserDefaults] setInteger:idx forKey:kPrefDisplayIdx];
    [self rebuildDisplaySubmenu];
    if ([self isServerRunning]) {
        [self stopServer];
        [self startServer];
    }
}

- (IBAction)toggleStartAtLogin:(id)sender
{
    NSString *binary = macVNCBinaryPath();
    if (!binary) {
        [self showAlert:@"macVNC binary not found"
            information:@"Cannot configure autostart: macVNC binary not found."];
        return;
    }

    BOOL hasLaunchAgent = [[NSFileManager defaultManager]
                           fileExistsAtPath:launchAgentPlistPath()];

    if (hasLaunchAgent) {
        /* Uninstall: delegate to the binary's -uninstall path */
        NSTask *t = [[NSTask alloc] init];
        t.launchPath = binary;
        t.arguments  = @[@"-uninstall"];
        [t launch];
        [t waitUntilExit];
    } else {
        /* Install: build the same args the server would use and call -install */
        NSString *passwordTmpFile = nil;
        NSMutableArray<NSString *> *args = [self buildServerArguments:YES
                                                     passwordTempFile:&passwordTmpFile];

        NSTask *t = [[NSTask alloc] init];
        t.launchPath = binary;
        t.arguments  = args;
        [t launch];
        [t waitUntilExit];

        if (passwordTmpFile)
            [[NSFileManager defaultManager] removeItemAtPath:passwordTmpFile error:nil];
    }

    [self updateMenuState];
}

- (IBAction)showLog:(id)sender
{
    if (!_logWindow) {
        NSRect frame = NSMakeRect(0, 0, 640, 400);
        _logWindow = [[NSWindow alloc]
                      initWithContentRect:frame
                                styleMask:(NSWindowStyleMaskTitled |
                                           NSWindowStyleMaskClosable |
                                           NSWindowStyleMaskResizable)
                                  backing:NSBackingStoreBuffered
                                    defer:NO];
        _logWindow.title = @"macVNC Log";
        _logWindow.releasedWhenClosed = NO;

        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:frame];
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        scroll.hasVerticalScroller   = YES;
        scroll.hasHorizontalScroller = YES;
        scroll.autohidesScrollers    = YES;

        _logTextView = [[NSTextView alloc] initWithFrame:frame];
        _logTextView.editable      = NO;
        _logTextView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        _logTextView.backgroundColor  = [NSColor blackColor];
        _logTextView.textColor        = [NSColor greenColor];

        scroll.documentView = _logTextView;
        _logWindow.contentView = scroll;
    }

    /* Fill with buffered history */
    if (_logBuffer.length) {
        [_logTextView.textStorage
         setAttributedString:[[NSAttributedString alloc]
                              initWithString:_logBuffer
                                  attributes:@{NSFontAttributeName:
                                               [NSFont userFixedPitchFontOfSize:11],
                                               NSForegroundColorAttributeName:
                                               [NSColor greenColor]}]];
    }

    [_logWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (IBAction)quitApp:(id)sender
{
    [self stopServer];
    [NSApp terminate:nil];
}

/* ── Convenience ─────────────────────────────────────────────────────────── */

- (void)showAlert:(NSString *)message information:(NSString *)info
{
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText     = message;
    alert.informativeText = info;
    [alert runModal];
}

@end

/* ── Entry point ─────────────────────────────────────────────────────────── */

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        app.activationPolicy = NSApplicationActivationPolicyAccessory;

        MenuBarAppDelegate *delegate = [[MenuBarAppDelegate alloc] init];
        app.delegate = delegate;

        [app run];
    }
    return 0;
}
