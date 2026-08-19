/*
 * macVNC – Menu Bar UI
 *
 * MenuBarApp.h – AppDelegate class for the macVNCUI menu-bar wrapper.
 *
 * This application launches the macVNC CLI binary as a managed subprocess and
 * exposes its options through an NSStatusItem menu.
 */

#import <Cocoa/Cocoa.h>

@interface MenuBarAppDelegate : NSObject <NSApplicationDelegate, NSMenuDelegate>

@end
