/*
 * This file is part of Bit Slicer.
 *
 * Bit Slicer is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 
 * Bit Slicer is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 
 * You should have received a copy of the GNU General Public License
 * along with Bit Slicer.  If not, see <http://www.gnu.org/licenses/>.
 * 
 * Created by Mayur Pawashe on 2/5/10.
 * Copyright 2010 zgcoder. All rights reserved.
 */

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
@class ZGDocumentController;
@class ZGPreferencesController;
@class ZGMemoryViewer;

#define ZGProcessLaunched    @"ZGProcessLaunched"
#define ZGProcessTerminated  @"ZGProcessTerminated"
#define ZGRunningApplication @"ZGRunningApplication"

@interface ZGAppController : NSObject
{
	IBOutlet ZGDocumentController *documentController;
	BOOL applicationIsAuthenticated;
	ZGPreferencesController *preferencesController;
	ZGMemoryViewer *memoryViewer;
	NSArray *runningApplications;
}

@property (readonly) BOOL applicationIsAuthenticated;

+ (ZGAppController *)sharedController;
- (ZGMemoryViewer *)memoryViewer;
- (ZGDocumentController *)documentController;

- (void)authenticateWithURL:(NSURL *)url;
+ (void)registerPauseAndUnpauseHotKey;
- (IBAction)openPreferences:(id)sender;
- (IBAction)openMemoryViewer:(id)sender;
- (IBAction)jumpToMemoryAddress:(id)sender;
- (IBAction)help:(id)sender;

@end
