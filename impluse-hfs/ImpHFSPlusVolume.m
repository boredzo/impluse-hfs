//
//  ImpHFSPlusVolume.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import "ImpHFSPlusVolume.h"

#import <hfs/hfs_format.h>
enum { kISOStandardBlockSize = 512 };

@interface ImpHFSPlusVolume ()

///Create a file with the requested file ID if not zero, or with the next available item ID. If a specific ID is requested, this method will either create a file with that ID and return that ID, or fail and return zero. If no specific ID is requested (requestedFileID is zero), this method will create a file with the first available ID and return that.
- (u_int32_t) createFileWithID:(u_int32_t)requestedFileID length:(NSUInteger)length parent:(u_int32_t)parentDirID;

@end

@implementation ImpHFSPlusVolume
{
	struct HFSPlusVolumeHeader _vh;
}

- (instancetype)init {
	if ((self = [super init])) {
		_bootBlocks = [NSMutableData dataWithLength:1024];
		_volumeHeader = [_bootBlocks subdataWithRange:(NSRange){ 0, 512 }];
	}
	return self;
}

- (void) createAllocationFileFromHFSVolumeBitmap:(NSData *_Nonnull const)vbmData {
	//Must be this value per hfs_format.h.
	u_int32_t const fileID = [self createFileWithID:kHFSAllocationFileID length:vbmData.length parent:0]; //FIXME: What *should* the parent of the allocation ID be?
	NSAssert(fileID == kHFSAllocationFileID, @"Failed to create allocation file; this may indicate that the allocation file ID was already claimed, likely by a regular file, which is a temporal violation (i.e., a bug)");
}

- (u_int32_t) createFileWithExtent:(NSRange)extentRange parent:(u_int32_t)parentDirID {
	return [self createFileWithLength:extentRange.length parent:parentDirID];
}
- (u_int32_t) createFileWithLength:(NSUInteger)length parent:(u_int32_t)parentDirID {
	return [self createFileWithID:0 length:length parent:parentDirID];
}

- (u_int32_t) createFileWithID:(u_int32_t)requestedFileID length:(NSUInteger)length parent:(u_int32_t)parentDirID {
	//TODO: Implement me
	NSAssert(false, @"(Re-)Creating files in the new volume is not implemented yet");
	return 0;
}

- (void)appendData:(NSData *_Nonnull const)data toFile:(u_int32_t)fileID {
	//TODO: Implement me
	NSAssert(false, @"Appending data to files in the new volume is not implemented yet");
}

@end
