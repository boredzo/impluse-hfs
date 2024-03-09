//
//  ImpHFSSourceVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-07.
//

#import "ImpSourceVolume.h"

#import <hfs/hfs_format.h>

@interface ImpHFSSourceVolume : ImpSourceVolume

- (void) peekAtHFSVolumeHeader:(void (^_Nonnull const)(struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr NS_NOESCAPE))block;

#pragma mark Reading fork contents

///Read fork contents from the sections of the volume indicated by the given extents.
- (NSData *_Nullable) readDataFromFileDescriptor:(int const)readFD
	logicalLength:(u_int64_t const)numBytes
	extents:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	numExtents:(NSUInteger const)numExtents
	error:(NSError *_Nullable *_Nonnull const)outError;

///Returns true if none of the extents in this record overlap. Returns false if there are overlapping extents, which may jeopardize user data or lead to volume corruption. Ignores any extents after an empty extent.
- (bool) checkHFSExtentRecord:(HFSExtentRecord const *_Nonnull const)hfsExtRec;

///For every extent in the file (the initial three plus any overflow records) until an empty extent, call the block with that extent and the number of bytes remaining in the file. The block should return the number of bytes it consumed (e.g., read from the file descriptor). Returns the total number of bytes consumed.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithExtentsRecord:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtRec
	readDataOrReturnError:(NSError *_Nullable *_Nonnull const)outError
	block:(bool (^_Nonnull const)(NSData *_Nonnull const fileData, u_int64_t const logicalLength))block;

///More general method for doing something with every extent, mainly exposed for the sake of analyze.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithExtentsRecord:(struct HFSExtentDescriptor const *_Nonnull const)initialExtRec
	block:(u_int64_t (^_Nonnull const)(struct HFSExtentDescriptor const *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining))block;

@end
