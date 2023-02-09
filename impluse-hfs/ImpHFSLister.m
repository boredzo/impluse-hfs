//
//  ImpHFSLister.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-06.
//

#import "ImpHFSLister.h"

#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"
#import "ImpDehydratedItem.h"

@implementation ImpHFSLister

- (bool)performInventoryOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	NSError *_Nullable errorLoadingHFS, *errorLoadingHFSPlus;
	ImpHFSVolume *_Nonnull srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:readFD textEncoding:self.hfsTextEncoding];
	bool const loadedHFS = [srcVol loadAndReturnError:&errorLoadingHFS];
	bool loadedHFSPlus = false;
	if (! loadedHFS) {
		lseek(readFD, 0, SEEK_SET);
		srcVol = [[ImpHFSPlusVolume alloc] initWithFileDescriptor:readFD textEncoding:self.hfsTextEncoding];
		loadedHFSPlus = [srcVol loadAndReturnError:&errorLoadingHFSPlus];
	}
	if (! (loadedHFS || loadedHFSPlus)) {
		*outError = errorLoadingHFS ?: errorLoadingHFSPlus;
		return false;
	}

	ImpDehydratedItem *_Nonnull const rootDirectory = [ImpDehydratedItem rootDirectoryOfHFSVolume:srcVol];
	[rootDirectory printDirectoryHierarchy_asPaths:self.printAbsolutePaths];

	return true;
}

@end
