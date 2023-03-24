//
//  ImpHFSLister.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-06.
//

#import <Foundation/Foundation.h>

@interface ImpHFSLister : NSObject

///Which encoding to interpret HFS volume, folder, and file names as. Defaults to MacRoman.
@property TextEncoding hfsTextEncoding;

///If true, reports each item as an absolute HFS path (volume:folder:folder:item). Files are listed without trailing colons; folders and the root directory are listed with trailing colons. If false, reports each item as an icon (emoji) and name, indented by its depth in the hierarchy.
@property bool printAbsolutePaths;

///Print a CSV inventory of applications only, rather than a full human-readable directory listing.
@property bool inventoryApplications;

///Read an HFS volume from this device. (Does not actually need to be a device but will be assumed to be one.)
@property(copy) NSURL *_Nullable sourceDevice;

- (bool)performInventoryOrReturnError:(NSError *_Nullable *_Nonnull) outError;

@end
