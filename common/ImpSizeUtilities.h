//
//  ImpSizeUtilities.h
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-30.
//

#ifndef ImpSizeUtilities_h
#define ImpSizeUtilities_h

#import <sys/types.h>
#import <hfs/hfs_format.h>

@class NSString;

///Returns the next number that is less than or equal to size, and is a multiple of factor.
#define macro_ImpNextMultipleOfSize(size, factor) \
	( \
		(size) % (factor) == 0 \
		? (size) \
		: ((size) + ((factor) - (size) % (factor))) \
	)
static inline size_t ImpNextMultipleOfSize(size_t const size, size_t const factor) {
	if (size % factor == 0) {
		return size;
	} else {
		size_t const roundedUpSize = size + (factor - size % factor);
		return roundedUpSize;
	}
}

#define ImpCeilingDivide(num, denom) (((num) / (denom)) + ((((num) % (denom)) != 0) ? 1 : 0))

#pragma mark Extent utilities

u_int32_t ImpNumberOfBlocksInHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec);
///Returns a string concisely describing one extent.
NSString *_Nonnull ImpDescribeHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec);

///Call a block with every block number covered by one extent.
void ImpIterateHFSExtent(struct HFSExtentDescriptor const *_Nonnull const extRec, void (^_Nonnull const block)(u_int32_t const blockNumber));

#pragma mark Extent record utilities

///Returns the sum of the block counts of the extents in the extent record, up to the first empty extent or the end of the record.
u_int32_t ImpNumberOfBlocksInHFSExtentRecord(struct HFSExtentDescriptor const *_Nonnull const extRec);

///Returns the sum of the block counts of the extents in the extent record, up to the first empty extent or the end of the record.
u_int64_t ImpNumberOfBlocksInHFSPlusExtentRecord(struct HFSPlusExtentDescriptor const *_Nonnull const extRec);

///Returns a string concisely describing the extents in the given extent record, up to the first empty extent or the end of the record.
NSString *_Nonnull ImpDescribeHFSExtentRecord(struct HFSExtentDescriptor const *_Nonnull const extRec);

///Returns a string concisely describing the extents in the given extent record, up to the first empty extent or the end of the record.
NSString *_Nonnull ImpDescribeHFSPlusExtentRecord(struct HFSPlusExtentDescriptor const *_Nonnull const extRec);

enum {
	///Size of the blocks used for the boot blocks, volume header, and VBM. Allocation blocks (used for the catalog file, extents file, and user data) use a different size, indicated by drAlBlkSiz in the volume header.
	kISOStandardBlockSize = 512
};

#endif /* ImpSizeUtilities_h */
