//
//  ImpHFSVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-26.
//

#import <Foundation/Foundation.h>

@class ImpBTreeFile;

#import "ImpForkUtilities.h"

@interface ImpHFSVolume : NSObject

- (instancetype _Nonnull) initWithFileDescriptor:(int const)readFD;

@property(readonly) int fileDescriptor;

@property off_t volumeStartOffset; //Defaults to 0. Set to something else if your HFS volume starts somewhere in the middle of a file (e.g., after a partition map).

///Read the boot blocks, volume header, and allocation bitmap in that order, followed by the extents overflow file and catalog file.
- (bool)loadAndReturnError:(NSError *_Nullable *_Nonnull const)outError;

- (NSData *_Nonnull)bootBlocks;
- (void) getVolumeHeader:(void *_Nonnull const)outMDB;
- (NSData *_Nonnull)volumeBitmap;
@property(strong) ImpBTreeFile *_Nonnull catalogBTree;
@property(strong) ImpBTreeFile *_Nonnull extentsOverflowBTree;

- (NSString *_Nonnull) volumeName;
- (u_int64_t) totalSizeInBytes;
- (NSUInteger) numberOfBytesPerBlock;
- (NSUInteger) numberOfBlocksTotal;
- (NSUInteger) numberOfBlocksUsed;
- (NSUInteger) numberOfBlocksFree;
///Total number of files in the whole volume.
- (NSUInteger) numberOfFiles;
///Total number of folders in the whole volume.
- (NSUInteger) numberOfFolders;

#pragma mark -

- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	extents:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	numExtents:(NSUInteger const)numExtents
	error:(NSError *_Nullable *_Nonnull const)outError;

- (bool) checkExtentRecord:(HFSExtentRecord const *_Nonnull const)hfsExtRec;

///For every extent in the file (the initial three plus any overflow records) until an empty extent, call the block with that extent and the number of bytes remaining in the file. The block should return the number of bytes it consumed (e.g., read from the file descriptor). Returns the total number of bytes consumed.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithExtentsRecord:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	readDataOrReturnError:(NSError *_Nullable *_Nonnull const)outError
	block:(bool (^_Nonnull const)(NSData *_Nonnull const fileData, u_int64_t const logicalLength))block;

@end
