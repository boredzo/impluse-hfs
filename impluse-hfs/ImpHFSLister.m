//
//  ImpHFSLister.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-06.
//

#import "ImpHFSLister.h"

#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"
#import "ImpVolumeProbe.h"
#import "ImpDehydratedItem.h"

@implementation ImpHFSLister

- (bool)performInventoryOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	__block bool listed = false;
	ImpVolumeProbe *_Nonnull const probe = [[ImpVolumeProbe alloc] initWithFileDescriptor:readFD];
	[probe findVolumes:^(const u_int64_t startOffsetInBytes, const u_int64_t lengthInBytes, Class  _Nullable const __unsafe_unretained volumeClass) {
		ImpHFSVolume *_Nonnull srcVol = [[volumeClass alloc] initWithFileDescriptor:readFD startOffsetInBytes:startOffsetInBytes lengthInBytes:lengthInBytes textEncoding:self.hfsTextEncoding];
		bool const loaded = [srcVol loadAndReturnError:outError];

		if (loaded) {
			ImpDehydratedItem *_Nonnull const rootDirectory = [ImpDehydratedItem rootDirectoryOfHFSVolume:srcVol];
			[rootDirectory printDirectoryHierarchy_asPaths:self.printAbsolutePaths];
			listed = true;
		}
	}];

	return listed;
}

@end
