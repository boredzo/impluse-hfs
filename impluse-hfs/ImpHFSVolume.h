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

- (bool) readBootBlocksFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError; 
- (bool) readVolumeHeaderFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
- (bool)readAllocationBitmapFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
- (bool)readCatalogFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;
- (bool)readExtentsOverflowFileFromFileDescriptor:(int const)readFD error:(NSError *_Nullable *_Nonnull const)outError;

///Convenience method that reads the boot blocks, volume header, allocation bitmap, extents overflow file, and catalog file, in that order.
- (bool)loadAndReturnError:(NSError *_Nullable *_Nonnull const)outError;

- (NSData *_Nonnull)bootBlocks;
- (void) getVolumeHeader:(void *_Nonnull const)outMDB;
- (NSData *_Nonnull)volumeBitmap;
@property(strong) ImpBTreeFile *_Nonnull catalogBTree;
@property(strong) ImpBTreeFile *_Nonnull extentsOverflowBTree;

- (NSString *_Nonnull) volumeName;
- (NSUInteger) numberOfBytesPerBlock;
- (NSUInteger) numberOfBlocksTotal;
- (NSUInteger) numberOfBlocksUsed;
- (NSUInteger) numberOfBlocksFree;

#pragma mark -

- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	extent:(struct HFSExtentDescriptor const *_Nonnull const)hfsExt
	error:(NSError *_Nullable *_Nonnull const)outError;
- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	extents:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	error:(NSError *_Nullable *_Nonnull const)outError;

- (bool) checkExtentRecord:(HFSExtentRecord const *_Nonnull const)hfsExtRec;

- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithExtentsRecord:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	readDataOrReturnError:(NSError *_Nullable *_Nonnull const)outError
	block:(bool (^_Nonnull const)(NSData *_Nonnull const fileData, u_int64_t const logicalLength))block;

@end
