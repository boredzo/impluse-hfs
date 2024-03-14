//
//  ImpHFSPlusSourceVolume.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2024-03-08.
//

#import "ImpSourceVolume.h"

@interface ImpHFSPlusSourceVolume : ImpSourceVolume

- (void) peekAtHFSPlusVolumeHeader:(void (^_Nonnull const)(struct HFSPlusVolumeHeader const *_Nonnull const vhPtr NS_NOESCAPE))block;

///For every extent in the file (the initial eight plus any overflow records) until an empty extent, call the block with that extent and the number of bytes remaining in the file. The block should return the number of bytes it consumed (e.g., read from the file descriptor). Returns the total number of bytes consumed.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithBigExtentsRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)initialExtRec
	block:(u_int64_t (^_Nonnull const)(struct HFSPlusExtentDescriptor const *_Nonnull const oneExtent, u_int64_t logicalBytesRemaining))block;

///More general method for doing something with every extent, mainly exposed for the sake of analyze.
- (u_int64_t) forEachExtentInFileWithID:(HFSCatalogNodeID)cnid
	fork:(ImpForkType)forkType
	forkLogicalLength:(u_int64_t const)forkLength
	startingWithBigExtentsRecord:(struct HFSPlusExtentDescriptor const *_Nonnull const)hfsExtRec
	readDataOrReturnError:(NSError *_Nullable *_Nonnull const)outError
	block:(bool (^_Nonnull const)(NSData *_Nonnull const forkData, u_int64_t const logicalLength))block;

@end
