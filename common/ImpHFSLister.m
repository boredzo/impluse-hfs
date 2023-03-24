//
//  ImpHFSLister.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-06.
//

#import "ImpHFSLister.h"

#import "ImpCSVProducer.h"

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
	__block NSError *_Nullable volumeLoadError = nil;

	ImpVolumeProbe *_Nonnull const probe = [[ImpVolumeProbe alloc] initWithFileDescriptor:readFD];
	[probe findVolumes:^(const u_int64_t startOffsetInBytes, const u_int64_t lengthInBytes, Class  _Nullable const __unsafe_unretained volumeClass) {
		ImpHFSVolume *_Nonnull srcVol = [[volumeClass alloc] initWithFileDescriptor:readFD startOffsetInBytes:startOffsetInBytes lengthInBytes:lengthInBytes textEncoding:self.hfsTextEncoding];
		bool const loaded = [srcVol loadAndReturnError:&volumeLoadError];

		if (loaded) {
			ImpDehydratedItem *_Nonnull const rootDirectory = [ImpDehydratedItem rootDirectoryOfHFSVolume:srcVol];
			if (self.inventoryApplications) {
				[self inventoryApplicationsWithinItem:rootDirectory];
			} else {
				[rootDirectory printDirectoryHierarchy_asPaths:self.printAbsolutePaths];
			}
			listed = true;
		}
	}];

	if (! listed) {
		if (outError != NULL) {
			*outError = volumeLoadError;
		}
	}

	return listed;
}

- (void) inventoryApplicationsWithinItem:(ImpDehydratedItem *_Nonnull const)rootDirectory {
	NSArray <NSString *> *_Nonnull const columns = @[
		@"volume_name",
		@"application_name",
		@"version",
		@"creation_date",
		@"modification_date",
		@"file_type",
		@"signature",
		@"path"
	];
	ImpCSVProducer *_Nonnull const csvProducer = [[ImpCSVProducer alloc] initWithFileHandle:[NSFileHandle fileHandleWithStandardOutput] headerRow:columns];

	NSISO8601DateFormatter *_Nonnull const iso8601Fmtr = [NSISO8601DateFormatter new];
	iso8601Fmtr.formatOptions = NSISO8601DateFormatWithInternetDateTime;
	[rootDirectory walkBreadthFirst:^(const NSUInteger depth, ImpDehydratedItem *_Nonnull const item) {
		//TODO: Should we also include 'appe' and 'appc'?
		if (item.fileTypeCode == 'APPL') {
			@autoreleasepool {
				[csvProducer writeRow:@[
					rootDirectory.name,
					item.name,
					item.versionStringFromVersionNumber ?: @"-",
					[iso8601Fmtr stringFromDate:item.creationDate],
					[iso8601Fmtr stringFromDate:item.modificationDate],
					NSFileTypeForHFSTypeCode(item.fileTypeCode),
					NSFileTypeForHFSTypeCode(item.creatorCode),
					[item.path componentsJoinedByString:@":"]
				]];
			}
		}
	}];
}

@end
