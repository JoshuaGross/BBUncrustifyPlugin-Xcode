//
//  BBUncrustifyPlugin.m
//  BBUncrustifyPlugin
//
//  Created by Benoît on 16/03/13.
//
//

#import "BBUncrustifyPlugin.h"
#import "BBUncrustify.h"
#import "BBXcode.h"
#import "BBPluginUpdater.h"

@interface BBUncrustifyPlugin ()
@property (nonatomic, strong) NSMutableDictionary *openFileHashes;
@end

@implementation BBUncrustifyPlugin {}

#pragma mark - Setup and Teardown

static BBUncrustifyPlugin *sharedPlugin = nil;

+ (void)pluginDidLoad:(NSBundle *)plugin {
	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
	    sharedPlugin = [[self alloc] init];
	});
}

- (id)init {
	self  = [super init];
	if (self) {
        // Set defaults
        if (![[NSUserDefaults standardUserDefaults] objectForKey:kBBAutoUncrustify]) {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:kBBAutoUncrustify];
        }

        // Set up edit menu
		NSMenuItem *editMenuItem = [[NSApp mainMenu] itemWithTitle:@"Edit"];
		if (editMenuItem) {
			[[editMenuItem submenu] addItem:[NSMenuItem separatorItem]];

			NSMenuItem *menuItem;
			menuItem = [[NSMenuItem alloc] initWithTitle:@"Uncrustify Selected Files" action:@selector(uncrustifySelectedFiles:) keyEquivalent:@""];
			[menuItem setTarget:self];
			[[editMenuItem submenu] addItem:menuItem];
			[menuItem release];
            menuItem = nil;

			menuItem = [[NSMenuItem alloc] initWithTitle:@"Uncrustify Active File" action:@selector(uncrustifyActiveFile:) keyEquivalent:@""];
			[menuItem setTarget:self];
			[[editMenuItem submenu] addItem:menuItem];
			[menuItem release];
            menuItem = nil;

			menuItem = [[NSMenuItem alloc] initWithTitle:@"Uncrustify Selected Lines" action:@selector(uncrustifySelectedLines:) keyEquivalent:@""];
			[menuItem setTarget:self];
			[[editMenuItem submenu] addItem:menuItem];
			[menuItem release];
            menuItem = nil;

			menuItem = [[NSMenuItem alloc] initWithTitle:@"Open with UncrustifyX" action:@selector(openWithUncrustifyX:) keyEquivalent:@""];
			[menuItem setTarget:self];
			[[editMenuItem submenu] addItem:menuItem];
			[menuItem release];
            menuItem = nil;

			menuItem = [[NSMenuItem alloc] initWithTitle:@"Auto-Uncrustify open files" action:@selector(toggleAutomaticUncrustify:) keyEquivalent:@""];
			[menuItem setTarget:self];
			[[editMenuItem submenu] addItem:menuItem];
			[menuItem release];
            menuItem = nil;

			if ([[NSUserDefaults standardUserDefaults] boolForKey:kBBAutoUncrustify]) {
				_openFileHashes = [[NSMutableDictionary alloc] initWithCapacity:2];
				[self automaticUncrustify];
			}

			[BBPluginUpdater sharedUpdater].delegate = self;

			NSLog(@"BBUncrustifyPlugin (V%@) loaded", [[[NSBundle bundleForClass:[self class]] infoDictionary] objectForKey:@"CFBundleVersion"]);
		}
	}
	return self;
}

- (void)automaticUncrustify {
	IDESourceCodeDocument *currentDocument = [BBXcode currentSourceCodeDocument];
	NSTextView *currentTextView = [BBXcode currentSourceCodeTextView];
	NSString *openFileName = [[currentDocument fileURL] absoluteString];
	NSUInteger openFileHash = [[[BBXcode currentSourceCodeDocument] textStorage] hash];

	// file should only be processed when it was saved ~3 seconds ago.
    BOOL isObjCfile = [openFileName hasSuffix:@".m"] || [openFileName hasSuffix:@".h"];
    BOOL shouldProcessFile = isObjCfile	 && currentDocument && currentTextView;
	if (shouldProcessFile) {
		// Make a record of the current file that's open.
		NSMutableDictionary *existingRecord = [_openFileHashes objectForKey:openFileName] ? : [[NSMutableDictionary alloc] initWithObjects:@[[NSNumber numberWithUnsignedInteger:openFileHash]] forKeys:@[@"oldHash"]];
		existingRecord[@"hash"] = [NSNumber numberWithUnsignedInteger:openFileHash];
		existingRecord[@"dirty"] = [NSNumber numberWithBool:[existingRecord[@"oldHash"] unsignedIntegerValue] != openFileHash];
		existingRecord[@"doc"] = currentDocument;
		existingRecord[@"textview"] = currentTextView;
		existingRecord[@"pt"] = currentDocument.fileModificationDate ? : [NSDate date];

		[_openFileHashes setValue:existingRecord forKey:openFileName];

		// Uncrustify a file if it has been closed, or changed, between 3-4 seconds ago.
		for (NSString *key in [_openFileHashes copy]) {
			NSDictionary *fileDetailsDict = [_openFileHashes valueForKey:key];
			NSDate *pollTime = [fileDetailsDict valueForKey:@"pt"];
			if (fabsf([pollTime timeIntervalSinceNow]) < 3 || fabsf([pollTime timeIntervalSinceNow]) > 5) {
				continue;
			}
			if (![fileDetailsDict[@"dirty"] boolValue]) {
				continue;
			}

			// The document needs to have been open for at least 5 seconds and to have changed.
			IDESourceCodeDocument *doc = [fileDetailsDict valueForKey:@"doc"];
			NSTextView *textView = [fileDetailsDict valueForKey:@"textview"];
			[self uncrustifySourceCodeTextView:textView inDocument:doc requireCustomConfig:YES];

			existingRecord[@"oldHash"] = [NSNumber numberWithUnsignedInteger:openFileHash];
			[_openFileHashes setValue:existingRecord forKey:openFileName];
		}
	}

	// Trigger uncrustify check every 2 seconds
	if ([[NSUserDefaults standardUserDefaults] boolForKey:kBBAutoUncrustify]) {
		double delayInSeconds = 2.0;
		dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
		dispatch_after(popTime, dispatch_get_main_queue(), ^(void) {
		    [self automaticUncrustify];
		});
	}
}

- (void)uncrustifySourceCodeTextView:(NSTextView *)textView inDocument:(IDESourceCodeDocument *)document requireCustomConfig:(BOOL)requireCustomConfig {
	DVTSourceTextStorage *textStorage = [document textStorage];

	// We try to restore the original cursor position after the uncrustification. We compute a percentage value
	// expressing the actual selected line compared to the total number of lines of the document. After the uncrustification,
	// we restore the position taking into account the modified number of lines of the document.

	CGRect visibleRect = [textView visibleRect];
	NSArray *originalRanges = [textView selectedRanges];
	NSRange originalCharacterRange = [textView selectedRange];
	NSRange originalLineRange = [textStorage lineRangeForCharacterRange:originalCharacterRange];
	NSRange originalDocumentLineRange = [textStorage lineRangeForCharacterRange:NSMakeRange(0, textStorage.string.length)];
	NSUInteger originalLength = textStorage.string.length;

	CGFloat verticalRelativePosition = (CGFloat)originalLineRange.location / (CGFloat)originalDocumentLineRange.length;

	IDEWorkspace *currentWorkspace = [BBXcode currentWorkspaceDocument].workspace;
	[BBXcode uncrustifyCodeOfDocument:document inWorkspace:currentWorkspace requireCustomConfig:requireCustomConfig];

	NSUInteger newLength = textStorage.string.length;
	NSInteger lengthDiff = originalLength - newLength;
	NSRange newDocumentLineRange = [textStorage lineRangeForCharacterRange:NSMakeRange(0, textStorage.string.length)];
	NSUInteger originalLine = roundf(verticalRelativePosition * (CGFloat)originalDocumentLineRange.length);
	NSUInteger restoredLine = roundf(verticalRelativePosition * (CGFloat)newDocumentLineRange.length);

	if (newLength < restoredLine) {
		return;
	}

	NSRange newCharacterRange = [textStorage characterRangeForLineRange:NSMakeRange(restoredLine, 0)];

	if ((newCharacterRange.location + newCharacterRange.length) < textStorage.string.length) {
		// move cursor adsf
		[textView scrollRectToVisible:visibleRect];

		// If we can just select all the initial ranges (say, if the number of lines hasn't changed) do so.
		// We make the selection after adjusting ranges in the most naive way -
		//  by adding/subtracting the change in string length.
		if (originalLine == restoredLine) {
			NSMutableArray *ranges = [[NSMutableArray alloc] initWithCapacity:originalRanges.count];
			for (NSValue *rangeValue in originalRanges) {
				NSRange adjustedRange = [rangeValue rangeValue];
				adjustedRange.location -= lengthDiff;
				[ranges addObject:[NSValue valueWithRange:adjustedRange]];
			}
			[textView setSelectedRanges:ranges];
			[ranges release];
		}
		else {
			[textView setSelectedRange:newCharacterRange affinity:NSSelectionAffinityDownstream stillSelecting:NO];
		}
	}
}

#pragma mark - Actions

- (IBAction)uncrustifySelectedFiles:(id)sender {
    NSArray *fileNavigableItems = [BBXcode selectedSourceCodeFileNavigableItems];
    IDEWorkspace *currentWorkspace = [BBXcode currentWorkspaceDocument].workspace;
    for (IDEFileNavigableItem *fileNavigableItem in fileNavigableItems) {
        NSDocument *document = [IDEDocumentController retainedEditorDocumentForNavigableItem:fileNavigableItem error:nil];
        if ([document isKindOfClass:NSClassFromString(@"IDESourceCodeDocument")]) {
            IDESourceCodeDocument *sourceCodeDocument = (IDESourceCodeDocument *)document;
            BOOL uncrustified = [BBXcode uncrustifyCodeOfDocument:sourceCodeDocument inWorkspace:currentWorkspace];
            if (uncrustified) {
                [document saveDocument:nil];
            }
        }
        [IDEDocumentController releaseEditorDocument:document];
    }

    [[BBPluginUpdater sharedUpdater] checkForUpdatesIfNeeded];
}

- (IBAction)uncrustifyActiveFile:(id)sender {
	IDESourceCodeDocument *document = [BBXcode currentSourceCodeDocument];
	if (!document) return;

	[self uncrustifySourceCodeTextView:[BBXcode currentSourceCodeTextView] inDocument:document requireCustomConfig:NO];

	[[BBPluginUpdater sharedUpdater] checkForUpdatesIfNeeded];
}

- (IBAction)uncrustifySelectedLines:(id)sender {
    IDESourceCodeDocument *document = [BBXcode currentSourceCodeDocument];
    NSTextView *textView = [BBXcode currentSourceCodeTextView];
    if (!document || !textView) return;
    IDEWorkspace *currentWorkspace = [BBXcode currentWorkspaceDocument].workspace;
    NSArray *selectedRanges = [textView selectedRanges];
    [BBXcode uncrustifyCodeAtRanges:selectedRanges document:document inWorkspace:currentWorkspace];
    
    [[BBPluginUpdater sharedUpdater] checkForUpdatesIfNeeded];
}

- (IBAction)openWithUncrustifyX:(id)sender {
    NSURL *appURL = [BBUncrustify uncrustifyXApplicationURL];
    
    NSURL *configurationFileURL = [BBUncrustify resolvedConfigurationFileURLWithAdditionalLookupFolderURLs:nil];
    NSURL *builtInConfigurationFileURL = [BBUncrustify builtInConfigurationFileURL];
    if ([configurationFileURL isEqual:builtInConfigurationFileURL]) {
        configurationFileURL = [BBUncrustify userConfigurationFileURLs][0];
        NSAlert *alert = [NSAlert alertWithMessageText:@"Custom Configuration File Not Found" defaultButton:@"Create Configuration File & Open UncrustifyX" alternateButton:@"Cancel" otherButton:nil informativeTextWithFormat:@"Do you want to create a configuration file at this path \n%@", configurationFileURL.path];
        if ([alert runModal] == NSAlertDefaultReturn) {
            [[NSFileManager defaultManager] copyItemAtPath:builtInConfigurationFileURL.path toPath:configurationFileURL.path error:nil];
        } else {
            configurationFileURL = nil;
        }
    }
    
    if (configurationFileURL) {
        IDESourceCodeDocument *document = [BBXcode currentSourceCodeDocument];
        if (document) {
            DVTSourceTextStorage *textStorage = [document textStorage];
            [[NSPasteboard pasteboardWithName:@"BBUncrustifyPlugin-source-code"] clearContents];
            if (textStorage.string) {
                [[NSPasteboard pasteboardWithName:@"BBUncrustifyPlugin-source-code"] writeObjects:@[textStorage.string]];
            }
        }
        NSDictionary *configuration = @{ NSWorkspaceLaunchConfigurationArguments: @[@"-bbuncrustifyplugin", @"-configpath", configurationFileURL.path] };
        [[NSWorkspace sharedWorkspace]launchApplicationAtURL:appURL options:0 configuration:configuration error:nil];
    }
    
    [[BBPluginUpdater sharedUpdater] checkForUpdatesIfNeeded];
}

- (IBAction)toggleAutomaticUncrustify:(id)sender {
    BOOL boolForOption = ![[NSUserDefaults standardUserDefaults] boolForKey:kBBAutoUncrustify];
    [[NSUserDefaults standardUserDefaults] setBool:boolForOption forKey:kBBAutoUncrustify];
    [sender setState:(boolForOption ? NSOnState : NSOffState)];
    
    if (boolForOption) {
        [self automaticUncrustify];
    }
}

#pragma mark - NSMenuValidation

- (BOOL)validateMenuItem:(NSMenuItem *)menuItem {
    if ([menuItem action] == @selector(uncrustifySelectedFiles:)) {
        return ([BBXcode selectedSourceCodeFileNavigableItems].count > 0);
    } else if ([menuItem action] == @selector(uncrustifyActiveFile:)) {
        IDESourceCodeDocument *document = [BBXcode currentSourceCodeDocument];
        return (document != nil);
    } else if ([menuItem action] == @selector(uncrustifySelectedLines:)) {
        BOOL validated = NO;
        IDESourceCodeDocument *document = [BBXcode currentSourceCodeDocument];
        NSTextView *textView = [BBXcode currentSourceCodeTextView];
        if (document && textView) {
            NSArray *selectedRanges = [textView selectedRanges];
            validated = (selectedRanges.count > 0);
        }
        return validated;
    } else if ([menuItem action] == @selector(toggleAutomaticUncrustify:)) {
        [menuItem setEnabled:YES];
        [menuItem setState:[[NSUserDefaults standardUserDefaults] boolForKey:kBBAutoUncrustify] ? NSOnState : NSOffState];
        return YES;
    } else if ([menuItem action] == @selector(openWithUncrustifyX:)) {
        BOOL appExists = NO;
        NSURL *appURL = [BBUncrustify uncrustifyXApplicationURL];
        if (appURL) appExists = [[NSFileManager defaultManager] fileExistsAtPath:appURL.path];
        [menuItem setHidden:!appExists];
    }
    return YES;
}

#pragma mark - SUUpdater Delegate

- (NSString *)pathToRelaunchForUpdater:(SUUpdater *)updater {
    return [[NSBundle mainBundle].bundleURL path];
}

@end
