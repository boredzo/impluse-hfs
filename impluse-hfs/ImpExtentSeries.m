//
//  ImpExtentSeries.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-11-29.
//

#import "ImpExtentSeries.h"

#import <checkint.h>
#import "ImpByteOrder.h"

@implementation ImpExtentSeries
{
	NSMutableData *_Nonnull _extentDescriptors;
}

- (instancetype)init {
	if ((self = [super init])) {
		_extentDescriptors = [NSMutableData dataWithLength:sizeof(HFSPlusExtentRecord)];
	}
	return self;
}

///Note: May lengthen the last extent instead of appending a new extent if the new extent would be adjacent to the last extent.
- (void) appendHFSExtent:(struct HFSExtentDescriptor const *_Nonnull const)hfsExtDesc {
	//If the new extent is empty, we don't need to do anything.
	if (L(hfsExtDesc->blockCount) == 0) {
		return;
	}

	//If we already have at least one extent, see if we can extend the last one we have to cover the new one.
	if (_numberOfExtents > 0) {
		struct HFSPlusExtentDescriptor *_Nonnull const extentStorage = _extentDescriptors.mutableBytes;
		struct HFSPlusExtentDescriptor *_Nonnull const lastExistingExtent = &extentStorage[_numberOfExtents - 1];

		//This is written in a roundabout way to avoid overflowing, but what it's equivalent to is: if (lastExistingExtent->startBlock + lastExistingExtent->blockCount == hfsExtDesc->startBlock).
		//That is: Are these two extents adjacent?
		if (
			(L(hfsExtDesc->startBlock) >= L(lastExistingExtent->blockCount))
			&&
			(L(hfsExtDesc->startBlock) - L(lastExistingExtent->blockCount) == L(lastExistingExtent->startBlock))
		) {
			//Technically, this can overflow blockCount if it was within 65,535 of UINT_MAX and the addition pushes it over. We would need to assemble 65,538 consecutive adjacent full extents to make that happen. Such a file would be nearly 2.2 TB; HFS catalog records limit files to 2**31 bytes (2 GB), and we can reasonably assume we'll never encounter a file in violation of that constraint.
			S(lastExistingExtent->blockCount,
				L(lastExistingExtent->blockCount) + L(hfsExtDesc->blockCount)
			);

			return;
		}
	}

	/********************
	 ** ⚠️ VERY IMPORTANT: We cannot use any previous pointers to the backing storage of _extentDescriptors beyond this point, because increasing the data's length may invalidate that storage and any pointers to it. **
	 ** We must assume the old storage has been freed, and re-acquire the current pointer to the data's storage. **
	 ********************
	 */
	{
		if (_numberOfExtents % kHFSPlusExtentDensity == 0) {
			//Add another HFS+ extent record's worth of extents. (We always try to keep the backing storage's length equal to a whole number of extent records.)
			[_extentDescriptors increaseLengthBy:kHFSPlusExtentDensity];
		}

		struct HFSPlusExtentDescriptor *_Nonnull const extentStorage = _extentDescriptors.mutableBytes;
		struct HFSPlusExtentDescriptor *_Nonnull const newExtent = extentStorage + _numberOfExtents;
		S(newExtent->startBlock, L(hfsExtDesc->startBlock));
		S(newExtent->blockCount, L(hfsExtDesc->blockCount));

		++_numberOfExtents;
	}
}

- (void)appendHFSExtentRecord:(const struct HFSExtentDescriptor *const)hfsExtRec {
	if (L(hfsExtRec[0].blockCount)) {
		[self appendHFSExtent:hfsExtRec + 0];
		if (L(hfsExtRec[1].blockCount)) {
			[self appendHFSExtent:hfsExtRec + 1];
			if (L(hfsExtRec[2].blockCount)) {
				[self appendHFSExtent:hfsExtRec + 2];
			}
		}
	}
}

///The extent record to put in a file's catalog entry, or the special files' entries in the volume header.
- (NSData *_Nonnull const) firstHFSPlusExtentRecord {
	return [_extentDescriptors subdataWithRange:(NSRange){ 0, sizeof(HFSPlusExtentRecord) }];
}

///Additional extent records, if needed, to be inserted into the extents overflow file. Each item in the array is one HFSPlusExtentRecord, suitable for adding as a record in the extents overflow file. If numberOfExtents <= kHFSPlusExtentDensity (which is 8), then this will be an empty array.
- (NSArray <NSData *> *_Nonnull const) overflowHFSPlusExtentRecords {
	if (_numberOfExtents <= kHFSPlusExtentDensity) {
		return [NSArray array];
	}

	NSMutableArray <NSData *> *_Nonnull const overflowRecords = [NSMutableArray arrayWithCapacity:_numberOfExtents / 8];
	for (NSUInteger i = kHFSPlusExtentDensity; i < _numberOfExtents; i += kHFSPlusExtentDensity) {
		NSData *_Nonnull const recordData = [_extentDescriptors subdataWithRange:(NSRange){ i * sizeof(HFSPlusExtentRecord), kHFSPlusExtentDensity * sizeof(HFSPlusExtentRecord) }];
		[overflowRecords addObject:recordData];
	}
	return overflowRecords;
}

- (void) getHFSPlusExtentRecordAtIndex:(NSUInteger const)extentRecordIndex buffer:(struct HFSPlusExtentDescriptor *_Nonnull const)outPtr {
	[_extentDescriptors getBytes:outPtr range:(NSRange){
		sizeof(HFSPlusExtentRecord) * extentRecordIndex,
		sizeof(HFSPlusExtentRecord)
	}];
}

- (void) forEachExtent:(void (^_Nonnull const)(struct HFSPlusExtentDescriptor const *_Nonnull const))block {
	//We use mutableBytes here to avoid an unnecessary copy, but the block is not permitted to modify the block.
	struct HFSPlusExtentDescriptor const *_Nonnull const extentStorage = _extentDescriptors.mutableBytes;
	NSUInteger const numExtentsAtStartOfIteration = _numberOfExtents;
	for (NSUInteger i = 0; i < numExtentsAtStartOfIteration; ++i) {
		NSUInteger const numExtentsNow = _numberOfExtents;
		NSAssert(numExtentsNow == numExtentsAtStartOfIteration, @"Extent series was modified during iteration (had %lu extents; now somehow has %lu extents). This is either an API misuse (don't modify an extent series while iterating it!) or memory corruption (try ASan).", numExtentsAtStartOfIteration, numExtentsNow);

		block(extentStorage + i);
	}
}
@end
